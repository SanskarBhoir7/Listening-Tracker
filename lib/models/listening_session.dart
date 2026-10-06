/// Persistent model for a device-specific listening session.
///
/// Tracks:
/// - Connected Time: Total duration device was connected
/// - Active Listening: Confirmed media playback through this device
/// - Silent / Paused: Time connected without media playback
///
/// Invariant: connectedDuration ≈ activeListeningDuration + silentDuration
///
/// IMPORTANT: Does NOT claim to detect if earbuds are physically in the user's ears.
class ListeningSession {
  final String id;
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final DateTime connectedAt;
  final DateTime? disconnectedAt;
  final DateTime? listeningStartedAt;
  final DateTime? listeningEndedAt;
  final int connectedDurationSeconds;
  final int activeListeningDurationSeconds;
  final int silentDurationSeconds;
  final String status; // 'active' or 'completed'

  const ListeningSession({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.connectedAt,
    this.disconnectedAt,
    this.listeningStartedAt,
    this.listeningEndedAt,
    required this.connectedDurationSeconds,
    required this.activeListeningDurationSeconds,
    required this.silentDurationSeconds,
    this.status = 'active',
  });

  Duration get connectedDuration => Duration(seconds: connectedDurationSeconds);
  Duration get activeListeningDuration => Duration(seconds: activeListeningDurationSeconds);
  Duration get silentDuration => Duration(seconds: silentDurationSeconds);

  static String formatSeconds(int totalSeconds) {
    final d = Duration(seconds: totalSeconds);
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  static String formatClock(int totalSeconds) {
    final d = Duration(seconds: totalSeconds);
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String get connectedDurationFormatted => formatSeconds(connectedDurationSeconds);
  String get activeListeningDurationFormatted => formatSeconds(activeListeningDurationSeconds);
  String get silentDurationFormatted => formatSeconds(silentDurationSeconds);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
      'connected_at': connectedAt.millisecondsSinceEpoch,
      'disconnected_at': disconnectedAt?.millisecondsSinceEpoch,
      'listening_started_at': listeningStartedAt?.millisecondsSinceEpoch,
      'listening_ended_at': listeningEndedAt?.millisecondsSinceEpoch,
      'connected_duration_seconds': connectedDurationSeconds,
      'active_listening_duration_seconds': activeListeningDurationSeconds,
      'silent_duration_seconds': silentDurationSeconds,
      'status': status,
    };
  }

  factory ListeningSession.fromMap(Map<String, dynamic> map) {
    return ListeningSession(
      id: map['id'] as String,
      deviceId: map['device_id'] as String,
      deviceName: map['device_name'] as String,
      deviceType: map['device_type'] as String,
      connectedAt: DateTime.fromMillisecondsSinceEpoch(map['connected_at'] as int),
      disconnectedAt: map['disconnected_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['disconnected_at'] as int)
          : null,
      listeningStartedAt: map['listening_started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['listening_started_at'] as int)
          : null,
      listeningEndedAt: map['listening_ended_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['listening_ended_at'] as int)
          : null,
      connectedDurationSeconds: map['connected_duration_seconds'] as int,
      activeListeningDurationSeconds: map['active_listening_duration_seconds'] as int,
      silentDurationSeconds: map['silent_duration_seconds'] as int,
      status: map['status'] as String? ?? 'completed',
    );
  }

  ListeningSession copyWith({
    DateTime? disconnectedAt,
    DateTime? listeningStartedAt,
    DateTime? listeningEndedAt,
    int? connectedDurationSeconds,
    int? activeListeningDurationSeconds,
    int? silentDurationSeconds,
    String? status,
  }) {
    return ListeningSession(
      id: id,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      connectedAt: connectedAt,
      disconnectedAt: disconnectedAt ?? this.disconnectedAt,
      listeningStartedAt: listeningStartedAt ?? this.listeningStartedAt,
      listeningEndedAt: listeningEndedAt ?? this.listeningEndedAt,
      connectedDurationSeconds: connectedDurationSeconds ?? this.connectedDurationSeconds,
      activeListeningDurationSeconds:
          activeListeningDurationSeconds ?? this.activeListeningDurationSeconds,
      silentDurationSeconds: silentDurationSeconds ?? this.silentDurationSeconds,
      status: status ?? this.status,
    );
  }
}
