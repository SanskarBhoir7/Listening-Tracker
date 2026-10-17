import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/audio_device.dart';
import '../models/break_state.dart';
import 'break_notification_service.dart';
import 'diagnostic_logger.dart';

/// Deterministic, rule-based Break Engine.
///
/// Tracks continuous actual listening duration and determines whether
/// a break recommendation is required according to configurable thresholds.
///
/// Core Invariants:
/// 1. Only actual audio playback increments continuous listening duration.
///    Bluetooth connection without playback (idle/silent) NEVER counts.
/// 2. Temporary interruptions (within the 3-minute grace period) do NOT increment
///    duration while paused, but preserve continuous session continuity upon resume.
/// 3. When a session terminates (grace period expires, disconnect, or stop monitoring),
///    all break notifications are cancelled, and continuous duration resets to zero.
/// 4. Duplicate notifications are strictly suppressed during the same continuous period.
class BreakEngine {
  static int _nextLocalGeneration = 0;

  String? _sessionGeneration;
  BreakRuleConfig _config;
  BreakRuleConfig get config => _config;

  final BreakNotificationService notificationService;

  BreakState _state;
  BreakState get state => _state;

  // Deduplication flags for the current continuous session
  bool _notifiedBreakSoon = false;
  bool _notifiedBreakRecommended = false;

  bool get hasNotifiedBreakSoon => _notifiedBreakSoon;
  bool get hasNotifiedBreakRecommended => _notifiedBreakRecommended;

  // Snooze tracking
  Duration? _snoozedUntilContinuousDuration;
  bool get isSnoozed =>
      _snoozedUntilContinuousDuration != null &&
      _state.continuousListeningDuration < _snoozedUntilContinuousDuration!;

