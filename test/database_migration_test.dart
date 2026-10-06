import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/models/connection_record.dart';

void main() {
  group('ConnectionRecord Model Tests', () {
    test('serialization roundtrip preserves all fields', () {
      final now = DateTime.now();
      final record = ConnectionRecord(
        id: 'conn_123',
        deviceId: 'bluetooth_realme_buds_t200_lite',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth A2DP',
        connectedAt: now,
        disconnectedAt: now.add(const Duration(minutes: 90)),
        durationSeconds: 5400,
        status: 'completed',
      );

      final map = record.toMap();
      final fromMap = ConnectionRecord.fromMap(map);

      expect(fromMap.id, equals(record.id));
      expect(fromMap.deviceId, equals(record.deviceId));
      expect(fromMap.deviceName, equals(record.deviceName));
      expect(fromMap.deviceType, equals(record.deviceType));
      expect(fromMap.connectedAt.millisecondsSinceEpoch, equals(record.connectedAt.millisecondsSinceEpoch));
      expect(fromMap.disconnectedAt?.millisecondsSinceEpoch, equals(record.disconnectedAt?.millisecondsSinceEpoch));
      expect(fromMap.durationSeconds, equals(5400));
      expect(fromMap.status, equals('completed'));
      expect(fromMap.durationFormatted, equals('1h 30m 0s'));
      expect(fromMap.durationClock, equals('01:30:00'));
    });

    test('active connection defaults and copyWith', () {
      final now = DateTime.now();
      final record = ConnectionRecord(
        id: 'conn_active',
        deviceId: 'addr_88_c9_e8',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth A2DP',
        connectedAt: now,
        durationSeconds: 0,
        status: 'active',
      );

      expect(record.disconnectedAt, isNull);
      expect(record.status, equals('active'));

      final finalized = record.copyWith(
        disconnectedAt: now.add(const Duration(minutes: 10)),
        durationSeconds: 600,
        status: 'completed',
      );

      expect(finalized.id, equals('conn_active'));
      expect(finalized.status, equals('completed'));
      expect(finalized.durationSeconds, equals(600));
      expect(finalized.durationFormatted, equals('10m 0s'));
    });
  });

  group('DatabaseAdapter ConnectionRecord CRUD Tests', () {
    late DatabaseAdapter adapter;

    setUp(() {
      adapter = InMemoryDatabaseAdapter();
    });

    test('save and retrieve connection records', () async {
      final now = DateTime.now();
      final record = ConnectionRecord(
        id: 'conn_test_1',
        deviceId: 'bt_dev_1',
        deviceName: 'Headphones',
        deviceType: 'Bluetooth A2DP',
        connectedAt: now,
        durationSeconds: 120,
        status: 'active',
      );

      await adapter.saveConnectionRecord(record);

      final fetched = await adapter.getConnectionRecord('conn_test_1');
      expect(fetched, isNotNull);
      expect(fetched!.deviceName, equals('Headphones'));
      expect(fetched.status, equals('active'));

      final active = await adapter.getActiveConnectionRecord(deviceId: 'bt_dev_1');
      expect(active, isNotNull);
      expect(active!.id, equals('conn_test_1'));

      // Finalize
      final updated = record.copyWith(
        disconnectedAt: now.add(const Duration(seconds: 120)),
        status: 'completed',
      );
      await adapter.saveConnectionRecord(updated);

      final noLongerActive = await adapter.getActiveConnectionRecord(deviceId: 'bt_dev_1');
      expect(noLongerActive, isNull);

      final recent = await adapter.getRecentConnectionRecords();
      expect(recent.length, equals(1));
      expect(recent.first.status, equals('completed'));

      final forDay = await adapter.getConnectionRecordsForDay(now);
      expect(forDay.length, equals(1));
    });
  });
}
