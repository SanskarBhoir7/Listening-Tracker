import '../models/connection_record.dart';
import '../models/daily_trend_point.dart';
import '../models/device_usage_stats.dart';
import '../models/listening_session.dart';
import '../models/period_comparison.dart';
import '../models/period_stats.dart';

/// Pure-Dart calculation service for listening analytics, metrics, trends, and comparisons.
///
/// Operates on domain models produced by DatabaseAdapter/DatabaseHelper.
/// Strictly decoupled from database persistence or native platform code.
///
/// Metric Guarantees:
/// - Listening time = active listening duration (from device_sessions).
/// - Connection time = physical Bluetooth connection duration (from connection_records).
/// - Never derives connection time from device_sessions.
/// - Never counts silent/grace time as active listening.
class AnalyticsCalculator {
  const AnalyticsCalculator();

  // =========================================================================
  // 1. Average Session Duration
  // =========================================================================

  /// Calculates average session duration in seconds.
  /// Zero-safe against zero or negative session counts.
  /// Uses mathematical rounding (.round()).
  static int calculateAverageSessionSeconds(int totalListeningSeconds, int sessionCount) {
    if (sessionCount <= 0 || totalListeningSeconds <= 0) return 0;
    return (totalListeningSeconds / sessionCount).round();
  }

  /// Calculates average session duration as a [Duration].
  static Duration calculateAverageSessionDuration(int totalListeningSeconds, int sessionCount) {
    return Duration(seconds: calculateAverageSessionSeconds(totalListeningSeconds, sessionCount));
  }

  /// Calculates average session seconds directly from a list of [ListeningSession].
  static int averageSessionSecondsFromSessions(List<ListeningSession> sessions) {
    if (sessions.isEmpty) return 0;
    int totalListening = 0;
    for (final s in sessions) {
      totalListening += s.activeListeningDurationSeconds;
    }
    return calculateAverageSessionSeconds(totalListening, sessions.length);
  }

  /// Calculates average session duration as [Duration] from a list of [ListeningSession].
  static Duration averageSessionDurationFromSessions(List<ListeningSession> sessions) {
    return Duration(seconds: averageSessionSecondsFromSessions(sessions));
  }

  // =========================================================================
  // 2. Listening Ratio
  // =========================================================================

  /// Calculates listening efficiency ratio (active listening / Bluetooth connection time).
  ///
  /// Guarantees:
  /// - Clamped between 0.0 and 1.0 according to project convention.
  /// - Returns 0.0 if connection time <= 0.
  /// - Never produces NaN or Infinity.
  static double calculateListeningRatio(int listeningSeconds, int connectedSeconds) {
    if (connectedSeconds <= 0 || listeningSeconds <= 0) return 0.0;
    final ratio = listeningSeconds / connectedSeconds;
    if (!ratio.isFinite) return 0.0;
    return ratio.clamp(0.0, 1.0);
  }

  /// Calculates listening ratio from a [PeriodStats] instance.
  static double calculateListeningRatioFromStats(PeriodStats stats) {
    return calculateListeningRatio(stats.totalListeningSeconds, stats.totalConnectedSeconds);
  }

  /// Calculates listening ratio from a [DeviceUsageStats] instance.
  static double calculateDeviceListeningRatio(DeviceUsageStats stats) {
    return calculateListeningRatio(stats.totalListeningSeconds, stats.totalConnectedSeconds);
  }

  // =========================================================================
  // 3. Longest Listening Session
  // =========================================================================

  /// Finds the longest actual active listening session duration in seconds.
  /// Does NOT use Bluetooth connection duration.
  /// Returns 0 if the list is empty.
  static int findLongestSessionSeconds(List<ListeningSession> sessions) {
    if (sessions.isEmpty) return 0;
    int longest = 0;
    for (final s in sessions) {
      if (s.activeListeningDurationSeconds > longest) {
        longest = s.activeListeningDurationSeconds;
      }
    }
    return longest;
  }

  /// Returns the [ListeningSession] with the highest active listening duration.
  /// Returns null if the list is empty.
  static ListeningSession? findLongestSession(List<ListeningSession> sessions) {
    if (sessions.isEmpty) return null;
    ListeningSession? longest;
    for (final s in sessions) {
      if (longest == null ||
          s.activeListeningDurationSeconds > longest.activeListeningDurationSeconds) {
        longest = s;
      }
    }
    return longest;
  }

