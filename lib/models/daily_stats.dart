/// Aggregated listening statistics for a single calendar day.
class DailyStats {
  final DateTime date;
  final int totalConnectedSeconds;
  final int totalActiveListeningSeconds;
  final int totalSilentSeconds;
  final int deviceSessionCount;
  final int continuousSessionCount;
  final int devicesUsedCount;
  final int longestContinuousSessionSeconds;

  const DailyStats({
    required this.date,
    required this.totalConnectedSeconds,
    required this.totalActiveListeningSeconds,
    required this.totalSilentSeconds,
    required this.deviceSessionCount,
    required this.continuousSessionCount,
    required this.devicesUsedCount,
    required this.longestContinuousSessionSeconds,
  });

  factory DailyStats.empty(DateTime date) {
    return DailyStats(
      date: date,
      totalConnectedSeconds: 0,
      totalActiveListeningSeconds: 0,
      totalSilentSeconds: 0,
      deviceSessionCount: 0,
      continuousSessionCount: 0,
      devicesUsedCount: 0,
      longestContinuousSessionSeconds: 0,
    );
  }

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

  String get totalConnectedFormatted => formatDuration(totalConnectedSeconds);
  String get totalActiveListeningFormatted =>
      formatDuration(totalActiveListeningSeconds);
  String get totalSilentFormatted => formatDuration(totalSilentSeconds);
  String get longestContinuousFormatted =>
      formatDuration(longestContinuousSessionSeconds);
}
