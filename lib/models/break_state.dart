import 'package:flutter/material.dart';

/// Status of the continuous listening break recommendation.
enum BreakStatus {
  /// Continuous listening duration is within the normal healthy range (< 45 min default).
  normal,

  /// Continuous listening duration has reached the early warning threshold (45-60 min default).
  breakSoon,

  /// Continuous listening duration has reached or exceeded the recommended limit (>= 60 min default).
  breakRecommended,
}

/// Configuration specifying deterministic duration thresholds for break recommendations.
class BreakRuleConfig {
  /// Whether break reminders are enabled.
  final bool enabled;

  /// Duration of continuous actual listening before recommending a break soon.
  final Duration breakSoonThreshold;

  /// Duration of continuous actual listening before strongly recommending a break.
  final Duration breakRecommendedThreshold;

  /// Duration to snooze when a reminder is snoozed.
  final Duration snoozeDuration;

  const BreakRuleConfig({
    this.enabled = true,
    this.breakSoonThreshold = const Duration(minutes: 45),
    this.breakRecommendedThreshold = const Duration(minutes: 60),
    this.snoozeDuration = const Duration(minutes: 10),
  });

  Map<String, dynamic> toMap() => {
    'enabled': enabled ? 1 : 0,
    'break_soon_seconds': breakSoonThreshold.inSeconds,
    'break_recommended_seconds': breakRecommendedThreshold.inSeconds,
    'snooze_seconds': snoozeDuration.inSeconds,
  };

  factory BreakRuleConfig.fromMap(Map<String, dynamic> map) {
    return BreakRuleConfig(
      enabled: (map['enabled'] as int? ?? 1) == 1,
      breakSoonThreshold: Duration(
        seconds: map['break_soon_seconds'] as int? ?? 45 * 60,
      ),
      breakRecommendedThreshold: Duration(
        seconds: map['break_recommended_seconds'] as int? ?? 60 * 60,
      ),
      snoozeDuration: Duration(
        seconds: map['snooze_seconds'] as int? ?? 10 * 60,
      ),
    );
  }
}

/// Immutable snapshot of the current break recommendation state for display and logic.
class BreakState {
  /// Continuous duration of actual audio playback during the current continuous session.
  final Duration continuousListeningDuration;

  /// Current break status classification.
  final BreakStatus status;

  /// Duration remaining until the next threshold is reached.
  /// When [status] is [BreakStatus.breakRecommended], this is [Duration.zero].
  final Duration timeUntilNextThreshold;

  /// Human-readable recommendation message.
  final String recommendation;

  /// Name of the active audio peripheral being monitored.
  final String? activeDeviceName;

  /// Whether audio is actively playing right now (as opposed to paused in grace period or idle).
  final bool isAudioPlaying;

  /// Whether the session is currently in the 3-minute grace period.
  final bool isInGracePeriod;

  /// Whether the continuous listening duration includes debug simulation time.
  final bool isSimulated;

  /// Whether the reminder is currently snoozed.
  final bool isSnoozed;

  /// Duration remaining on active snooze, if any.
  final Duration? snoozeRemaining;

  /// Whether the reminder for the current threshold was dismissed.
  final bool isDismissed;

  /// Whether reminders are enabled in settings.
  final bool isEnabled;

  const BreakState({
    required this.continuousListeningDuration,
    required this.status,
    required this.timeUntilNextThreshold,
    required this.recommendation,
    this.activeDeviceName,
    this.isAudioPlaying = false,
    this.isInGracePeriod = false,
    this.isSimulated = false,
    this.isSnoozed = false,
    this.snoozeRemaining,
    this.isDismissed = false,
    this.isEnabled = true,
  });

  /// Initial idle state when no active listening has taken place.
  factory BreakState.initial([BreakRuleConfig config = const BreakRuleConfig()]) {
    return BreakState(
      continuousListeningDuration: Duration.zero,
      status: BreakStatus.normal,
      timeUntilNextThreshold: config.breakSoonThreshold,
      recommendation: config.enabled
          ? 'Break tracking will start when audio begins playing.'
          : 'Break reminders are disabled in settings.',
      isAudioPlaying: false,
      isInGracePeriod: false,
      isSimulated: false,
      isSnoozed: false,
      isDismissed: false,
      isEnabled: config.enabled,
    );
  }

  /// Formatted continuous listening clock (e.g. "45:00" or "01:15:30").
  String get listeningDurationFormatted {
    final totalSeconds = continuousListeningDuration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Formatted duration until the next threshold (e.g. "12m 45s" or "0s").
  String get timeUntilNextThresholdFormatted {
    if (status == BreakStatus.breakRecommended || timeUntilNextThreshold <= Duration.zero) {
      return 'Threshold reached';
    }
    final totalSeconds = timeUntilNextThreshold.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s remaining';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s remaining';
    } else {
      return '${seconds}s remaining';
    }
  }

  /// Theme accent color corresponding to the break status.
  Color get statusColor {
    switch (status) {
      case BreakStatus.normal:
        return Colors.tealAccent.shade400;
      case BreakStatus.breakSoon:
        return Colors.amberAccent.shade400;
      case BreakStatus.breakRecommended:
        return Colors.deepOrangeAccent.shade200;
    }
  }

  /// Human-readable label for the status badge.
  String get statusLabel {
    switch (status) {
      case BreakStatus.normal:
        return 'NORMAL';
      case BreakStatus.breakSoon:
        return 'BREAK SOON';
      case BreakStatus.breakRecommended:
        return 'BREAK DUE';
    }
  }

  Map<String, dynamic> toMap() => {
    'continuous_listening_seconds': continuousListeningDuration.inSeconds,
    'status': status.name,
    'time_until_next_threshold_seconds': timeUntilNextThreshold.inSeconds,
    'recommendation': recommendation,
    'active_device_name': activeDeviceName,
    'is_audio_playing': isAudioPlaying,
    'is_in_grace_period': isInGracePeriod,
  };
}
