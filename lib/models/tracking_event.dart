import '../tracking_state.dart';

/// Structured tracking event emitted on state transitions.
///
/// Used for diagnostics, analytics, debugging, and UI logs.
class TrackingEvent {
  final String id;
  final String eventType;
  final DateTime timestamp;
  final String? deviceId;
  final String? deviceName;
  final String? deviceType;
  final BluetoothConnectionState? connectionState;
  final AudioPlaybackState? audioState;
  final ListeningSessionState? sessionState;
  final String? reason;
  final int? durationSeconds;
  final Map<String, dynamic>? metadata;

  const TrackingEvent({
    required this.id,
    required this.eventType,
    required this.timestamp,
    this.deviceId,
    this.deviceName,
    this.deviceType,
    this.connectionState,
    this.audioState,
    this.sessionState,
    this.reason,
    this.durationSeconds,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'event_type': eventType,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
      'connection_state': connectionState?.name,
      'audio_state': audioState?.name,
      'session_state': sessionState?.name,
      'reason': reason,
      'duration_seconds': durationSeconds,
      'metadata': metadata,
    };
  }

  factory TrackingEvent.fromMap(Map<String, dynamic> map) {
    return TrackingEvent(
      id: map['id'] as String,
      eventType: map['event_type'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      deviceId: map['device_id'] as String?,
      deviceName: map['device_name'] as String?,
      deviceType: map['device_type'] as String?,
      connectionState: map['connection_state'] != null
          ? BluetoothConnectionState.values.asNameMap()[map['connection_state']]
          : null,
      audioState: map['audio_state'] != null
          ? AudioPlaybackState.values.asNameMap()[map['audio_state']]
          : null,
      sessionState: map['session_state'] != null
          ? ListeningSessionState.values.asNameMap()[map['session_state']]
          : null,
      reason: map['reason'] as String?,
      durationSeconds: map['duration_seconds'] as int?,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(map['metadata'] as Map)
          : null,
    );
  }

  @override
  String toString() {
    final dev = deviceName != null ? ' | device=$deviceName' : '';
    final rsn = reason != null ? ' | reason=$reason' : '';
    final dur = durationSeconds != null ? ' | duration=${durationSeconds}s' : '';
    return '[$eventType] at ${timestamp.toIso8601String()}$dev$rsn$dur';
  }
}
