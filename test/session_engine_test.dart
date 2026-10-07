import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/tracking_state.dart';

void main() {
  late InMemoryDatabaseAdapter db;
  late SessionEngine engine;

  setUp(() {
    db = InMemoryDatabaseAdapter();
    engine = SessionEngine(database: db);
    engine.startMonitoring();
  });

  tearDown(() {
    engine.dispose();
  });

  Map<String, dynamic> btConnectEvent({
    String name = 'realme Buds T200 Lite',
    String connType = 'bluetooth',
    String? address = '88:C9:E8:12:34:56',
    String typeName = 'Bluetooth A2DP',
  }) {
    return {
      'type': 'DEVICE_CONNECTED',
      'deviceName': name,
      'connectionType': connType,
      'deviceAddress': address,
      'deviceType': typeName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> btDisconnectEvent({
    String name = 'realme Buds T200 Lite',
    String connType = 'bluetooth',
    String? address = '88:C9:E8:12:34:56',
    String typeName = 'Bluetooth A2DP',
  }) {
    return {
      'type': 'DEVICE_DISCONNECTED',
      'deviceName': name,
      'connectionType': connType,
      'deviceAddress': address,
      'deviceType': typeName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> audioStartEvent() {
    return {
      'type': 'AUDIO_STARTED',
      'isAudioPlaying': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> audioStopEvent() {
    return {
      'type': 'AUDIO_STOPPED',
      'isAudioPlaying': false,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> outputChangeEvent({
    required String name,
    required String connType,
    String? address,
    String typeName = 'Bluetooth A2DP',
  }) {
    return {
      'type': 'AUDIO_OUTPUT_CHANGED',
      'deviceName': name,
      'connectionType': connType,
      'deviceAddress': address,
      'deviceType': typeName,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  // =========================================================================
  // TEST 1: BT connects, no audio -> connection active, listening idle
  // =========================================================================
  test('TEST 1: BT connects, no audio -> connection active, listening idle', () async {
    await engine.handleNativeEvent(btConnectEvent());

    expect(engine.connectionState, equals(BluetoothConnectionState.connected));
    expect(engine.audioState, equals(AudioPlaybackState.notPlaying));
    expect(engine.sessionState, equals(ListeningSessionState.idle));
    expect(engine.activeConnectionRecord, isNotNull);
    expect(engine.activeConnectionRecord!.status, equals('active'));
    expect(engine.currentDeviceSession, isNull);
  });

  // =========================================================================
  // TEST 2: BT connects while audio not playing -> no listening session in DB
  // =========================================================================
  test('TEST 2: BT connects while audio not playing -> no listening session in DB', () async {
    await engine.handleNativeEvent(btConnectEvent());

    expect(engine.currentDeviceSession, isNull);
    expect(db.deviceSessions, isEmpty);
    expect(db.connectionRecords.length, equals(1));
  });

  // =========================================================================
  // TEST 3: Audio starts while connected -> listening ACTIVE
  // =========================================================================
  test('TEST 3: Audio starts while connected -> listening ACTIVE', () async {
    await engine.handleNativeEvent(btConnectEvent());
    expect(engine.sessionState, equals(ListeningSessionState.idle));

    await engine.handleNativeEvent(audioStartEvent());

    expect(engine.audioState, equals(AudioPlaybackState.playing));
    expect(engine.sessionState, equals(ListeningSessionState.active));
    expect(engine.currentDeviceSession, isNotNull);
    expect(engine.currentDeviceSession!.status, equals('active'));
    expect(engine.currentContinuousSession, isNotNull);
  });

  // =========================================================================
  // TEST 4: Audio stops -> listening GRACE_PERIOD, exactly one grace timer
  // =========================================================================
  test('TEST 4: Audio stops -> listening GRACE_PERIOD, exactly one grace timer', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());
    expect(engine.sessionState, equals(ListeningSessionState.active));

    await engine.handleNativeEvent(audioStopEvent());

    expect(engine.audioState, equals(AudioPlaybackState.notPlaying));
    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));
    expect(engine.isInGracePeriod, isTrue);

    // Sending another stop event does not duplicate or break grace period
    await engine.handleNativeEvent(audioStopEvent());
    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));
    expect(engine.isInGracePeriod, isTrue);
  });

  // =========================================================================
  // TEST 5: Audio resumes before grace expiry -> same listening session resumes
  // =========================================================================
  test('TEST 5: Audio resumes before grace expiry -> same listening session resumes', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());

    final originalSessionId = engine.currentDeviceSession!.id;
    final originalContinuousId = engine.currentContinuousSession!.id;

    await engine.handleNativeEvent(audioStopEvent());
    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));

    // Resume audio within grace period
    await engine.handleNativeEvent(audioStartEvent());

    expect(engine.sessionState, equals(ListeningSessionState.active));
    expect(engine.isInGracePeriod, isFalse);
    expect(engine.currentDeviceSession!.id, equals(originalSessionId));
    expect(engine.currentContinuousSession!.id, equals(originalContinuousId));
  });

  // =========================================================================
  // TEST 6: Grace expires -> listening session ends
  // =========================================================================
  test('TEST 6: Grace expires -> listening session ends', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());
    await engine.handleNativeEvent(audioStopEvent());

    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));

    // Trigger grace period expiration
    await engine.triggerGraceExpiredForTesting();

    expect(engine.sessionState, equals(ListeningSessionState.idle));
    expect(engine.currentDeviceSession, isNull);
    expect(engine.currentContinuousSession, isNull);
    expect(engine.connectionState, equals(BluetoothConnectionState.connected));
    expect(db.deviceSessions.length, equals(1));
    expect(db.deviceSessions.first.status, equals('completed'));
  });

  // =========================================================================
  // TEST 7: BT disconnect while ACTIVE -> finalized immediately, no grace period
  // =========================================================================
  test('TEST 7: BT disconnect while ACTIVE -> finalized immediately, no grace period', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());

    expect(engine.sessionState, equals(ListeningSessionState.active));
    expect(engine.connectionState, equals(BluetoothConnectionState.connected));

    await engine.handleNativeEvent(btDisconnectEvent());

    expect(engine.connectionState, equals(BluetoothConnectionState.disconnected));
    expect(engine.sessionState, equals(ListeningSessionState.idle));
    expect(engine.isInGracePeriod, isFalse);
    expect(engine.activeConnectionRecord, isNull);
    expect(engine.currentDeviceSession, isNull);
    expect(db.connectionRecords.first.status, equals('completed'));
    expect(db.deviceSessions.first.status, equals('completed'));
  });

  // =========================================================================
  // TEST 8: BT disconnect during GRACE_PERIOD -> listening ends immediately, old timer cancelled
  // =========================================================================
  test('TEST 8: BT disconnect during GRACE_PERIOD -> listening ends immediately, old timer cancelled', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());
    await engine.handleNativeEvent(audioStopEvent());

    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));

    // Disconnect occurs during grace
    await engine.handleNativeEvent(btDisconnectEvent());

    expect(engine.sessionState, equals(ListeningSessionState.idle));
    expect(engine.isInGracePeriod, isFalse);
    expect(engine.connectionState, equals(BluetoothConnectionState.disconnected));

    // Expiration after disconnect must be a no-op
    await engine.triggerGraceExpiredForTesting();
    expect(engine.sessionState, equals(ListeningSessionState.idle));
  });

  // =========================================================================
  // TEST 9: BT reconnect -> creates distinct new ConnectionRecord
  // =========================================================================
  test('TEST 9: BT reconnect -> creates distinct new ConnectionRecord', () async {
    await engine.handleNativeEvent(btConnectEvent());
    final firstRecordId = engine.activeConnectionRecord!.id;

    await engine.handleNativeEvent(btDisconnectEvent());
    expect(engine.activeConnectionRecord, isNull);

    await Future.delayed(const Duration(milliseconds: 2));

    await engine.handleNativeEvent(btConnectEvent());
    final secondRecordId = engine.activeConnectionRecord!.id;

    expect(firstRecordId, isNot(equals(secondRecordId)));
    expect(db.connectionRecords.length, equals(2));
  });

  // =========================================================================
  // TEST 10: Duplicate BT_CONNECTED -> no duplicate connection record
  // =========================================================================
  test('TEST 10: Duplicate BT_CONNECTED -> no duplicate connection record', () async {
    await engine.handleNativeEvent(btConnectEvent());
    final recordId = engine.activeConnectionRecord!.id;

    // Send duplicate event for the same device
    await engine.handleNativeEvent(btConnectEvent());

    expect(engine.activeConnectionRecord!.id, equals(recordId));
    expect(db.connectionRecords.length, equals(1));
  });

  // =========================================================================
  // TEST 11: Duplicate AUDIO_STARTED -> no duplicate listening session
  // =========================================================================
  test('TEST 11: Duplicate AUDIO_STARTED -> no duplicate listening session', () async {
    await engine.handleNativeEvent(btConnectEvent());
    await engine.handleNativeEvent(audioStartEvent());

    final sessionId = engine.currentDeviceSession!.id;

    // Send duplicate AUDIO_STARTED
    await engine.handleNativeEvent(audioStartEvent());

    expect(engine.currentDeviceSession!.id, equals(sessionId));
    expect(engine.sessionState, equals(ListeningSessionState.active));
  });

  // =========================================================================
  // TEST 12: Output-device change -> ends old connection, starts new connection
  // =========================================================================
  test('TEST 12: Output-device change -> ends old connection, starts new connection', () async {
    // Device A connects, audio starts
    await engine.handleNativeEvent(btConnectEvent(name: 'Device A', address: '11:22:33:44:55:66'));
    await engine.handleNativeEvent(audioStartEvent());

    final deviceAConnectionId = engine.activeConnectionRecord!.id;
    final deviceASessionId = engine.currentDeviceSession!.id;

    await Future.delayed(const Duration(milliseconds: 2));

    // Output switches to Device B while audio playing
    await engine.handleNativeEvent(outputChangeEvent(
      name: 'Device B',
      connType: 'bluetooth',
      address: 'AA:BB:CC:DD:EE:FF',
    ));

    expect(engine.activeConnectionRecord!.id, isNot(equals(deviceAConnectionId)));
    expect(engine.activeConnectionRecord!.deviceName, equals('Device B'));
    expect(engine.currentDeviceSession!.id, isNot(equals(deviceASessionId)));
    expect(engine.currentDeviceSession!.deviceName, equals('Device B'));
    expect(engine.sessionState, equals(ListeningSessionState.active));

    // Device A's connection record was finalized
    final devARecord = db.connectionRecords.firstWhere((r) => r.id == deviceAConnectionId);
    expect(devARecord.status, equals('completed'));
  });

  // =========================================================================
  // TEST 13: Lifecycle/state snapshot -> actual native state is reconciled correctly
  // =========================================================================
  test('TEST 13: Lifecycle/state snapshot -> reconciles correctly without losing state', () async {
    final snapshot = {
      'isAudioPlaying': true,
      'outputDeviceName': 'Sony WH-1000XM4',
      'outputDeviceType': 'Bluetooth A2DP',
      'outputConnectionType': 'bluetooth',
      'outputDeviceAddress': '12:34:56:78:90:AB',
      'connectedDevices': [
        {
          'id': 1,
          'name': 'Sony WH-1000XM4',
          'typeName': 'Bluetooth A2DP',
          'connectionType': 'bluetooth',
          'address': '12:34:56:78:90:AB',
        }
      ],
    };

    await engine.processStateSnapshot(snapshot);

    expect(engine.connectionState, equals(BluetoothConnectionState.connected));
    expect(engine.audioState, equals(AudioPlaybackState.playing));
    expect(engine.sessionState, equals(ListeningSessionState.active));
    expect(engine.activeOutputDevice!.name, equals('Sony WH-1000XM4'));
    expect(engine.currentDeviceSession, isNotNull);
  });

  // =========================================================================
  // TEST 14: Stale grace timer -> cannot modify a newer listening session
  // =========================================================================
  test('TEST 14: Stale grace timer cannot modify a newer listening session', () async {
    // Session A starts and stops -> enters grace
    await engine.handleNativeEvent(btConnectEvent(name: 'Earbuds 1', address: '00:11:22:33:44:55'));
    await engine.handleNativeEvent(audioStartEvent());
    await engine.handleNativeEvent(audioStopEvent());
    expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));

    // Disconnect Earbuds 1 -> ends Session A and invalidates timer token
    await engine.handleNativeEvent(btDisconnectEvent(name: 'Earbuds 1', address: '00:11:22:33:44:55'));
    expect(engine.sessionState, equals(ListeningSessionState.idle));

    // Reconnect and start Session B
    await engine.handleNativeEvent(btConnectEvent(name: 'Earbuds 2', address: '66:77:88:99:AA:BB'));
    await engine.handleNativeEvent(audioStartEvent());
    expect(engine.sessionState, equals(ListeningSessionState.active));
    final sessionBId = engine.currentDeviceSession!.id;

    // Simulate stale timer callback firing; token check prevents it from affecting Session B
    await engine.triggerGraceExpiredForTesting();

    // Session B must NOT have been closed by Earbuds 1's timer!
    expect(engine.sessionState, equals(ListeningSessionState.active));
    expect(engine.currentDeviceSession!.id, equals(sessionBId));
  });

  // =========================================================================
  // RACE-CONDITION & SINGLE-SHOT FINALIZATION TESTS
  // =========================================================================
  test('RACE CONDITION FIX: Bluetooth disconnect followed immediately by output-change emits CONNECTION_ENDED and LISTENING_ENDED exactly once', () async {
    final emittedEvents = <String>[];
    engine.onTrackingEvent = (e) => emittedEvents.add(e.eventType);

    // 1. Connect and start active listening
    await engine.handleNativeEvent(btConnectEvent(name: 'realme Buds T200 Lite'));
    await engine.handleNativeEvent(audioStartEvent());
    expect(engine.connectionState, equals(BluetoothConnectionState.connected));
    expect(engine.sessionState, equals(ListeningSessionState.active));

    // 2. Disconnect Bluetooth, followed immediately by OUTPUT_CHANGED (e.g. Phone Speaker)
    await engine.handleNativeEvent(btDisconnectEvent(name: 'realme Buds T200 Lite'));
    await engine.handleNativeEvent(outputChangeEvent(name: 'Phone Speaker', connType: 'internal'));

    // Count occurrences of finalization events
    final connectionEndedCount = emittedEvents.where((e) => e == 'CONNECTION_ENDED').length;
    final listeningEndedCount = emittedEvents.where((e) => e == 'LISTENING_ENDED').length;

    expect(connectionEndedCount, equals(1), reason: 'CONNECTION_ENDED must be emitted exactly once');
    expect(listeningEndedCount, equals(1), reason: 'LISTENING_ENDED must be emitted exactly once');

    // Verify database contains exactly one completed connection record and one completed session
    expect(db.connectionRecords.length, equals(1));
    expect(db.connectionRecords.first.status, equals('completed'));
    expect(db.deviceSessions.length, equals(1));
    expect(db.deviceSessions.first.status, equals('completed'));

    // Verify engine active references are cleared
    expect(engine.activeConnectionRecord, isNull);
    expect(engine.currentDeviceSession, isNull);
  });

  test('RACE CONDITION FIX: Rapid duplicate disconnect events do not re-finalize or duplicate records', () async {
    final emittedEvents = <String>[];
    engine.onTrackingEvent = (e) => emittedEvents.add(e.eventType);

    await engine.handleNativeEvent(btConnectEvent(name: 'realme Buds T200 Lite'));
    await engine.handleNativeEvent(audioStartEvent());

    // Send two identical disconnect events in sequence
    await engine.handleNativeEvent(btDisconnectEvent(name: 'realme Buds T200 Lite'));
    await engine.handleNativeEvent(btDisconnectEvent(name: 'realme Buds T200 Lite'));

    final connectionEndedCount = emittedEvents.where((e) => e == 'CONNECTION_ENDED').length;
    final listeningEndedCount = emittedEvents.where((e) => e == 'LISTENING_ENDED').length;

    expect(connectionEndedCount, equals(1));
    expect(listeningEndedCount, equals(1));
    expect(db.connectionRecords.length, equals(1));
    expect(db.deviceSessions.length, equals(1));
  });

  test('RACE CONDITION FIX: Active references are detached before async persistence', () async {
    bool referencesWereClearedDuringSave = false;

    // Use a custom DatabaseAdapter hook to inspect engine state during the save operation
    final slowDb = HookedDatabaseAdapter(
      onSaveConnection: () {
        if (engine.activeConnectionRecord == null) {
          referencesWereClearedDuringSave = true;
        }
      },
    );

    final testEngine = SessionEngine(database: slowDb);
    testEngine.startMonitoring();

    await testEngine.handleNativeEvent(btConnectEvent());
    await testEngine.handleNativeEvent(btDisconnectEvent());

    expect(referencesWereClearedDuringSave, isTrue,
        reason: 'Active connection reference must be null before the DB save completes');

    testEngine.dispose();
  });
}

class HookedDatabaseAdapter extends InMemoryDatabaseAdapter {
  final void Function()? onSaveConnection;

  HookedDatabaseAdapter({this.onSaveConnection});

  @override
  Future<void> saveConnectionRecord(record) async {
    onSaveConnection?.call();
    return super.saveConnectionRecord(record);
  }
}

