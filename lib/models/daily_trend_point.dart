/// Represents an aggregated analytics data point for a single calendar day
/// in trend charts and history tables.
class DailyTrendPoint {
  final DateTime date;
  final int listeningSeconds;
  final int connectedSeconds;
  final int silentSeconds;
  final int sessionCount;

  const DailyTrendPoint({
    required this.date,
    required this.listeningSeconds,
    this.connectedSeconds = 0,
    this.silentSeconds = 0,
    this.sessionCount = 0,
  });

  factory DailyTrendPoint.empty(DateTime date) {
    return DailyTrendPoint(
      date: DateTime(date.year, date.month, date.day),
      listeningSeconds: 0,
      connectedSeconds: 0,
      silentSeconds: 0,
      sessionCount: 0,
    );
  }

  Duration get listeningDuration => Duration(seconds: listeningSeconds);
  Duration get connectedDuration => Duration(seconds: connectedSeconds);
  Duration get silentDuration => Duration(seconds: silentSeconds);

  /// Efficiency ratio: active listening time divided by total connected time (0.0 to 1.0)
  double get listeningRatio => connectedSeconds > 0
      ? (listeningSeconds / connectedSeconds).clamp(0.0, 1.0)
      : 0.0;

  bool get hasActivity =>
      listeningSeconds > 0 || connectedSeconds > 0 || sessionCount > 0;

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

  String get listeningFormatted => formatDuration(listeningSeconds);
  String get connectedFormatted => formatDuration(connectedSeconds);
  String get silentFormatted => formatDuration(silentSeconds);

  Map<String, dynamic> toMap() {
    return {
      'date': date.millisecondsSinceEpoch,
      'listening_seconds': listeningSeconds,
      'connected_seconds': connectedSeconds,
      'silent_seconds': silentSeconds,
      'session_count': sessionCount,
    };
  }

  factory DailyTrendPoint.fromMap(Map<String, dynamic> map) {
    return DailyTrendPoint(
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      listeningSeconds: (map['listening_seconds'] as int?) ?? 0,
      connectedSeconds: (map['connected_seconds'] as int?) ?? 0,
      silentSeconds: (map['silent_seconds'] as int?) ?? 0,
      sessionCount: (map['session_count'] as int?) ?? 0,
    );
  }

  @override
  String toString() {
    return 'DailyTrendPoint(${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}, listening: ${listeningSeconds}s, connected: ${connectedSeconds}s, sessions: $sessionCount)';
  }
}
