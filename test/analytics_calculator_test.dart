import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/analytics_calculator.dart';
import 'package:listening_tracker/models/connection_record.dart';
import 'package:listening_tracker/models/device_usage_stats.dart';
import 'package:listening_tracker/models/listening_session.dart';
import 'package:listening_tracker/models/period_stats.dart';

ListeningSession _createSession({
  required String id,
  required String deviceId,
  String deviceName = 'Device 1',
  String deviceType = 'Bluetooth A2DP',
  required DateTime connectedAt,
  int activeListeningDurationSeconds = 0,
  int connectedDurationSeconds = 0,
  int silentDurationSeconds = 0,
}) {
  return ListeningSession(
    id: id,
    deviceId: deviceId,
    deviceName: deviceName,
    deviceType: deviceType,
    connectedAt: connectedAt,
    connectedDurationSeconds: connectedDurationSeconds,
    activeListeningDurationSeconds: activeListeningDurationSeconds,
    silentDurationSeconds: silentDurationSeconds,
  );
}

ConnectionRecord _createConnectionRecord({
  required String id,
  required String deviceId,
  String deviceName = 'Device 1',
  String deviceType = 'Bluetooth A2DP',
  required DateTime connectedAt,
  int durationSeconds = 0,
  String status = 'completed',
}) {
  return ConnectionRecord(
    id: id,
    deviceId: deviceId,
    deviceName: deviceName,
    deviceType: deviceType,
    connectedAt: connectedAt,
    durationSeconds: durationSeconds,
    status: status,
  );
}