  // =========================================================================
  // 4 & 7. Device Analytics & Most-Used Device
  // =========================================================================

  /// Sorts a list of [DeviceUsageStats] deterministically:
  /// 1. Primary: total listening duration DESC
  /// 2. Tie-break: total connected duration DESC
  /// 3. Tie-break: session count DESC
  /// 4. Tie-break: deviceId ASC
  static List<DeviceUsageStats> sortDeviceUsage(List<DeviceUsageStats> devices) {
    final list = List<DeviceUsageStats>.from(devices);
    list.sort((a, b) {
      final cmpListening = b.totalListeningSeconds.compareTo(a.totalListeningSeconds);
      if (cmpListening != 0) return cmpListening;

      final cmpConnected = b.totalConnectedSeconds.compareTo(a.totalConnectedSeconds);
      if (cmpConnected != 0) return cmpConnected;

      final cmpCount = b.sessionCount.compareTo(a.sessionCount);
      if (cmpCount != 0) return cmpCount;

      return a.deviceId.compareTo(b.deviceId);
    });
    return list;
  }

  /// Determines the most-used device.
  ///
  /// By default, returns the device with the highest listening duration.
  /// Uses deterministic tie-breaking (connected time, session count, deviceId).
  /// Correctly handles connection-only devices when listening time is 0.
  /// Returns null if the list is empty.
  static DeviceUsageStats? findMostUsedDevice(List<DeviceUsageStats> devices) {
    if (devices.isEmpty) return null;
    return sortDeviceUsage(devices).first;
  }

  /// Checks whether a device is connection-only (connected duration > 0, 0 listening time).
  static bool isConnectionOnly(DeviceUsageStats device) {
    return device.totalConnectedSeconds > 0 && device.totalListeningSeconds == 0;
  }

  /// Filters devices that only had connection time without any active listening.
  static List<DeviceUsageStats> filterConnectionOnlyDevices(List<DeviceUsageStats> devices) {
    return devices.where(isConnectionOnly).toList();
  }

  /// Filters devices that had confirmed active listening time (> 0s).
  static List<DeviceUsageStats> filterActiveListeningDevices(List<DeviceUsageStats> devices) {
    return devices.where((d) => d.totalListeningSeconds > 0).toList();
  }

  /// Pure in-memory aggregator that combines sessions and connection records
  /// into aggregated [DeviceUsageStats] list.
  static List<DeviceUsageStats> aggregateDeviceUsageFromRecords({
    required List<ListeningSession> sessions,
    required List<ConnectionRecord> connectionRecords,
  }) {
    final map = <String, _MutableDeviceUsage>{};

    for (final s in sessions) {
      final entry = map.putIfAbsent(
        s.deviceId,
        () => _MutableDeviceUsage(deviceId: s.deviceId, deviceName: s.deviceName),
      );
      entry.totalListeningSeconds += s.activeListeningDurationSeconds;
      entry.sessionCount += 1;
      if (s.activeListeningDurationSeconds > entry.longestSessionSeconds) {
        entry.longestSessionSeconds = s.activeListeningDurationSeconds;
      }
      if (entry.deviceName.isEmpty && s.deviceName.isNotEmpty) {
        entry.deviceName = s.deviceName;
      }
    }

    for (final r in connectionRecords) {
      final entry = map.putIfAbsent(
        r.deviceId,
        () => _MutableDeviceUsage(deviceId: r.deviceId, deviceName: r.deviceName),
      );
      entry.totalConnectedSeconds += r.durationSeconds;
      if (entry.deviceName.isEmpty && r.deviceName.isNotEmpty) {
        entry.deviceName = r.deviceName;
      }
    }

    final stats = map.values.map((e) => e.toStats()).toList();
    return sortDeviceUsage(stats);
  }

  // =========================================================================
  // 5. Daily Trend Data
  // =========================================================================

