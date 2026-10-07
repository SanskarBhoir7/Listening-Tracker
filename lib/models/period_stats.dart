/// Aggregate listening and connection statistics for an arbitrary date/time range.
class PeriodStats {
  final DateTime startDate;
  final DateTime endDate;
  final int totalListeningSeconds;
  final int totalConnectedSeconds;
  final int totalSilentSeconds;
  final int sessionCount;
  final int continuousSessionCount;
  final int devicesUsedCount;
  final int longestSessionSeconds;

  const PeriodStats({
    required this.startDate,
    required this.endDate,
    required this.totalListeningSeconds,
    required this.totalConnectedSeconds,
    required this.totalSilentSeconds,
    required this.sessionCount,
    required this.continuousSessionCount,
    required this.devicesUsedCount,
    required this.longestSessionSeconds,
  });

  factory PeriodStats.empty(DateTime startDate, DateTime endDate) {
    return PeriodStats(
      startDate: startDate,
      endDate: endDate,
      totalListeningSeconds: 0,
      totalConnectedSeconds: 0,
      totalSilentSeconds: 0,
      sessionCount: 0,
      continuousSessionCount: 0,
      devicesUsedCount: 0,
      longestSessionSeconds: 0,
    );
  }

  Duration get totalListeningDuration => Duration(seconds: totalListeningSeconds);
  Duration get totalConnectedDuration => Duration(seconds: totalConnectedSeconds);
  Duration get totalSilentDuration => Duration(seconds: totalSilentSeconds);
  Duration get longestSessionDuration => Duration(seconds: longestSessionSeconds);

  int get averageSessionSeconds =>
      sessionCount > 0 ? (totalListeningSeconds / sessionCount).round() : 0;
  Duration get averageSessionDuration => Duration(seconds: averageSessionSeconds);

  /// Efficiency ratio: active listening time divided by total connected time
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
  String get totalSilentFormatted => formatDuration(totalSilentSeconds);
  String get longestSessionFormatted => formatDuration(longestSessionSeconds);
  String get averageSessionFormatted => formatDuration(averageSessionSeconds);

  Map<String, dynamic> toMap() {
    return {
      'start_date': startDate.millisecondsSinceEpoch,
      'end_date': endDate.millisecondsSinceEpoch,
      'total_listening_seconds': totalListeningSeconds,
      'total_connected_seconds': totalConnectedSeconds,
      'total_silent_seconds': totalSilentSeconds,
      'session_count': sessionCount,
      'continuous_session_count': continuousSessionCount,
      'devices_used_count': devicesUsedCount,
      'longest_session_seconds': longestSessionSeconds,
    };
  }

  factory PeriodStats.fromMap(Map<String, dynamic> map) {
    return PeriodStats(
      startDate: DateTime.fromMillisecondsSinceEpoch(map['start_date'] as int),
      endDate: DateTime.fromMillisecondsSinceEpoch(map['end_date'] as int),
      totalListeningSeconds: (map['total_listening_seconds'] as int?) ?? 0,
      totalConnectedSeconds: (map['total_connected_seconds'] as int?) ?? 0,
      totalSilentSeconds: (map['total_silent_seconds'] as int?) ?? 0,
      sessionCount: (map['session_count'] as int?) ?? 0,
      continuousSessionCount: (map['continuous_session_count'] as int?) ?? 0,
      devicesUsedCount: (map['devices_used_count'] as int?) ?? 0,
      longestSessionSeconds: (map['longest_session_seconds'] as int?) ?? 0,
    );
  }

  @override
  String toString() {
    return 'PeriodStats(${startDate.toIso8601String()} - ${endDate.toIso8601String()}, listening: ${totalListeningSeconds}s, connected: ${totalConnectedSeconds}s, sessions: $sessionCount)';
  }
}