  Duration? get snoozeRemaining {
    if (_snoozedUntilContinuousDuration == null) return null;
    final remaining =
        _snoozedUntilContinuousDuration! - _state.continuousListeningDuration;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // Dismissal tracking for current thresholds
  final Set<BreakStatus> _dismissedStatuses = <BreakStatus>{};
  bool get isCurrentStatusDismissed =>
      _dismissedStatuses.contains(_state.status);

  // Debug-only simulated duration offset (guarded strictly by kDebugMode)
  Duration _debugSimulatedOffset = Duration.zero;
  Duration _lastActualListeningDuration = Duration.zero;

  Duration get debugSimulatedOffset => _debugSimulatedOffset;

  /// Debug-only method to advance simulated continuous listening time.
  /// Unavailable and rejected in release builds.
  void debugAdvanceSimulatedListening(Duration offset) {
    if (!kDebugMode) {
      throw UnsupportedError(
        'Simulated listening is disabled in release builds.',
      );
    }
    _debugSimulatedOffset += offset;
  }

  /// Debug-only method to reset simulated listening offset.
  /// Unavailable and rejected in release builds.
  void debugResetSimulatedListening() {
    if (!kDebugMode) {
      throw UnsupportedError(
        'Simulated listening is disabled in release builds.',
      );
    }
    _debugSimulatedOffset = Duration.zero;
  }

  // Change notification callback
  void Function(BreakState state)? onBreakStateChanged;

  BreakEngine({
    BreakRuleConfig? config,
    BreakNotificationService? notificationService,
  })  : _config = config ?? const BreakRuleConfig(),
        notificationService =
            notificationService ?? NativeBreakNotificationService(),
        _state = BreakState.initial(config ?? const BreakRuleConfig());

  /// Updates the engine configuration dynamically when user settings change.
  /// Re-evaluates active notifications and state immediately without stale timers.
  Future<void> updateConfig(BreakRuleConfig newConfig) async {
    final thresholdsChanged =
        newConfig.breakSoonThreshold != _config.breakSoonThreshold ||
        newConfig.breakRecommendedThreshold !=
            _config.breakRecommendedThreshold;
    final enabledChanged = newConfig.enabled != _config.enabled;
    if (thresholdsChanged || enabledChanged) {
      // Notification deduplication belongs to the configuration that produced
      // the old thresholds. Let the newly configured thresholds notify once.
      _notifiedBreakSoon = false;
      _notifiedBreakRecommended = false;
      _dismissedStatuses.clear();
    }
    _config = newConfig;
    if (!_config.enabled || thresholdsChanged) {
      try {
        await notificationService.cancelAllBreakNotifications();
      } catch (_) {}
    }
    await update(
      continuousListeningDuration: _lastActualListeningDuration,
      isAudioPlaying: _state.isAudioPlaying,
      isInGracePeriod: _state.isInGracePeriod,
    );
  }

  /// Snoozes the active break reminder for [duration] (or the configured snooze duration).
  /// Cancels active notifications and suppresses re-triggering until the snooze duration elapses.
  Future<void> snooze([Duration? duration]) async {
    final snoozeDur = duration ?? _config.snoozeDuration;
    _snoozedUntilContinuousDuration =
        _state.continuousListeningDuration + snoozeDur;

    // Reset notification flags so reminder can re-trigger when snooze ends
    _notifiedBreakSoon = false;
    _notifiedBreakRecommended = false;
    _dismissedStatuses.remove(_state.status);

    try {
      await notificationService.cancelAllBreakNotifications();
    } catch (_) {}

    DiagnosticLogger.instance.logEvent(
      eventType: 'BREAK_REMINDER_SNOOZED',
      source: 'flutter',
      metadata: {
        'snoozeMinutes': snoozeDur.inMinutes,
        'continuousListeningSeconds':
            _state.continuousListeningDuration.inSeconds,
        'isSimulated': _state.isSimulated,
        'actualContinuousListeningSeconds':
            _lastActualListeningDuration.inSeconds,
        'simulatedOffsetSeconds': _debugSimulatedOffset.inSeconds,
        'snoozedUntilSeconds': _snoozedUntilContinuousDuration!.inSeconds,
      },
    );

    await update(
      continuousListeningDuration: _lastActualListeningDuration,
      isAudioPlaying: _state.isAudioPlaying,
      isInGracePeriod: _state.isInGracePeriod,
    );
  }

  /// Dismisses the break reminder for the current threshold.
  /// Cancels the notification and suppresses re-triggering until a new threshold is reached.
  Future<void> dismiss([int? notificationId]) async {
    _dismissedStatuses.add(_state.status);
    _snoozedUntilContinuousDuration = null;

    try {
      if (notificationId != null) {
        await notificationService.cancelBreakNotification(notificationId);
      } else {
        await notificationService.cancelAllBreakNotifications();
      }
    } catch (_) {}

    DiagnosticLogger.instance.logEvent(
      eventType: 'BREAK_REMINDER_DISMISSED',
      source: 'flutter',
      metadata: {
        'status': _state.status.name,
        'notificationId': notificationId,
        'continuousListeningSeconds':
            _state.continuousListeningDuration.inSeconds,
        'isSimulated': _state.isSimulated,
        'actualContinuousListeningSeconds':
            _lastActualListeningDuration.inSeconds,
        'simulatedOffsetSeconds': _debugSimulatedOffset.inSeconds,
      },
    );

    await update(
      continuousListeningDuration: _lastActualListeningDuration,
      isAudioPlaying: _state.isAudioPlaying,
      isInGracePeriod: _state.isInGracePeriod,
    );
  }

  /// Validates a native notification action against its session and threshold.
  bool isCurrentNotificationAction({
    required Object? sessionGeneration,
    required Object? notificationId,
  }) {
    if (sessionGeneration is! String ||
        sessionGeneration.isEmpty ||
        sessionGeneration != _sessionGeneration ||
        notificationId is! int) {
      return false;
    }
    final int? expectedId;
    if (_state.status == BreakStatus.breakSoon) {
      expectedId = NativeBreakNotificationService.breakSoonNotificationId;
    } else if (_state.status == BreakStatus.breakRecommended) {
      expectedId = NativeBreakNotificationService.breakRecommendedNotificationId;
    } else {
      expectedId = null;
    }
    return notificationId == expectedId;
  }

  /// Updates the engine state from the current session metrics.
  /// Called on every timer tick and state transition.
  Future<void> update({
    required Duration continuousListeningDuration,
    required bool isAudioPlaying,
    required bool isInGracePeriod,
    AudioDevice? activeDevice,
    String? sessionGeneration,
  }) async {
    if (sessionGeneration != null) {
      _sessionGeneration = sessionGeneration;
    } else {
      _sessionGeneration ??= 'break-engine-${++_nextLocalGeneration}';
    }
    _lastActualListeningDuration = continuousListeningDuration;
    final isSimulated = kDebugMode && _debugSimulatedOffset > Duration.zero;
    final effectiveDuration = isSimulated
        ? continuousListeningDuration + _debugSimulatedOffset
        : continuousListeningDuration;

    // If disabled in settings, suppress all reminders
    if (!_config.enabled) {
      final previousState = _state;
      _state = BreakState(
        continuousListeningDuration: effectiveDuration,
        status: BreakStatus.normal,
        timeUntilNextThreshold: _config.breakSoonThreshold,
        recommendation: 'Break reminders are disabled in settings.',
        activeDeviceName: activeDevice?.name ?? _state.activeDeviceName,
        isAudioPlaying: isAudioPlaying,
        isInGracePeriod: isInGracePeriod,
        isSimulated: isSimulated,
        isEnabled: false,
      );

      if (previousState.status != _state.status ||
          previousState.isEnabled != _state.isEnabled ||
          previousState.isInGracePeriod != isInGracePeriod ||
          previousState.isAudioPlaying != isAudioPlaying) {
        onBreakStateChanged?.call(_state);
      }
      return;
    }

    // Check if active snooze has elapsed
    if (_snoozedUntilContinuousDuration != null &&
        effectiveDuration >= _snoozedUntilContinuousDuration!) {
      _snoozedUntilContinuousDuration = null;
    }

    final activeSnooze = _snoozedUntilContinuousDuration != null &&
        effectiveDuration < _snoozedUntilContinuousDuration!;
    final remainingSnooze = activeSnooze
        ? _snoozedUntilContinuousDuration! - effectiveDuration
        : null;

    final status = _determineStatus(effectiveDuration);
    final timeUntilNext = _calculateTimeUntilNext(
      effectiveDuration,
      status,
    );
    final isDismissed = _dismissedStatuses.contains(status);

    final recommendation = _generateRecommendation(
      duration: effectiveDuration,
      status: status,
      isAudioPlaying: isAudioPlaying,
      isInGracePeriod: isInGracePeriod,
      deviceName: activeDevice?.name ?? _state.activeDeviceName,
      isSnoozed: activeSnooze,
      snoozeRemaining: remainingSnooze,
      isDismissed: isDismissed,
    );

    final previousStatus = _state.status;
    final previousInGrace = _state.isInGracePeriod;
    final previousIsPlaying = _state.isAudioPlaying;
    final previousIsSnoozed = _state.isSnoozed;
    final previousIsDismissed = _state.isDismissed;

    _state = BreakState(
      continuousListeningDuration: effectiveDuration,
      status: status,
      timeUntilNextThreshold: timeUntilNext,
      recommendation: recommendation,
      activeDeviceName: activeDevice?.name ?? _state.activeDeviceName,
      isAudioPlaying: isAudioPlaying,
      isInGracePeriod: isInGracePeriod,
      isSimulated: isSimulated,
      isSnoozed: activeSnooze,
      snoozeRemaining: remainingSnooze,
      isDismissed: isDismissed,
      isEnabled: _config.enabled,
    );

    if (previousStatus != status ||
        previousInGrace != isInGracePeriod ||
        previousIsPlaying != isAudioPlaying ||
        previousIsSnoozed != activeSnooze ||
        previousIsDismissed != isDismissed) {
      onBreakStateChanged?.call(_state);
    }

    // Only dispatch notifications during active playback (never during idle, pause, snooze, or if dismissed)
    if (isAudioPlaying && !activeSnooze && !isDismissed) {
      await _checkAndDispatchNotifications(activeDevice);
    }
  }

  BreakStatus _determineStatus(Duration duration) {
    if (duration >= _config.breakRecommendedThreshold) {
      return BreakStatus.breakRecommended;
    } else if (duration >= _config.breakSoonThreshold) {
      return BreakStatus.breakSoon;
    } else {
      return BreakStatus.normal;
    }
  }

  Duration _calculateTimeUntilNext(Duration duration, BreakStatus status) {
    switch (status) {
      case BreakStatus.normal:
        final remaining = _config.breakSoonThreshold - duration;
        return remaining.isNegative ? Duration.zero : remaining;
      case BreakStatus.breakSoon:
        final remaining = _config.breakRecommendedThreshold - duration;
        return remaining.isNegative ? Duration.zero : remaining;
      case BreakStatus.breakRecommended:
        return Duration.zero;
    }
  }

  String _generateRecommendation({
    required Duration duration,
    required BreakStatus status,
    required bool isAudioPlaying,
    required bool isInGracePeriod,
    String? deviceName,
    bool isSnoozed = false,
    Duration? snoozeRemaining,
    bool isDismissed = false,
  }) {
    final deviceStr =
        deviceName != null && deviceName.isNotEmpty ? ' on $deviceName' : '';
    final minutes = duration.inMinutes;

    if (isInGracePeriod) {
      return 'Audio paused$deviceStr. Listening session in grace period.';
    }

    if (!isAudioPlaying && duration == Duration.zero) {
      return 'Break tracking will start when audio begins playing.';
    }

    if (isSnoozed && snoozeRemaining != null) {
      final snoozeMins = (snoozeRemaining.inSeconds / 60).ceil();
      return 'Break reminder snoozed. Resuming in ~$snoozeMins minute(s)$deviceStr.';
    }

    if (isDismissed) {
      return 'Reminder acknowledged for $minutes minutes$deviceStr. Next alert at ${_config.breakRecommendedThreshold.inMinutes} minutes.';
    }

    switch (status) {
      case BreakStatus.normal:
        return 'Listening time is healthy$deviceStr. Keep enjoying your audio.';
      case BreakStatus.breakSoon:
        return 'You have been listening for $minutes minutes$deviceStr. Consider taking a break soon.';
      case BreakStatus.breakRecommended:
        return 'Continuous listening has reached $minutes minutes$deviceStr. It is recommended to take a 10-15 minute break to rest your ears.';
    }
  }

  Future<void> _checkAndDispatchNotifications(AudioDevice? activeDevice) async {
    final deviceName = activeDevice?.name ?? 'your earbuds';

    if (_state.status == BreakStatus.breakSoon && !_notifiedBreakSoon) {
      _notifiedBreakSoon = true;
      final minutes = _config.breakSoonThreshold.inMinutes;
      final title = 'Break Soon Recommended';
      final body =
          'You have been listening continuously for $minutes minutes on $deviceName. Consider resting soon.';

      DiagnosticLogger.instance.logEvent(
        eventType: 'BREAK_REMINDER_TRIGGERED',
        source: 'flutter',
        deviceId: activeDevice?.id,
        deviceName: activeDevice?.name,
        metadata: {
          'thresholdMinutes': minutes,
          'status': 'breakSoon',
          'continuousSeconds': _state.continuousListeningDuration.inSeconds,
          if (_state.isSimulated) 'isSimulated': true,
        },
      );

      await notificationService.showBreakNotification(
        id: NativeBreakNotificationService.breakSoonNotificationId,
        title: title,
        body: body,
        snoozeMinutes: _config.snoozeDuration.inMinutes,
        sessionGeneration: _sessionGeneration!,
      );
    } else if (_state.status == BreakStatus.breakRecommended &&
        !_notifiedBreakRecommended) {
      _notifiedBreakRecommended = true;
      final minutes = _config.breakRecommendedThreshold.inMinutes;
      final title = 'Time for an Ear Rest';
      final body =
          'Continuous listening reached $minutes minutes on $deviceName. Please take a break to protect your hearing.';

      DiagnosticLogger.instance.logEvent(
        eventType: 'BREAK_REMINDER_TRIGGERED',
        source: 'flutter',
        deviceId: activeDevice?.id,
        deviceName: activeDevice?.name,
        metadata: {
          'thresholdMinutes': minutes,
          'status': 'breakRecommended',
          'continuousSeconds': _state.continuousListeningDuration.inSeconds,
          if (_state.isSimulated) 'isSimulated': true,
        },
      );

      await notificationService.showBreakNotification(
        id: NativeBreakNotificationService.breakRecommendedNotificationId,
        title: title,
        body: body,
        snoozeMinutes: _config.snoozeDuration.inMinutes,
        sessionGeneration: _sessionGeneration!,
      );
    }
  }

  /// Resets the engine and cancels all active break notifications.
  /// Called when continuous session terminates or monitoring stops.
  Future<void> reset() async {
    _notifiedBreakSoon = false;
    _notifiedBreakRecommended = false;
    _snoozedUntilContinuousDuration = null;
    _dismissedStatuses.clear();
    _debugSimulatedOffset = Duration.zero;
    _lastActualListeningDuration = Duration.zero;
    _sessionGeneration = null;
    _state = BreakState.initial(_config);
    try {
      await notificationService.cancelAllBreakNotifications();
    } catch (_) {}
    onBreakStateChanged?.call(_state);
  }

  /// Handles switching audio devices seamlessly while maintaining continuous listening time.
  void onDeviceSwitched(AudioDevice newDevice) {
    _state = BreakState(
      continuousListeningDuration: _state.continuousListeningDuration,
      status: _state.status,
      timeUntilNextThreshold: _state.timeUntilNextThreshold,
      recommendation: _generateRecommendation(
        duration: _state.continuousListeningDuration,
        status: _state.status,
        isAudioPlaying: _state.isAudioPlaying,
        isInGracePeriod: _state.isInGracePeriod,
        deviceName: newDevice.name,
        isSnoozed: isSnoozed,
        snoozeRemaining: snoozeRemaining,
        isDismissed: isCurrentStatusDismissed,
      ),
      activeDeviceName: newDevice.name,
      isAudioPlaying: _state.isAudioPlaying,
      isInGracePeriod: _state.isInGracePeriod,
      isSimulated: _state.isSimulated,
      isSnoozed: isSnoozed,
      snoozeRemaining: snoozeRemaining,
      isDismissed: isCurrentStatusDismissed,
      isEnabled: _config.enabled,
    );
    onBreakStateChanged?.call(_state);
  }

  Future<void> dispose() async {
    await reset();
    onBreakStateChanged = null;
  }
}