void main() {
  group('DailyTrendPoint Model Tests', () {
    test('serialization roundtrip and getters', () {
      final date = DateTime(2026, 10, 5);
      final point = DailyTrendPoint(
        date: date,
        listeningSeconds: 3600,
        connectedSeconds: 7200,
        silentSeconds: 1200,
        sessionCount: 3,
      );

      final map = point.toMap();
      final fromMap = DailyTrendPoint.fromMap(map);

      expect(fromMap.date, equals(date));
      expect(fromMap.listeningSeconds, equals(3600));
      expect(fromMap.connectedSeconds, equals(7200));
      expect(fromMap.silentSeconds, equals(1200));
      expect(fromMap.sessionCount, equals(3));
      expect(fromMap.listeningRatio, equals(0.5));
      expect(fromMap.hasActivity, isTrue);
      expect(fromMap.listeningFormatted, equals('1h'));
      expect(fromMap.connectedFormatted, equals('2h'));
    });

    test('empty factory and zero safety', () {
      final date = DateTime(2026, 10, 5);
      final empty = DailyTrendPoint.empty(date);

      expect(empty.listeningSeconds, equals(0));
      expect(empty.connectedSeconds, equals(0));
      expect(empty.silentSeconds, equals(0));
      expect(empty.sessionCount, equals(0));
      expect(empty.listeningRatio, equals(0.0));
      expect(empty.hasActivity, isFalse);
    });
  });

  group('PeriodComparison Model Tests', () {
    test('calculates differences and percentage changes', () {
      final start1 = DateTime(2026, 10, 1);
      final end1 = DateTime(2026, 10, 7);
      final previous = PeriodStats(
        startDate: start1,
        endDate: end1,
        totalListeningSeconds: 3600,
        totalConnectedSeconds: 7200,
        totalSilentSeconds: 1800,
        sessionCount: 4,
        continuousSessionCount: 2,
        devicesUsedCount: 1,
        longestSessionSeconds: 1800,
      );

      final start2 = DateTime(2026, 10, 8);
      final end2 = DateTime(2026, 10, 14);
      final current = PeriodStats(
        startDate: start2,
        endDate: end2,
        totalListeningSeconds: 5400,
        totalConnectedSeconds: 9000,
        totalSilentSeconds: 1200,
        sessionCount: 6,
        continuousSessionCount: 3,
        devicesUsedCount: 2,
        longestSessionSeconds: 2400,
      );

      final comparison = PeriodComparison(current: current, previous: previous);

      expect(comparison.listeningSecondsDifference, equals(1800));
      expect(comparison.connectedSecondsDifference, equals(1800));
      expect(comparison.sessionCountDifference, equals(2));
      expect(comparison.listeningPercentageChange, equals(50.0));
      expect(comparison.connectedPercentageChange, equals(25.0));
      expect(comparison.isListeningIncreased, isTrue);
      expect(comparison.isListeningDecreased, isFalse);
      expect(comparison.isListeningEqual, isFalse);
    });

    test('zero denominator handling never produces NaN or Infinity', () {
      final emptyPrevious = PeriodStats.empty(DateTime(2026, 10, 1), DateTime(2026, 10, 7));
      final currentWithListening = PeriodStats(
        startDate: DateTime(2026, 10, 8),
        endDate: DateTime(2026, 10, 14),
        totalListeningSeconds: 1800,
        totalConnectedSeconds: 3600,
        totalSilentSeconds: 0,
        sessionCount: 2,
        continuousSessionCount: 1,
        devicesUsedCount: 1,
        longestSessionSeconds: 900,
      );

      final comp = PeriodComparison(current: currentWithListening, previous: emptyPrevious);

      expect(comp.listeningPercentageChange, equals(100.0));
      expect(comp.listeningPercentageChange.isFinite, isTrue);

      final bothEmpty = PeriodComparison(current: emptyPrevious, previous: emptyPrevious);
      expect(bothEmpty.listeningPercentageChange, equals(0.0));
      expect(bothEmpty.connectedPercentageChange, equals(0.0));
      expect(bothEmpty.isListeningEqual, isTrue);
    });
  });

  group('A. Average Session Duration Calculations', () {
    test('normal values calculate correctly', () {
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(1800, 3), equals(600));
      expect(
        AnalyticsCalculator.calculateAverageSessionDuration(1800, 3),
        equals(const Duration(seconds: 600)),
      );
    });

    test('zero sessions returns 0 safely without division-by-zero', () {
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(1800, 0), equals(0));
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(0, 0), equals(0));
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(-100, 2), equals(0));
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(500, -1), equals(0));
    });

    test('fractional and rounding behavior uses standard rounding', () {
      // 100 / 3 = 33.333 -> 33
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(100, 3), equals(33));
      // 101 / 3 = 33.666 -> 34
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(101, 3), equals(34));
      // 100 / 6 = 16.666 -> 17
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(100, 6), equals(17));
    });

    test('averageSessionSecondsFromSessions calculates from session list', () {
      final now = DateTime(2026, 10, 5);
      final sessions = [
        _createSession(id: 's1', deviceId: 'd1', connectedAt: now, activeListeningDurationSeconds: 400),
        _createSession(id: 's2', deviceId: 'd1', connectedAt: now, activeListeningDurationSeconds: 600),
      ];

      expect(AnalyticsCalculator.averageSessionSecondsFromSessions(sessions), equals(500));
      expect(
        AnalyticsCalculator.averageSessionDurationFromSessions(sessions),
        equals(const Duration(seconds: 500)),
      );

      // Empty list
      expect(AnalyticsCalculator.averageSessionSecondsFromSessions([]), equals(0));
      expect(
        AnalyticsCalculator.averageSessionDurationFromSessions([]),
        equals(Duration.zero),
      );
    });
  });

  group('B. Listening Ratio Calculations', () {
    test('normal case produces expected ratio', () {
      expect(AnalyticsCalculator.calculateListeningRatio(600, 1200), equals(0.5));
    });

    test('zero connection time returns 0.0 safely without NaN or Infinity', () {
      final ratio = AnalyticsCalculator.calculateListeningRatio(600, 0);
      expect(ratio, equals(0.0));
      expect(ratio.isNaN, isFalse);
      expect(ratio.isInfinite, isFalse);
    });

    test('listening time equal to connection time returns 1.0', () {
      expect(AnalyticsCalculator.calculateListeningRatio(1200, 1200), equals(1.0));
    });

    test('listening time greater than connection time clamps safely to 1.0', () {
      expect(AnalyticsCalculator.calculateListeningRatio(1500, 1000), equals(1.0));
    });

    test('negative values return 0.0 safely', () {
      expect(AnalyticsCalculator.calculateListeningRatio(-500, 1000), equals(0.0));
      expect(AnalyticsCalculator.calculateListeningRatio(500, -1000), equals(0.0));
    });

    test('helpers from stats and device usage models match', () {
      final period = PeriodStats(
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 7),
        totalListeningSeconds: 1500,
        totalConnectedSeconds: 3000,
        totalSilentSeconds: 0,
        sessionCount: 1,
        continuousSessionCount: 0,
        devicesUsedCount: 1,
        longestSessionSeconds: 1500,
      );
      expect(AnalyticsCalculator.calculateListeningRatioFromStats(period), equals(0.5));

      final dev = DeviceUsageStats(
        deviceId: 'd1',
        deviceName: 'Device',
        totalListeningSeconds: 1000,
        totalConnectedSeconds: 2000,
        sessionCount: 1,
      );
      expect(AnalyticsCalculator.calculateDeviceListeningRatio(dev), equals(0.5));
    });
  });

  group('C. Longest Session Calculations', () {
    test('multiple sessions selects highest active listening duration', () {
      final now = DateTime(2026, 10, 5);
      final sessions = [
        _createSession(
          id: 's1',
          deviceId: 'd1',
          connectedAt: now,
          activeListeningDurationSeconds: 600,
          connectedDurationSeconds: 3000, // higher connected duration
        ),
        _createSession(
          id: 's2',
          deviceId: 'd1',
          connectedAt: now.add(const Duration(hours: 1)),
          activeListeningDurationSeconds: 1800, // HIGHEST active listening
          connectedDurationSeconds: 2000,
        ),
        _createSession(
          id: 's3',
          deviceId: 'd1',
          connectedAt: now.add(const Duration(hours: 2)),
          activeListeningDurationSeconds: 900,
          connectedDurationSeconds: 1000,
        ),
      ];

      // CRITICAL METRIC RULE: must use activeListeningDurationSeconds, NOT connectedDurationSeconds
      expect(AnalyticsCalculator.findLongestSessionSeconds(sessions), equals(1800));
      final longest = AnalyticsCalculator.findLongestSession(sessions);
      expect(longest, isNotNull);
      expect(longest!.id, equals('s2'));
      expect(longest.activeListeningDurationSeconds, equals(1800));
    });

    test('one session returns that session', () {
      final now = DateTime(2026, 10, 5);
      final session = _createSession(
        id: 's_only',
        deviceId: 'd1',
        connectedAt: now,
        activeListeningDurationSeconds: 450,
      );

      expect(AnalyticsCalculator.findLongestSessionSeconds([session]), equals(450));
      expect(AnalyticsCalculator.findLongestSession([session])?.id, equals('s_only'));
    });

    test('empty list returns 0 and null', () {
      expect(AnalyticsCalculator.findLongestSessionSeconds([]), equals(0));
      expect(AnalyticsCalculator.findLongestSession([]), isNull);
    });
  });

  group('D. Most-Used Device Calculations', () {
    test('multiple devices selects device with highest listening duration', () {
      final dev1 = DeviceUsageStats(
        deviceId: 'dev_1',
        deviceName: 'Device 1',
        totalListeningSeconds: 1000,
        totalConnectedSeconds: 2000,
        sessionCount: 2,
      );
      final dev2 = DeviceUsageStats(
        deviceId: 'dev_2',
        deviceName: 'Device 2',
        totalListeningSeconds: 2500, // Winner
        totalConnectedSeconds: 3000,
        sessionCount: 3,
      );
      final dev3 = DeviceUsageStats(
        deviceId: 'dev_3',
        deviceName: 'Device 3',
        totalListeningSeconds: 500,
        totalConnectedSeconds: 1000,
        sessionCount: 1,
      );

      final mostUsed = AnalyticsCalculator.findMostUsedDevice([dev1, dev2, dev3]);
      expect(mostUsed, isNotNull);
      expect(mostUsed!.deviceId, equals('dev_2'));
      expect(mostUsed.totalListeningSeconds, equals(2500));
    });

    test('same device with multiple sessions in aggregate', () {
      final now = DateTime(2026, 10, 5);
      final sessions = [
        _createSession(id: 's1', deviceId: 'd_sony', activeListeningDurationSeconds: 600, connectedAt: now),
        _createSession(id: 's2', deviceId: 'd_sony', activeListeningDurationSeconds: 800, connectedAt: now),
        _createSession(id: 's3', deviceId: 'd_buds', activeListeningDurationSeconds: 1000, connectedAt: now),
      ];
      final connections = [
        _createConnectionRecord(id: 'c1', deviceId: 'd_sony', durationSeconds: 2000, connectedAt: now),
        _createConnectionRecord(id: 'c2', deviceId: 'd_buds', durationSeconds: 1500, connectedAt: now),
      ];

      final aggregated = AnalyticsCalculator.aggregateDeviceUsageFromRecords(
        sessions: sessions,
        connectionRecords: connections,
      );

      // Sony total: 600 + 800 = 1400s; Buds: 1000s -> Sony wins
      final mostUsed = AnalyticsCalculator.findMostUsedDevice(aggregated);
      expect(mostUsed, isNotNull);
      expect(mostUsed!.deviceId, equals('d_sony'));
      expect(mostUsed.totalListeningSeconds, equals(1400));
    });

    test('tie handling uses deterministic tie breakers', () {
      // Tie on listening seconds -> broken by connected seconds
      final devA = DeviceUsageStats(
        deviceId: 'dev_a',
        deviceName: 'A',
        totalListeningSeconds: 1000,
        totalConnectedSeconds: 2000, // Higher connected time
        sessionCount: 2,
      );
      final devB = DeviceUsageStats(
        deviceId: 'dev_b',
        deviceName: 'B',
        totalListeningSeconds: 1000,
        totalConnectedSeconds: 1500,
        sessionCount: 3,
      );

      final winner1 = AnalyticsCalculator.findMostUsedDevice([devB, devA]);
      expect(winner1!.deviceId, equals('dev_a'));

      // Tie on listening AND connected seconds -> broken by session count
      final devC = DeviceUsageStats(
        deviceId: 'dev_c',
        deviceName: 'C',
        totalListeningSeconds: 1000,
        totalConnectedSeconds: 2000,
        sessionCount: 5, // Higher session count
      );

      final winner2 = AnalyticsCalculator.findMostUsedDevice([devA, devC]);
      expect(winner2!.deviceId, equals('dev_c'));

      // Complete tie -> broken by deviceId ASC
      final devD1 = DeviceUsageStats(
        deviceId: 'dev_alpha',
        deviceName: 'Alpha',
        totalListeningSeconds: 500,
        totalConnectedSeconds: 1000,
        sessionCount: 1,
      );
      final devD2 = DeviceUsageStats(
        deviceId: 'dev_beta',
        deviceName: 'Beta',
        totalListeningSeconds: 500,
        totalConnectedSeconds: 1000,
        sessionCount: 1,
      );

      final winner3 = AnalyticsCalculator.findMostUsedDevice([devD2, devD1]);
      expect(winner3!.deviceId, equals('dev_alpha'));
    });

    test('empty list returns null', () {
      expect(AnalyticsCalculator.findMostUsedDevice([]), isNull);
    });

    test('connection-only device handled correctly', () {
      final connOnly1 = DeviceUsageStats(
        deviceId: 'dev_car',
        deviceName: 'Car Bluetooth',
        totalListeningSeconds: 0,
        totalConnectedSeconds: 3600,
        sessionCount: 0,
      );
      final connOnly2 = DeviceUsageStats(
        deviceId: 'dev_speaker',
        deviceName: 'Desk Speaker',
        totalListeningSeconds: 0,
        totalConnectedSeconds: 1800,
        sessionCount: 0,
      );

      final top = AnalyticsCalculator.findMostUsedDevice([connOnly2, connOnly1]);
      expect(top, isNotNull);
      expect(top!.deviceId, equals('dev_car'));
      expect(top.totalConnectedSeconds, equals(3600));
      expect(top.totalListeningSeconds, equals(0));
    });
  });

  group('E. Daily Trends Calculations', () {
    test('multiple dates and strict chronological ordering', () {
      final start = DateTime(2026, 10, 1);
      final end = DateTime(2026, 10, 5);

      final sessions = [
        // Oct 2
        _createSession(
          id: 's_oct2',
          deviceId: 'd1',
          connectedAt: DateTime(2026, 10, 2, 14, 0),
          activeListeningDurationSeconds: 1200,
          silentDurationSeconds: 100,
        ),
        // Oct 4
        _createSession(
          id: 's_oct4',
          deviceId: 'd1',
          connectedAt: DateTime(2026, 10, 4, 9, 30),
          activeListeningDurationSeconds: 2400,
          silentDurationSeconds: 200,
        ),
      ];

      final connections = [
        // Oct 2
        _createConnectionRecord(
          id: 'c_oct2',
          deviceId: 'd1',
          connectedAt: DateTime(2026, 10, 2, 14, 0),
          durationSeconds: 1500,
        ),
        // Oct 3 (connection only!)
        _createConnectionRecord(
          id: 'c_oct3',
          deviceId: 'd1',
          connectedAt: DateTime(2026, 10, 3, 11, 0),
          durationSeconds: 800,
        ),
        // Oct 4
        _createConnectionRecord(
          id: 'c_oct4',
          deviceId: 'd1',
          connectedAt: DateTime(2026, 10, 4, 9, 30),
          durationSeconds: 3000,
        ),
      ];

      final trends = AnalyticsCalculator.buildDailyTrends(
        startDate: start,
        endDate: end,
        sessions: sessions,
        connectionRecords: connections,
      );

      expect(trends.length, equals(5));

      // Strictly chronological
      expect(trends[0].date, equals(DateTime(2026, 10, 1)));
      expect(trends[1].date, equals(DateTime(2026, 10, 2)));
      expect(trends[2].date, equals(DateTime(2026, 10, 3)));
      expect(trends[3].date, equals(DateTime(2026, 10, 4)));
      expect(trends[4].date, equals(DateTime(2026, 10, 5)));

      // Oct 1 is empty
      expect(trends[0].listeningSeconds, equals(0));
      expect(trends[0].connectedSeconds, equals(0));
      expect(trends[0].hasActivity, isFalse);

      // Oct 2 has listening 1200s, connected 1500s
      expect(trends[1].listeningSeconds, equals(1200));
      expect(trends[1].connectedSeconds, equals(1500));
      expect(trends[1].sessionCount, equals(1));
      expect(trends[1].hasActivity, isTrue);

      // Oct 3 has connection only: 0s listening, 800s connected
      expect(trends[2].listeningSeconds, equals(0));
      expect(trends[2].connectedSeconds, equals(800));
      expect(trends[2].sessionCount, equals(0));
      expect(trends[2].hasActivity, isTrue);

      // Oct 4 has listening 2400s, connected 3000s
      expect(trends[3].listeningSeconds, equals(2400));
      expect(trends[3].connectedSeconds, equals(3000));
      expect(trends[3].sessionCount, equals(1));

      // Oct 5 is empty
      expect(trends[4].listeningSeconds, equals(0));
      expect(trends[4].hasActivity, isFalse);
    });

    test('dailyStatsMap input variant generates matching trends', () {
      final start = DateTime(2026, 10, 1);
      final end = DateTime(2026, 10, 2);

      final map = {
        DateTime(2026, 10, 1): PeriodStats(
          startDate: DateTime(2026, 10, 1),
          endDate: DateTime(2026, 10, 1, 23, 59),
          totalListeningSeconds: 900,
          totalConnectedSeconds: 1800,
          totalSilentSeconds: 100,
          sessionCount: 1,
          continuousSessionCount: 1,
          devicesUsedCount: 1,
          longestSessionSeconds: 900,
        ),
      };

      final trends = AnalyticsCalculator.buildDailyTrends(
        startDate: start,
        endDate: end,
        dailyStatsMap: map,
      );

      expect(trends.length, equals(2));
      expect(trends[0].listeningSeconds, equals(900));
      expect(trends[0].connectedSeconds, equals(1800));
      expect(trends[1].listeningSeconds, equals(0));
      expect(trends[1].connectedSeconds, equals(0));
    });

    test('inverted date range returns empty list', () {
      final trends = AnalyticsCalculator.buildDailyTrends(
        startDate: DateTime(2026, 10, 10),
        endDate: DateTime(2026, 10, 5),
      );
      expect(trends, isEmpty);
    });
  });

  group('F. Device Analytics Calculations', () {
    test('sortDeviceUsage sorts by listening DESC, connected DESC, count DESC', () {
      final devices = [
        DeviceUsageStats(deviceId: 'd3', deviceName: '3', totalListeningSeconds: 100, totalConnectedSeconds: 100, sessionCount: 1),
        DeviceUsageStats(deviceId: 'd1', deviceName: '1', totalListeningSeconds: 500, totalConnectedSeconds: 1000, sessionCount: 2),
        DeviceUsageStats(deviceId: 'd2', deviceName: '2', totalListeningSeconds: 300, totalConnectedSeconds: 500, sessionCount: 1),
      ];

      final sorted = AnalyticsCalculator.sortDeviceUsage(devices);
      expect(sorted[0].deviceId, equals('d1'));
      expect(sorted[1].deviceId, equals('d2'));
      expect(sorted[2].deviceId, equals('d3'));
    });

    test('connection-only device detection and filtering', () {
      final active = DeviceUsageStats(
        deviceId: 'd_active',
        deviceName: 'Active',
        totalListeningSeconds: 500,
        totalConnectedSeconds: 800,
        sessionCount: 1,
      );
      final connOnly = DeviceUsageStats(
        deviceId: 'd_conn',
        deviceName: 'Conn Only',
        totalListeningSeconds: 0,
        totalConnectedSeconds: 1200,
        sessionCount: 0,
      );
      final zeroAll = DeviceUsageStats(
        deviceId: 'd_zero',
        deviceName: 'Zero',
        totalListeningSeconds: 0,
        totalConnectedSeconds: 0,
        sessionCount: 0,
      );

      expect(AnalyticsCalculator.isConnectionOnly(active), isFalse);
      expect(AnalyticsCalculator.isConnectionOnly(connOnly), isTrue);
      expect(AnalyticsCalculator.isConnectionOnly(zeroAll), isFalse);

      final list = [active, connOnly, zeroAll];
      final filteredConn = AnalyticsCalculator.filterConnectionOnlyDevices(list);
      expect(filteredConn.length, equals(1));
      expect(filteredConn.first.deviceId, equals('d_conn'));

      final filteredActive = AnalyticsCalculator.filterActiveListeningDevices(list);
      expect(filteredActive.length, equals(1));
      expect(filteredActive.first.deviceId, equals('d_active'));
    });

    test('aggregateDeviceUsageFromRecords aggregates correctly', () {
      final now = DateTime(2026, 10, 5);
      final sessions = [
        _createSession(id: 's1', deviceId: 'dev_1', deviceName: 'Headphones', connectedAt: now, activeListeningDurationSeconds: 400),
        _createSession(id: 's2', deviceId: 'dev_1', deviceName: 'Headphones', connectedAt: now, activeListeningDurationSeconds: 600),
      ];
      final connections = [
        _createConnectionRecord(id: 'c1', deviceId: 'dev_1', deviceName: 'Headphones', connectedAt: now, durationSeconds: 1500),
      ];

      final aggregated = AnalyticsCalculator.aggregateDeviceUsageFromRecords(
        sessions: sessions,
        connectionRecords: connections,
      );

      expect(aggregated.length, equals(1));
      expect(aggregated.first.deviceId, equals('dev_1'));
      expect(aggregated.first.totalListeningSeconds, equals(1000));
      expect(aggregated.first.totalConnectedSeconds, equals(1500));
      expect(aggregated.first.sessionCount, equals(2));
      expect(aggregated.first.longestSessionSeconds, equals(600));
    });
  });

  group('G. Empty/Invalid Data Resilience', () {
    test('no exceptions, no NaN, no Infinity across all calculations', () {
      expect(AnalyticsCalculator.calculateAverageSessionSeconds(0, 0), equals(0));
      expect(AnalyticsCalculator.calculateListeningRatio(0, 0), equals(0.0));
      expect(AnalyticsCalculator.findLongestSessionSeconds([]), equals(0));
      expect(AnalyticsCalculator.findLongestSession([]), isNull);
      expect(AnalyticsCalculator.findMostUsedDevice([]), isNull);
      expect(AnalyticsCalculator.sortDeviceUsage([]), isEmpty);
      expect(AnalyticsCalculator.filterConnectionOnlyDevices([]), isEmpty);
      expect(AnalyticsCalculator.filterActiveListeningDevices([]), isEmpty);
      expect(
        AnalyticsCalculator.buildDailyTrends(
          startDate: DateTime(2026, 10, 5),
          endDate: DateTime(2026, 10, 5),
        ).length,
        equals(1),
      );
    });
  });
}
