import 'period_stats.dart';

/// Compares analytics metrics between two distinct time periods (e.g., this week vs last week).
class PeriodComparison {
  final PeriodStats current;
  final PeriodStats previous;

  const PeriodComparison({
    required this.current,
    required this.previous,
  });

  /// Absolute difference in active listening seconds (current - previous)
  int get listeningSecondsDifference =>
      current.totalListeningSeconds - previous.totalListeningSeconds;

  /// Absolute difference in connection seconds (current - previous)
  int get connectedSecondsDifference =>
      current.totalConnectedSeconds - previous.totalConnectedSeconds;

  /// Absolute difference in session count (current - previous)
  int get sessionCountDifference => current.sessionCount - previous.sessionCount;

  /// Percentage change in listening time (-100.0% to +Infinity%).
  /// Zero-safe against zero denominators; never returns NaN or Infinity.
  double get listeningPercentageChange {
    if (previous.totalListeningSeconds == 0) {
      return current.totalListeningSeconds > 0 ? 100.0 : 0.0;
    }
    final change = ((current.totalListeningSeconds - previous.totalListeningSeconds) /
            previous.totalListeningSeconds) *
        100.0;
    return change.isFinite ? change : 0.0;
  }

  /// Percentage change in connection time.
  /// Zero-safe against zero denominators; never returns NaN or Infinity.
  double get connectedPercentageChange {
    if (previous.totalConnectedSeconds == 0) {
      return current.totalConnectedSeconds > 0 ? 100.0 : 0.0;
    }
    final change = ((current.totalConnectedSeconds - previous.totalConnectedSeconds) /
            previous.totalConnectedSeconds) *
        100.0;
    return change.isFinite ? change : 0.0;
  }

  bool get isListeningIncreased => listeningSecondsDifference > 0;
  bool get isListeningDecreased => listeningSecondsDifference < 0;
  bool get isListeningEqual => listeningSecondsDifference == 0;
}