  /// Builds chronological daily trend points for every day within [startDate] and [endDate] (inclusive).
  ///
  /// Guarantees:
  /// - Points are chronologically ordered (earliest to latest).
  /// - Preserves empty days with zero-metrics so charts receive a continuous timeline.
  /// - Uses [connectionRecords] for connection time and [sessions] for listening time.
  /// - Alternatively consumes [dailyStatsMap] if precomputed daily stats are available.
  static List<DailyTrendPoint> buildDailyTrends({
    required DateTime startDate,
    required DateTime endDate,
    List<ListeningSession> sessions = const [],
    List<ConnectionRecord> connectionRecords = const [],
    Map<DateTime, PeriodStats>? dailyStatsMap,
  }) {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);

    if (start.isAfter(end)) return [];

    // Pre-index sessions by day
    final sessionsByDay = <DateTime, List<ListeningSession>>{};
    for (final s in sessions) {
      final dayKey = DateTime(s.connectedAt.year, s.connectedAt.month, s.connectedAt.day);
      sessionsByDay.putIfAbsent(dayKey, () => []).add(s);
    }

    // Pre-index connections by day
    final connectionsByDay = <DateTime, List<ConnectionRecord>>{};
    for (final c in connectionRecords) {
      final dayKey = DateTime(c.connectedAt.year, c.connectedAt.month, c.connectedAt.day);
      connectionsByDay.putIfAbsent(dayKey, () => []).add(c);
    }

    // Normalized map for dailyStatsMap
    final Map<DateTime, PeriodStats>? normalizedDailyMap;
    if (dailyStatsMap != null) {
      normalizedDailyMap = {};
      for (final entry in dailyStatsMap.entries) {
        final dayKey = DateTime(entry.key.year, entry.key.month, entry.key.day);
        normalizedDailyMap[dayKey] = entry.value;
      }
    } else {
      normalizedDailyMap = null;
    }

    final points = <DailyTrendPoint>[];
    var current = start;

    while (!current.isAfter(end)) {
      if (normalizedDailyMap != null && normalizedDailyMap.containsKey(current)) {
        final stats = normalizedDailyMap[current]!;
        points.add(DailyTrendPoint(
          date: current,
          listeningSeconds: stats.totalListeningSeconds,
          connectedSeconds: stats.totalConnectedSeconds,
          silentSeconds: stats.totalSilentSeconds,
          sessionCount: stats.sessionCount,
        ));
      } else {
        final daySessions = sessionsByDay[current] ?? const [];
        final dayConnections = connectionsByDay[current] ?? const [];

        int totalListening = 0;
        int totalSilent = 0;
        for (final s in daySessions) {
          totalListening += s.activeListeningDurationSeconds;
          totalSilent += s.silentDurationSeconds;
        }

        int totalConnected = 0;
        for (final c in dayConnections) {
          totalConnected += c.durationSeconds;
        }

        points.add(DailyTrendPoint(
          date: current,
          listeningSeconds: totalListening,
          connectedSeconds: totalConnected,
          silentSeconds: totalSilent,
          sessionCount: daySessions.length,
        ));
      }

      current = DateTime(current.year, current.month, current.day + 1);
    }

    return points;
  }

  // =========================================================================
  // 6. Period Comparison
  // =========================================================================

  /// Compares metrics between two periods (current vs previous).
  static PeriodComparison comparePeriods(PeriodStats current, PeriodStats previous) {
    return PeriodComparison(current: current, previous: previous);
  }
}

/// Type alias allowing callers to refer to [AnalyticsCalculator] as [AnalyticsService].
typedef AnalyticsService = AnalyticsCalculator;

class _MutableDeviceUsage {
  final String deviceId;
  String deviceName;
  int totalListeningSeconds = 0;
  int totalConnectedSeconds = 0;
  int sessionCount = 0;
  int longestSessionSeconds = 0;

  _MutableDeviceUsage({
    required this.deviceId,
    required this.deviceName,
  });

  DeviceUsageStats toStats() {
    return DeviceUsageStats(
      deviceId: deviceId,
      deviceName: deviceName,
      totalListeningSeconds: totalListeningSeconds,
      totalConnectedSeconds: totalConnectedSeconds,
      sessionCount: sessionCount,
      longestSessionSeconds: longestSessionSeconds,
    );
  }
}
