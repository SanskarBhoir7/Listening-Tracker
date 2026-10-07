import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/models/connection_record.dart';
import 'package:listening_tracker/models/continuous_session.dart';
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

ContinuousListeningSession _createContinuousSession({
  required String id,
  required DateTime startedAt,
  int activeListeningDurationSeconds = 0,
  int pausedDurationSeconds = 0,
  List<String> deviceIds = const ['dev_1'],
  List<String> deviceNames = const ['Device 1'],
}) {
  return ContinuousListeningSession(
    id: id,
    startedAt: startedAt,
    activeListeningDurationSeconds: activeListeningDurationSeconds,
    pausedDurationSeconds: pausedDurationSeconds,
    deviceIds: deviceIds,
    deviceNames: deviceNames,
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
  group('DeviceUsageStats Model Tests', () {
    test('serialization roundtrip preserves all fields', () {
      final stats = DeviceUsageStats(
        deviceId: 'dev_wh1000xm4',
        deviceName: 'Sony WH-1000XM4',
        totalListeningSeconds: 7200,
        totalConnectedSeconds: 9000,
        sessionCount: 3,
        longestSessionSeconds: 3600,
      );

      final map = stats.toMap();
      final fromMap = DeviceUsageStats.fromMap(map);

      expect(fromMap.deviceId, equals(stats.deviceId));
      expect(fromMap.deviceName, equals(stats.deviceName));
      expect(fromMap.totalListeningSeconds, equals(7200));
      expect(fromMap.totalConnectedSeconds, equals(9000));
      expect(fromMap.sessionCount, equals(3));
      expect(fromMap.longestSessionSeconds, equals(3600));
      expect(fromMap.averageSessionSeconds, equals(2400));
      expect(fromMap.listeningRatio, closeTo(0.8, 0.001));
      expect(fromMap.totalListeningFormatted, equals('2h'));
      expect(fromMap.totalConnectedFormatted, equals('2h 30m'));
      expect(fromMap.longestSessionFormatted, equals('1h'));
    });

    test('empty factory and zero safety', () {
      final empty = DeviceUsageStats.empty('dev_airpods', 'AirPods Pro');

      expect(empty.deviceId, equals('dev_airpods'));
      expect(empty.deviceName, equals('AirPods Pro'));
      expect(empty.totalListeningSeconds, equals(0));
      expect(empty.totalConnectedSeconds, equals(0));
      expect(empty.sessionCount, equals(0));
      expect(empty.longestSessionSeconds, equals(0));
      expect(empty.averageSessionSeconds, equals(0));
      expect(empty.listeningRatio, equals(0.0));
      expect(empty.totalListeningFormatted, equals('0s'));
    });

    test('listeningRatio clamped to 1.0', () {
      final stats = DeviceUsageStats(
        deviceId: 'dev_1',
        deviceName: 'Device 1',
        totalListeningSeconds: 500,
        totalConnectedSeconds: 200,
        sessionCount: 1,
      );

      expect(stats.listeningRatio, equals(1.0));
    });
  });

  group('PeriodStats Model Tests', () {
    test('serialization roundtrip preserves all fields', () {
      final start = DateTime(2026, 10, 1);
      final end = DateTime(2026, 10, 7);
      final stats = PeriodStats(
        startDate: start,
        endDate: end,
        totalListeningSeconds: 3600,
        totalConnectedSeconds: 5400,
        totalSilentSeconds: 1800,
        sessionCount: 4,
        continuousSessionCount: 2,
        devicesUsedCount: 2,
        longestSessionSeconds: 1800,
      );

      final map = stats.toMap();
      final fromMap = PeriodStats.fromMap(map);

      expect(fromMap.startDate, equals(start));
      expect(fromMap.endDate, equals(end));
      expect(fromMap.totalListeningSeconds, equals(3600));
      expect(fromMap.totalConnectedSeconds, equals(5400));
      expect(fromMap.totalSilentSeconds, equals(1800));
      expect(fromMap.sessionCount, equals(4));
      expect(fromMap.continuousSessionCount, equals(2));
      expect(fromMap.devicesUsedCount, equals(2));
      expect(fromMap.longestSessionSeconds, equals(1800));
      expect(fromMap.averageSessionSeconds, equals(900));
      expect(fromMap.listeningRatio, closeTo(0.666, 0.01));
      expect(fromMap.totalListeningFormatted, equals('1h'));
      expect(fromMap.totalConnectedFormatted, equals('1h 30m'));
      expect(fromMap.totalSilentFormatted, equals('30m'));
    });

    test('empty factory and zero safety', () {
      final start = DateTime(2026, 10, 1);
      final end = DateTime(2026, 10, 7);
      final empty = PeriodStats.empty(start, end);

      expect(empty.startDate, equals(start));
      expect(empty.endDate, equals(end));
      expect(empty.totalListeningSeconds, equals(0));
      expect(empty.totalConnectedSeconds, equals(0));
      expect(empty.totalSilentSeconds, equals(0));
      expect(empty.sessionCount, equals(0));
      expect(empty.continuousSessionCount, equals(0));
      expect(empty.devicesUsedCount, equals(0));
      expect(empty.longestSessionSeconds, equals(0));
      expect(empty.averageSessionSeconds, equals(0));
      expect(empty.listeningRatio, equals(0.0));
      expect(empty.totalListeningFormatted, equals('0s'));
    });
  });

  group('Analytics DatabaseAdapter Queries', () {
    late InMemoryDatabaseAdapter adapter;

    setUp(() {
      adapter = InMemoryDatabaseAdapter();
    });

    // A. Date-range session querying
    test('A. Date-range session querying includes in-range and excludes out-of-range', () async {
      final base = DateTime(2026, 10, 5, 12, 0);

      // Session before range
      await adapter.saveDeviceSession(_createSession(
        id: 's_before',
        deviceId: 'dev_1',
        connectedAt: base.subtract(const Duration(days: 2)),
        activeListeningDurationSeconds: 300,
      ));

      // Session in range
      await adapter.saveDeviceSession(_createSession(
        id: 's_in_1',
        deviceId: 'dev_1',
        connectedAt: base,
        activeListeningDurationSeconds: 600,
      ));

      // Second session in range
      await adapter.saveDeviceSession(_createSession(
        id: 's_in_2',
        deviceId: 'dev_2',
        deviceName: 'Device 2',
        connectedAt: base.add(const Duration(hours: 2)),
        activeListeningDurationSeconds: 1200,
      ));

      // Session after range
      await adapter.saveDeviceSession(_createSession(
        id: 's_after',
        deviceId: 'dev_1',
        connectedAt: base.add(const Duration(days: 3)),
        activeListeningDurationSeconds: 400,
      ));

      final rangeStart = base.subtract(const Duration(hours: 1));
      final rangeEnd = base.add(const Duration(hours: 4));

      final results = await adapter.getDeviceSessionsForDateRange(rangeStart, rangeEnd);

      expect(results.length, equals(2));
      expect(results.map((s) => s.id), containsAll(['s_in_1', 's_in_2']));
      expect(results.map((s) => s.id), isNot(contains('s_before')));
      expect(results.map((s) => s.id), isNot(contains('s_after')));
      // Sorted descending by connectedAt
      expect(results.first.id, equals('s_in_2'));
      expect(results.last.id, equals('s_in_1'));
    });

    // B. Date-range connection querying
    test('B. Date-range connection querying filters correctly', () async {
      final base = DateTime(2026, 10, 5, 12, 0);

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'c_before',
        deviceId: 'dev_1',
        connectedAt: base.subtract(const Duration(days: 1)),
        durationSeconds: 1000,
      ));

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'c_in',
        deviceId: 'dev_1',
        connectedAt: base,
        durationSeconds: 1500,
      ));

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'c_after',
        deviceId: 'dev_1',
        connectedAt: base.add(const Duration(days: 1)),
        durationSeconds: 800,
      ));

      final rangeStart = base.subtract(const Duration(hours: 1));
      final rangeEnd = base.add(const Duration(hours: 1));

      final results = await adapter.getConnectionRecordsForDateRange(rangeStart, rangeEnd);

      expect(results.length, equals(1));
      expect(results.first.id, equals('c_in'));
      expect(results.first.durationSeconds, equals(1500));
    });

    // C. Period statistics
    test('C. Period statistics correctly calculates all metrics', () async {
      final base = DateTime(2026, 10, 5, 10, 0);
      final rangeStart = base.subtract(const Duration(hours: 1));
      final rangeEnd = base.add(const Duration(hours: 6));

      // Device 1: Session 1 (listening: 600s, silent: 100s)
      await adapter.saveDeviceSession(_createSession(
        id: 's1',
        deviceId: 'dev_1',
        deviceName: 'Sony WH-1000XM4',
        connectedAt: base,
        activeListeningDurationSeconds: 600,
        silentDurationSeconds: 100,
      ));

      // Device 2: Session 2 (listening: 1800s, silent: 200s)
      await adapter.saveDeviceSession(_createSession(
        id: 's2',
        deviceId: 'dev_2',
        deviceName: 'realme Buds T200 Lite',
        connectedAt: base.add(const Duration(hours: 2)),
        activeListeningDurationSeconds: 1800,
        silentDurationSeconds: 200,
      ));

      // Connection records: dev_1 connected 1200s, dev_2 connected 2400s
      // METRIC RULE: Total connected time MUST come from connection_records
      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'cr1',
        deviceId: 'dev_1',
        deviceName: 'Sony WH-1000XM4',
        connectedAt: base,
        durationSeconds: 1200,
      ));

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'cr2',
        deviceId: 'dev_2',
        deviceName: 'realme Buds T200 Lite',
        connectedAt: base.add(const Duration(hours: 2)),
        durationSeconds: 2400,
      ));

      // Continuous session
      await adapter.saveContinuousSession(_createContinuousSession(
        id: 'cs1',
        startedAt: base,
        activeListeningDurationSeconds: 600,
      ));

      final stats = await adapter.getPeriodStats(rangeStart, rangeEnd);

      expect(stats.totalListeningSeconds, equals(2400)); // 600 + 1800
      expect(stats.totalConnectedSeconds, equals(3600)); // 1200 + 2400 (from connection_records)
      expect(stats.totalSilentSeconds, equals(300)); // 100 + 200
      expect(stats.sessionCount, equals(2));
      expect(stats.continuousSessionCount, equals(1));
      expect(stats.devicesUsedCount, equals(2));
      expect(stats.longestSessionSeconds, equals(1800)); // Max among sessions
    });

    // D. Per-device aggregation
    test('D. Per-device aggregation combines sessions and separates devices', () async {
      final base = DateTime(2026, 10, 5, 10, 0);
      final rangeStart = base.subtract(const Duration(hours: 1));
      final rangeEnd = base.add(const Duration(hours: 10));

      // Device A has 2 sessions: 500s and 800s listening
      await adapter.saveDeviceSession(_createSession(
        id: 's_a1',
        deviceId: 'dev_a',
        deviceName: 'Device A',
        connectedAt: base,
        activeListeningDurationSeconds: 500,
      ));

      await adapter.saveDeviceSession(_createSession(
        id: 's_a2',
        deviceId: 'dev_a',
        deviceName: 'Device A',
        connectedAt: base.add(const Duration(hours: 2)),
        activeListeningDurationSeconds: 800,
      ));

      // Device A connection: 2000s
      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'cr_a',
        deviceId: 'dev_a',
        deviceName: 'Device A',
        connectedAt: base,
        durationSeconds: 2000,
      ));

      // Device B has 1 session: 300s listening, 600s connected
      await adapter.saveDeviceSession(_createSession(
        id: 's_b',
        deviceId: 'dev_b',
        deviceName: 'Device B',
        connectedAt: base.add(const Duration(hours: 4)),
        activeListeningDurationSeconds: 300,
      ));

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'cr_b',
        deviceId: 'dev_b',
        deviceName: 'Device B',
        connectedAt: base.add(const Duration(hours: 4)),
        durationSeconds: 600,
      ));

      // Device C has connected time ONLY (no audio played)
      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'cr_c',
        deviceId: 'dev_c',
        deviceName: 'Device C',
        connectedAt: base.add(const Duration(hours: 6)),
        durationSeconds: 900,
      ));

      final devStats = await adapter.getDeviceUsageStats(rangeStart, rangeEnd);

      expect(devStats.length, equals(3));

      // Device A: 1300s listening, 2000s connected, 2 sessions, longest 800s
      final statsA = devStats.firstWhere((s) => s.deviceId == 'dev_a');
      expect(statsA.totalListeningSeconds, equals(1300));
      expect(statsA.totalConnectedSeconds, equals(2000));
      expect(statsA.sessionCount, equals(2));
      expect(statsA.longestSessionSeconds, equals(800));

      // Device B: 300s listening, 600s connected, 1 session, longest 300s
      final statsB = devStats.firstWhere((s) => s.deviceId == 'dev_b');
      expect(statsB.totalListeningSeconds, equals(300));
      expect(statsB.totalConnectedSeconds, equals(600));
      expect(statsB.sessionCount, equals(1));
      expect(statsB.longestSessionSeconds, equals(300));

      // Device C: 0s listening, 900s connected, 0 sessions
      final statsC = devStats.firstWhere((s) => s.deviceId == 'dev_c');
      expect(statsC.totalListeningSeconds, equals(0));
      expect(statsC.totalConnectedSeconds, equals(900));
      expect(statsC.sessionCount, equals(0));
      expect(statsC.longestSessionSeconds, equals(0));
    });

    // E. Empty data & zero safety
    test('E. Empty data returns zero-safe statistics without exception', () async {
      final start = DateTime(2026, 10, 1);
      final end = DateTime(2026, 10, 2);

      final stats = await adapter.getPeriodStats(start, end);

      expect(stats.totalListeningSeconds, equals(0));
      expect(stats.totalConnectedSeconds, equals(0));
      expect(stats.totalSilentSeconds, equals(0));
      expect(stats.sessionCount, equals(0));
      expect(stats.continuousSessionCount, equals(0));
      expect(stats.devicesUsedCount, equals(0));
      expect(stats.longestSessionSeconds, equals(0));
      expect(stats.averageSessionSeconds, equals(0));
      expect(stats.listeningRatio, equals(0.0));

      final devStats = await adapter.getDeviceUsageStats(start, end);
      expect(devStats, isEmpty);

      final sessions = await adapter.getDeviceSessionsForDateRange(start, end);
      expect(sessions, isEmpty);

      final connections = await adapter.getConnectionRecordsForDateRange(start, end);
      expect(connections, isEmpty);

      final dates = await adapter.getDatesWithActivity();
      expect(dates, isEmpty);
    });

    // F. Date boundary behavior
    test('F. Date boundary behavior includes exact start and end timestamps', () async {
      final start = DateTime(2026, 10, 5, 0, 0, 0, 0);
      final end = DateTime(2026, 10, 5, 23, 59, 59, 999);

      // Session exactly at start boundary
      await adapter.saveDeviceSession(_createSession(
        id: 's_start',
        deviceId: 'dev_1',
        connectedAt: start,
        activeListeningDurationSeconds: 100,
      ));

      // Session exactly at end boundary
      await adapter.saveDeviceSession(_createSession(
        id: 's_end',
        deviceId: 'dev_1',
        connectedAt: end,
        activeListeningDurationSeconds: 200,
      ));

      // Session 1 ms before start
      await adapter.saveDeviceSession(_createSession(
        id: 's_just_before',
        deviceId: 'dev_1',
        connectedAt: start.subtract(const Duration(milliseconds: 1)),
        activeListeningDurationSeconds: 50,
      ));

      // Session 1 ms after end
      await adapter.saveDeviceSession(_createSession(
        id: 's_just_after',
        deviceId: 'dev_1',
        connectedAt: end.add(const Duration(milliseconds: 1)),
        activeListeningDurationSeconds: 50,
      ));

      final results = await adapter.getDeviceSessionsForDateRange(start, end);

      expect(results.length, equals(2));
      expect(results.map((s) => s.id), containsAll(['s_start', 's_end']));
      expect(results.map((s) => s.id), isNot(contains('s_just_before')));
      expect(results.map((s) => s.id), isNot(contains('s_just_after')));
    });

    // Dates with activity query
    test('Distinct dates with activity query collates sessions and connection dates', () async {
      final day1 = DateTime(2026, 10, 5, 10, 30);
      final day1Later = DateTime(2026, 10, 5, 18, 45);
      final day2 = DateTime(2026, 10, 6, 9, 15);

      await adapter.saveDeviceSession(_createSession(
        id: 's1',
        deviceId: 'dev_1',
        connectedAt: day1,
      ));

      await adapter.saveDeviceSession(_createSession(
        id: 's2',
        deviceId: 'dev_1',
        connectedAt: day1Later,
      ));

      await adapter.saveConnectionRecord(_createConnectionRecord(
        id: 'c1',
        deviceId: 'dev_1',
        connectedAt: day2,
        durationSeconds: 100,
      ));

      final dates = await adapter.getDatesWithActivity();

      expect(dates.length, equals(2));
      expect(dates[0], equals(DateTime(2026, 10, 6))); // sorted descending
      expect(dates[1], equals(DateTime(2026, 10, 5)));
    });
  });
}
