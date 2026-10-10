import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/database/database_helper.dart';
import 'package:listening_tracker/models/connection_record.dart';
import 'package:listening_tracker/models/diagnostic_event.dart';
import 'package:listening_tracker/models/listening_session.dart';
import 'package:listening_tracker/services/diagnostic_logger.dart';

void main() {
  group('DiagnosticEvent Model Tests', () {
    test('serialization roundtrip preserves all fields including signals', () {
      final now = DateTime.now();
      final event = DiagnosticEvent(
        id: 'diag_123',
        timestamp: now.millisecondsSinceEpoch,
        timestampIso: now.toIso8601String(),
        eventType: 'AUDIO_STOPPED',
        source: 'native',
        deviceName: 'realme Buds T200 Lite',
        deviceId: 'bt_realme_123',
        reason: 'no_active_media_or_sound',
        sessionState: 'active',
        connectionState: 'connected',
        stopConfirmationStatus: 'CONFIRMED',
        playbackConfigsCount: 0,
        activeMediaCount: 0,
        playbackStates: '[]',
        isMusicActive: false,
        isA2dpStreaming: false,
        prevPlaying: true,
        resolvedPlaying: false,
        resolverReason: 'no_active_media_or_sound',
        errorDetails: null,
        metadata: {'extra': 'test'},
      );

      final map = event.toMap();
      final fromMap = DiagnosticEvent.fromMap(map);

      expect(fromMap.id, equals('diag_123'));
      expect(fromMap.eventType, equals('AUDIO_STOPPED'));
      expect(fromMap.source, equals('native'));
      expect(fromMap.deviceName, equals('realme Buds T200 Lite'));
      expect(fromMap.deviceId, equals('bt_realme_123'));
      expect(fromMap.playbackConfigsCount, equals(0));
      expect(fromMap.activeMediaCount, equals(0));
      expect(fromMap.playbackStates, equals('[]'));
      expect(fromMap.isMusicActive, isFalse);
      expect(fromMap.isA2dpStreaming, isFalse);
      expect(fromMap.prevPlaying, isTrue);
      expect(fromMap.resolvedPlaying, isFalse);
      expect(fromMap.resolverReason, equals('no_active_media_or_sound'));
      expect(fromMap.stopConfirmationStatus, equals('CONFIRMED'));
      expect(fromMap.hasPlaybackDiagnostics, isTrue);
      expect(fromMap.playbackSignalsSummary, contains('configs=0'));
      expect(fromMap.playbackSignalsSummary, contains('resolved=false'));
    });

    test('toJsonMap produces clean structured JSON without credentials', () {
      final now = DateTime.now();
      final event = DiagnosticEvent(
        id: 'diag_456',
        timestamp: now.millisecondsSinceEpoch,
        timestampIso: now.toIso8601String(),
        eventType: 'STOP_CONFIRMATION_SCHEDULED',
        source: 'native',
        deviceName: 'realme Buds T200 Lite',
        stopConfirmationStatus: 'SCHEDULED',
        playbackConfigsCount: 1,
        activeMediaCount: 0,
        isMusicActive: false,
        isA2dpStreaming: false,
        resolvedPlaying: false,
        resolverReason: 'configs_no_media',
      );

      final exportMap = event.toJsonMap();
      final jsonStr = jsonEncode(exportMap);
      expect(jsonStr, isNotEmpty);

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded['event_type'], equals('STOP_CONFIRMATION_SCHEDULED'));
      expect(decoded['playback_configs_count'], equals(1));
      expect(decoded['resolved_playing'], isFalse);
      expect(decoded.containsKey('password'), isFalse);
      expect(decoded.containsKey('token'), isFalse);
    });
  });

  group('Diagnostic Database & Retention Tests', () {
    late DatabaseAdapter adapter;

    setUp(() {
      adapter = InMemoryDatabaseAdapter();
    });

    test('diagnostic events are saved and queried with pagination', () async {
      final now = DateTime.now();

      for (int i = 0; i < 25; i++) {
        final t = now.add(Duration(seconds: i));
        await adapter.saveDiagnosticEvent(
          DiagnosticEvent(
            id: 'evt_$i',
            timestamp: t.millisecondsSinceEpoch,
            timestampIso: t.toIso8601String(),
            eventType: i % 2 == 0 ? 'AUDIO_STARTED' : 'AUDIO_STOPPED',
            source: 'native',
          ),
        );
      }

      final count = await adapter.getDiagnosticEventCount();
      expect(count, equals(25));

      final page1 = await adapter.getDiagnosticEvents(limit: 10, offset: 0);
      expect(page1.length, equals(10));
      // Ordered newest first
      expect(page1.first.id, equals('evt_24'));
      expect(page1.last.id, equals('evt_15'));

      final page2 = await adapter.getDiagnosticEvents(limit: 10, offset: 10);
      expect(page2.length, equals(10));
      expect(page2.first.id, equals('evt_14'));

      final page3 = await adapter.getDiagnosticEvents(limit: 10, offset: 20);
      expect(page3.length, equals(5));
      expect(page3.last.id, equals('evt_0'));
    });

    test('pruning removes old events when exceeding retention limit and never touches sessions', () async {
      final now = DateTime.now();

      // Save a device session that must NEVER be touched
      final session = ListeningSession(
        id: 'sess_keep_me',
        deviceId: 'dev_1',
        deviceName: 'Important Session',
        deviceType: 'Headphones',
        connectedAt: now,
        listeningStartedAt: now,
        connectedDurationSeconds: 1200,
        activeListeningDurationSeconds: 1200,
        silentDurationSeconds: 0,
        status: 'completed',
      );
      await adapter.saveDeviceSession(session);

      // Save a connection record that must NEVER be touched
      final conn = ConnectionRecord(
        id: 'conn_keep_me',
        deviceId: 'dev_1',
        deviceName: 'Important Connection',
        deviceType: 'Headphones',
        connectedAt: now,
        durationSeconds: 1200,
        status: 'completed',
      );
      await adapter.saveConnectionRecord(conn);

      // Save 30 diagnostic events
      for (int i = 0; i < 30; i++) {
        final t = now.add(Duration(seconds: i));
        await adapter.saveDiagnosticEvent(
          DiagnosticEvent(
            id: 'diag_p_$i',
            timestamp: t.millisecondsSinceEpoch,
            timestampIso: t.toIso8601String(),
            eventType: 'TICK',
            source: 'flutter',
          ),
        );
      }

      expect(await adapter.getDiagnosticEventCount(), equals(30));

      // Prune down to 10
      final pruned = await adapter.pruneDiagnosticEvents(keepLatest: 10);
      expect(pruned, equals(20));

      final remaining = await adapter.getDiagnosticEventCount();
      expect(remaining, equals(10));

      // Verify the newest 10 remain
      final remainingList = await adapter.getDiagnosticEvents(limit: 10);
      expect(remainingList.first.id, equals('diag_p_29'));
      expect(remainingList.last.id, equals('diag_p_20'));

      // Invariant: Session and Connection records are completely intact!
      final keptSessions = await adapter.getRecentDeviceSessions();
      expect(keptSessions.any((s) => s.id == 'sess_keep_me'), isTrue);
      expect(
        keptSessions
            .firstWhere((s) => s.id == 'sess_keep_me')
            .activeListeningDurationSeconds,
        equals(1200),
      );

      final keptConn = await adapter.getConnectionRecord('conn_keep_me');
      expect(keptConn, isNotNull);
      expect(keptConn!.durationSeconds, equals(1200));
    });
  });

  group('DiagnosticLogger Service Tests', () {
    late DatabaseAdapter adapter;
    late DiagnosticLogger logger;

    setUp(() {
      adapter = InMemoryDatabaseAdapter();
      logger = DiagnosticLogger();
      logger.setDatabase(adapter);
    });

    test('logEvent persists event safely and broadcasts to stream', () async {
      DiagnosticEvent? streamedEvent;
      final sub = logger.eventStream.listen((e) => streamedEvent = e);

      final logged = await logger.logEvent(
        eventType: 'DEVICE_CONNECTED',
        source: 'native',
        deviceName: 'realme Buds T200 Lite',
        reason: 'A2DP profile connected',
      );

      await Future.delayed(const Duration(milliseconds: 10));
      expect(logged, isNotNull);
      expect(streamedEvent, isNotNull);
      expect(streamedEvent!.id, equals(logged!.id));
      expect(streamedEvent!.eventType, equals('DEVICE_CONNECTED'));

      final inDb = await adapter.getDiagnosticEvents();
      expect(inDb.length, equals(1));
      expect(inDb.first.deviceName, equals('realme Buds T200 Lite'));

      await sub.cancel();
    });

    test('logNativeAudioEvent parses structured and regex fallback playback signals', () async {
      // 1. Structured payload
      final structuredMap = {
        'type': 'AUDIO_STOPPED',
        'deviceName': 'realme Buds T200 Lite',
        'playbackConfigsCount': 0,
        'activeMediaCount': 0,
        'playbackStates': '[]',
        'isMusicActive': false,
        'isA2dpStreaming': false,
        'prevPlaying': true,
        'resolvedPlaying': false,
        'resolverReason': 'no_active_media_or_sound',
        'stopConfirmationStatus': 'CONFIRMED',
      };

      final event1 = await logger.logNativeAudioEvent(structuredMap);
      expect(event1, isNotNull);
      expect(event1!.eventType, equals('AUDIO_STOPPED'));
      expect(event1.resolvedPlaying, isFalse);
      expect(event1.prevPlaying, isTrue);
      expect(event1.resolverReason, equals('no_active_media_or_sound'));
      expect(event1.stopConfirmationStatus, equals('CONFIRMED'));

      // 2. Legacy regex diagnostics string fallback
      final legacyMap = {
        'type': 'AUDIO_STOPPED',
        'deviceName': 'realme Buds T200 Lite',
        'diagnostics': 'configs=0, activeMedia=0, states=[], isMusicActive=false, isA2dp=false, prev=true, resolved=false, reason=no_active_media_or_sound',
      };

      final event2 = await logger.logNativeAudioEvent(legacyMap);
      expect(event2, isNotNull);
      expect(event2!.playbackConfigsCount, equals(0));
      expect(event2.activeMediaCount, equals(0));
      expect(event2.isMusicActive, isFalse);
      expect(event2.isA2dpStreaming, isFalse);
      expect(event2.prevPlaying, isTrue);
      expect(event2.resolvedPlaying, isFalse);
      expect(event2.resolverReason, equals('no_active_media_or_sound'));
    });

    test('re-entrancy protection prevents infinite logging loops', () async {
      // Create a faulty mock adapter that calls logEvent when saving
      final recursiveAdapter = _RecursiveFaultyAdapter(logger);
      logger.setDatabase(recursiveAdapter);

      // This call should not result in stack overflow
      final result = await logger.logEvent(
        eventType: 'TEST_RECURSIVE',
        source: 'flutter',
      );

      expect(result, isNotNull);
      expect(recursiveAdapter.attemptedWrites, equals(1));
    });

    test('exportEventsAsJson outputs valid JSON array', () async {
      await logger.logEvent(
        eventType: 'EVENT_1',
        source: 'flutter',
        reason: 'Testing export 1',
      );
      await logger.logEvent(
        eventType: 'EVENT_2',
        source: 'native',
        reason: 'Testing export 2',
      );

      final jsonStr = await logger.exportEventsAsJson();
      expect(jsonStr, isNotEmpty);

      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded['events'], isA<List>());
      final eventsList = decoded['events'] as List;
      expect(eventsList.length, equals(2));
      expect(eventsList[0]['event_type'], equals('EVENT_2')); // Newest first
      expect(eventsList[1]['event_type'], equals('EVENT_1'));
    });
  });

  group('DatabaseHelper v3 Schema Migration Verification', () {
    test('database version is bumped to 3', () {
      expect(DatabaseHelper.databaseVersion, equals(3));
    });

    test('safe DDL creates diagnostic_events table idempotently', () {
      final ddl = DatabaseHelper.createDiagnosticEventsTableSql;
      expect(ddl, contains('CREATE TABLE IF NOT EXISTS diagnostic_events'));
      expect(ddl, contains('id TEXT PRIMARY KEY'));
      expect(ddl, contains('timestamp INTEGER NOT NULL'));
      expect(ddl, contains('event_type TEXT NOT NULL'));
      expect(ddl, contains('resolved_playing INTEGER'));
      expect(ddl, contains('resolver_reason TEXT'));
    });
  });
}

class _RecursiveFaultyAdapter extends InMemoryDatabaseAdapter {
  final DiagnosticLogger logger;
  int attemptedWrites = 0;

  _RecursiveFaultyAdapter(this.logger);

  @override
  Future<void> saveDiagnosticEvent(DiagnosticEvent event) async {
    attemptedWrites++;
    // Simulate re-entrant callback that tries to log another event
    await logger.logEvent(eventType: 'NESTED_LOG', source: 'test');
    await super.saveDiagnosticEvent(event);
  }
}
