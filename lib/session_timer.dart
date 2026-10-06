import 'dart:async';

/// Simple session timer for Phase 1 prototype.
///
/// Behavior:
/// - Starts when AUDIO_STARTED is received
/// - Pauses when AUDIO_STOPPED is received
/// - Resumes if audio restarts within the grace period
/// - Ends if: device disconnects, or grace period expires without audio resuming
///
/// EXPERIMENTAL: The grace period (default 3 minutes) is a placeholder.
/// Phase 2 should refine this based on real-world usage data.
@Deprecated(
  'Deprecated in Phase 3. SessionEngine is now the single source of truth for tracking state and grace timers.',
)
class SessionTimer {
  /// Grace period before ending a session after audio stops.
  /// EXPERIMENTAL: 3 minutes is a starting estimate.
  /// Short pauses (e.g., switching songs) should not end a session.
  static const Duration defaultGracePeriod = Duration(minutes: 3);

  Duration gracePeriod;

  SessionTimer({this.gracePeriod = defaultGracePeriod});

  // Session state
  bool _isRunning = false;
  DateTime? _sessionStartTime;
  Duration _accumulatedDuration = Duration.zero;
  DateTime? _lastResumeTime;
  Timer? _graceTimer;
  Timer? _tickTimer;

  // Callbacks
  void Function(Duration elapsed)? onTick;
  void Function(Duration totalDuration)? onSessionEnded;
  void Function()? onStateChanged;

  bool get isRunning => _isRunning;

  DateTime? get sessionStartTime => _sessionStartTime;

  /// Total elapsed time in the current session.
  Duration get elapsed {
    if (!_isRunning) return _accumulatedDuration;
    if (_lastResumeTime == null) return _accumulatedDuration;
    return _accumulatedDuration + DateTime.now().difference(_lastResumeTime!);
  }

  /// Formatted elapsed time as HH:MM:SS
  String get elapsedFormatted {
    final d = elapsed;
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  /// Called when audio playback starts.
  void onAudioStarted() {
    _graceTimer?.cancel();
    _graceTimer = null;

    if (_sessionStartTime == null) {
      // New session
      _sessionStartTime = DateTime.now();
      _accumulatedDuration = Duration.zero;
    }

    _lastResumeTime = DateTime.now();
    _isRunning = true;
    _startTickTimer();
    onStateChanged?.call();
  }

  /// Called when audio playback stops/pauses.
  /// Starts the grace period timer.
  void onAudioStopped() {
    if (_isRunning && _lastResumeTime != null) {
      _accumulatedDuration += DateTime.now().difference(_lastResumeTime!);
    }
    _isRunning = false;
    _lastResumeTime = null;
    _stopTickTimer();

    // Start grace period — if audio doesn't resume, end the session
    _graceTimer?.cancel();
    _graceTimer = Timer(gracePeriod, () {
      _endSession();
    });

    onStateChanged?.call();
  }

  /// Called when the audio device disconnects.
  /// Immediately ends the session (no grace period).
  void onDeviceDisconnected() {
    if (_isRunning && _lastResumeTime != null) {
      _accumulatedDuration += DateTime.now().difference(_lastResumeTime!);
    }
    _isRunning = false;
    _lastResumeTime = null;
    _endSession();
  }

  /// Force-end the current session.
  void _endSession() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _stopTickTimer();

    final totalDuration = _accumulatedDuration;
    _isRunning = false;
    _lastResumeTime = null;
    _sessionStartTime = null;
    _accumulatedDuration = Duration.zero;

    if (totalDuration > Duration.zero) {
      onSessionEnded?.call(totalDuration);
    }

    onStateChanged?.call();
  }

  /// Reset everything.
  void reset() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _stopTickTimer();
    _isRunning = false;
    _sessionStartTime = null;
    _accumulatedDuration = Duration.zero;
    _lastResumeTime = null;
    onStateChanged?.call();
  }

  void _startTickTimer() {
    _stopTickTimer();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      onTick?.call(elapsed);
    });
  }

  void _stopTickTimer() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  void dispose() {
    _graceTimer?.cancel();
    _tickTimer?.cancel();
  }
}
