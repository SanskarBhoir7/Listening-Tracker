import 'daily_trend_point.dart';
import 'period_stats.dart';

/// Listening totals and daily session trends for a local calendar week.
///
/// [dailyTrends] runs from Monday through [throughDate], so the current week
/// never displays future days as zero-activity days.
class WeeklyListeningInsights {
  final DateTime weekStart;
  final DateTime throughDate;
  final List<DailyTrendPoint> dailyTrends;

  const WeeklyListeningInsights({
    required this.weekStart,
    required this.throughDate,
    required this.dailyTrends,
  });

  DateTime get weekEndExclusive =>
      DateTime(weekStart.year, weekStart.month, weekStart.day + 7);

  int get totalListeningSeconds =>
      dailyTrends.fold(0, (total, point) => total + point.listeningSeconds);

  int get totalSessionCount =>
      dailyTrends.fold(0, (total, point) => total + point.sessionCount);

  String get totalListeningFormatted =>
      PeriodStats.formatDuration(totalListeningSeconds);

  bool get hasSessions => totalSessionCount > 0;
}
