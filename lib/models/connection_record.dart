/// Persistent model for a Bluetooth / external audio device connection record.
///
/// Tracks device connection duration independently of listening sessions.
/// Invariant: Connection start and end reflect physical/OS connection state,
/// not whether audio was playing.
class ConnectionRecord {
  final String id;
  final String deviceId;
  final String deviceName;
  final String deviceType;
  final DateTime connectedAt;
  final DateTime? disconnectedAt;
  final int durationSeconds;
  final String status; // 'active' or 'completed'

  const ConnectionRecord({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
    required this.connectedAt,
    this.disconnectedAt,
    required this.durationSeconds,
    this.status = 'active',
  });

  Duration get duration => Duration(seconds: durationSeconds);

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

  String get durationFormatted => formatSeconds(durationSeconds);
  String get durationClock => formatClock(durationSeconds);

  ConnectionRecord copyWith({
    String? id,
    String? deviceId,
    String? deviceName,
    String? deviceType,
    DateTime? connectedAt,
    DateTime? disconnectedAt,
    int? durationSeconds,
    String? status,
  }) {
    return ConnectionRecord(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      deviceType: deviceType ?? this.deviceType,
      connectedAt: connectedAt ?? this.connectedAt,
      disconnectedAt: disconnectedAt ?? this.disconnectedAt,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
      'connected_at': connectedAt.millisecondsSinceEpoch,
      'disconnected_at': disconnectedAt?.millisecondsSinceEpoch,
      'duration_seconds': durationSeconds,
      'status': status,
    };
  }

  factory ConnectionRecord.fromMap(Map<String, dynamic> map) {
    return ConnectionRecord(
      id: map['id'] as String,
      deviceId: map['device_id'] as String,
      deviceName: map['device_name'] as String,
      deviceType: map['device_type'] as String,
      connectedAt: DateTime.fromMillisecondsSinceEpoch(map['connected_at'] as int),
      disconnectedAt: map['disconnected_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['disconnected_at'] as int)
          : null,
      durationSeconds: (map['duration_seconds'] as int?) ?? 0,
      status: (map['status'] as String?) ?? 'completed',
    );
  }

  @override
  String toString() {
    return 'ConnectionRecord(id: $id, device: $deviceName, connectedAt: $connectedAt, duration: ${durationSeconds}s, status: $status)';
  }
}
