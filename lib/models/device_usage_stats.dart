/// Aggregated usage statistics for a specific audio device.
///
/// Tracks total active listening duration, total connection duration,
/// session count, and longest session for that device.
class DeviceUsageStats {
  final String deviceId;
  final String deviceName;
  final int totalListeningSeconds;
  final int totalConnectedSeconds;
  final int sessionCount;
  final int longestSessionSeconds;

  const DeviceUsageStats({
    required this.deviceId,
    required this.deviceName,
    required this.totalListeningSeconds,
    required this.totalConnectedSeconds,
    required this.sessionCount,
    this.longestSessionSeconds = 0,
  });

  factory DeviceUsageStats.empty(String deviceId, String deviceName) {
    return DeviceUsageStats(
      deviceId: deviceId,
      deviceName: deviceName,
      totalListeningSeconds: 0,
      totalConnectedSeconds: 0,
      sessionCount: 0,
      longestSessionSeconds: 0,
    );
  }

  Duration get totalListeningDuration => Duration(seconds: totalListeningSeconds);
  Duration get totalConnectedDuration => Duration(seconds: totalConnectedSeconds);
  Duration get longestSessionDuration => Duration(seconds: longestSessionSeconds);

  int get averageSessionSeconds =>
      sessionCount > 0 ? (totalListeningSeconds / sessionCount).round() : 0;
  Duration get averageSessionDuration => Duration(seconds: averageSessionSeconds);

  /// Ratio of actual listening time to connection time (0.0 to 1.0)
  double get listeningRatio => totalConnectedSeconds > 0
      ? (totalListeningSeconds / totalConnectedSeconds).clamp(0.0, 1.0)
      : 0.0;

  static String formatDuration(int totalSeconds) {
    final d = Duration(seconds: totalSeconds);
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      if (minutes > 0) return '${hours}h ${minutes}m';
      return '${hours}h';
    } else if (minutes > 0) {
      if (seconds > 0) return '${minutes}m ${seconds}s';
      return '${minutes}m';
    } else {
      return '${seconds}s';
    }
  }

  String get totalListeningFormatted => formatDuration(totalListeningSeconds);
  String get totalConnectedFormatted => formatDuration(totalConnectedSeconds);
  String get longestSessionFormatted => formatDuration(longestSessionSeconds);
  String get averageSessionFormatted => formatDuration(averageSessionSeconds);

  Map<String, dynamic> toMap() {
    return {
      'device_id': deviceId,
      'device_name': deviceName,
      'total_listening_seconds': totalListeningSeconds,
      'total_connected_seconds': totalConnectedSeconds,
      'session_count': sessionCount,
      'longest_session_seconds': longestSessionSeconds,
    };
  }

  factory DeviceUsageStats.fromMap(Map<String, dynamic> map) {
    return DeviceUsageStats(
      deviceId: map['device_id'] as String,
      deviceName: map['device_name'] as String,
      totalListeningSeconds: (map['total_listening_seconds'] as int?) ?? 0,
      totalConnectedSeconds: (map['total_connected_seconds'] as int?) ?? 0,
      sessionCount: (map['session_count'] as int?) ?? 0,
      longestSessionSeconds: (map['longest_session_seconds'] as int?) ?? 0,
    );
  }

  @override
  String toString() {
    return 'DeviceUsageStats(device: $deviceName, listening: ${totalListeningSeconds}s, connected: ${totalConnectedSeconds}s, sessions: $sessionCount)';
  }
}
