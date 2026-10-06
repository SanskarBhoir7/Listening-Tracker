/// Phase 3: Explicit tracking state enums.
///
/// These replace the implicit boolean-derived states from Phase 2,
/// enforcing a clear separation between Bluetooth connection,
/// audio playback, and listening session lifecycle.
library;

/// Whether a trackable external audio device (Bluetooth, wired, USB) is connected.
enum BluetoothConnectionState {
  disconnected,
  connected,
}

/// Whether system-wide media audio playback is active.
enum AudioPlaybackState {
  playing,
  notPlaying,
}

/// The lifecycle state of a listening session.
///
/// State transitions:
///   IDLE → ACTIVE           when genuine audio playback detected on external device
///   ACTIVE → GRACE_PERIOD   when audio stops (grace timer starts)
///   GRACE_PERIOD → ACTIVE   when audio resumes before grace expires (same session)
///   GRACE_PERIOD → IDLE     when grace period expires without audio resuming
///   ACTIVE → IDLE           when Bluetooth disconnects (immediate, no grace period)
///   GRACE_PERIOD → IDLE     when Bluetooth disconnects (immediate, no grace period)
enum ListeningSessionState {
  /// No active listening session. Device may or may not be connected.
  idle,

  /// Actively listening: audio is playing through an external device.
  active,

  /// Audio has stopped but within the grace period window.
  /// If audio resumes, the same session continues.
  /// If grace period expires, the session ends.
  gracePeriod,
}
