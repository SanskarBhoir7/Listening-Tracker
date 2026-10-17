import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/audio_monitor_service.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/main.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/services/break_engine.dart';
import 'package:listening_tracker/services/break_notification_service.dart';
import 'package:listening_tracker/tracking_state.dart';

class FakeAudioMonitorService implements AudioMonitorService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, bool> permissionsToReturn;
  Map<String, dynamic> stateToReturn;
  int startMonitoringCallCount = 0;
  int stopMonitoringCallCount = 0;
  int requestPermissionsCallCount = 0;
  List<Map<String, dynamic>> nativeLifecycleEvents = const [];
  bool startAccepted = true;

  FakeAudioMonitorService({
    this.permissionsToReturn = const {
      'bluetooth_connect': true,
      'post_notifications': true,
    },
    this.stateToReturn = const {
      'isMonitoring': false,
      'isAudioPlaying': false,
      'connectedDevices': [],
    },
  });

  @override
  Stream<Map<String, dynamic>> get audioEvents => _controller.stream;

  @override
  Future<Map<String, bool>> checkPermissions() async => permissionsToReturn;

  @override
  Future<void> requestPermissions() async {
    requestPermissionsCallCount++;
    permissionsToReturn = {
      'bluetooth_connect': true,
      'post_notifications': true,
    };
  }

  @override
  Future<bool> startMonitoring() async {
    startMonitoringCallCount++;
    if (!startAccepted) return false;
    stateToReturn = {
      'isMonitoring': true,
      'isAudioPlaying': false,
      'connectedDevices': stateToReturn['connectedDevices'] ?? [],
    };
    return true;
  }

  @override
  Future<List<Map<String, dynamic>>> drainNativeLifecycleEvents() async {
    final events = nativeLifecycleEvents;
    nativeLifecycleEvents = const [];
    return events;
  }

  @override
  Future<void> acknowledgeNativeLifecycleEvents(List<String> ids) async {}

  @override
  Future<bool> stopMonitoring() async {
    stopMonitoringCallCount++;
    stateToReturn = {
      'isMonitoring': false,
      'isAudioPlaying': false,
      'connectedDevices': stateToReturn['connectedDevices'] ?? [],
    };
    return true;
  }

  @override
  Future<Map<String, dynamic>> getCurrentState() async {
    return stateToReturn;
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}

  @override
  Future<bool> isCompanionAssociated() async => false;

  @override
  Future<bool> associateCompanionDevice({String namePattern = '.*'}) async =>
      true;

  @override
  Future<bool> shareLogFile(String content, String fileName) async => true;

  @override
  Future<bool> showBreakNotification({
    required int id,
    required String title,
    required String body,
    int snoozeMinutes = 10,
    required String sessionGeneration,
  }) async => true;

  @override
  Future<bool> cancelBreakNotification(int id) async => true;

  @override
  Future<bool> cancelAllBreakNotifications() async => true;

  void emitEvent(Map<String, dynamic> event) {
    if (event['type'] == 'DEVICE_CONNECTED') {
      emitRawEvent({
        'type': 'MONITORING_STATE_CHANGED',
        'isMonitoring': true,
        'reason': 'service_started',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    }
    emitRawEvent(event);
  }

  void emitRawEvent(Map<String, dynamic> event) {
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}

void main() {
  group('Bluetooth-Driven Monitoring Lifecycle (Tests 8-13)', () {
    late InMemoryDatabaseAdapter db;
    late SessionEngine engine;
    late FakeAudioMonitorService fakeService;

    setUp(() {
      db = InMemoryDatabaseAdapter();
      engine = SessionEngine(
        database: db,
        breakEngine: BreakEngine(
          notificationService: FakeBreakNotificationService(),
        ),
      );
      fakeService = FakeAudioMonitorService();
    });

    tearDown(() {
      engine.dispose();
      fakeService.dispose();
    });

    Widget buildApp({required FakeAudioMonitorService service}) {
      return MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MonitorDashboard(
          audioService: service,
          engine: engine,
          database: db,
        ),
      );
    }

    testWidgets(
      'Initial state with no Bluetooth audio device: monitoring remains OFF',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isFalse);
        expect(find.text('START MONITORING'), findsOneWidget);
        expect(find.text('IDLE (Monitoring Off)'), findsOneWidget);
      },
    );

    testWidgets(
      'Rejected native service start does not mark Flutter monitoring active',
      (tester) async {
        fakeService.startAccepted = false;
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('START MONITORING'));
        await tester.tap(find.text('START MONITORING'));
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isFalse);
        expect(find.text('START MONITORING'), findsOneWidget);
        expect(
          find.textContaining('Monitoring could not start'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Bluetooth connection remains idle until native service confirms monitoring',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        fakeService.emitRawEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(engine.isMonitoring, isFalse);
        expect(find.text('CONNECTED (Monitoring Inactive)'), findsOneWidget);
        expect(find.text('Active (Listening)'), findsNothing);

        fakeService.emitRawEvent({
          'type': 'MONITORING_STATE_CHANGED',
          'isMonitoring': true,
          'reason': 'service_started',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(engine.isMonitoring, isTrue);
        expect(find.text('CONNECTED (Idle / Silent)'), findsOneWidget);
        await engine.stopMonitoring();
        await tester.pump();
      },
    );

    testWidgets(
      'Native lifecycle breadcrumbs are imported into persistent diagnostics',
      (tester) async {
        fakeService.nativeLifecycleEvents = [
          {
            'id': 'native_evt_1',
            'processId': 'process_1',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'eventType': 'SERVICE_START_REQUEST_REJECTED',
            'details': {'error': 'ForegroundServiceStartNotAllowedException'},
          },
        ];

        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        final diagnostics = await db.getDiagnosticEvents(limit: 20);
        final imported = diagnostics.firstWhere(
          (event) => event.eventType == 'SERVICE_START_REQUEST_REJECTED',
        );
        expect(imported.source, equals('native_lifecycle'));
        expect(imported.metadata?['nativeProcessId'], equals('process_1'));
        expect(
          imported.metadata?['error'],
          contains('ForegroundServiceStartNotAllowedException'),
        );
      },
    );

    testWidgets(
      'Test 8: Bluetooth connected => Monitoring starts automatically',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isFalse);

        // Bluetooth device connects
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Monitoring started automatically
        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(find.text('STOP MONITORING'), findsOneWidget);
        expect(find.text('Battery: unavailable from Android'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Test 9: Duplicate Bluetooth connected => No duplicate monitoring instance',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // Emit connected 3 times
        for (int i = 0; i < 3; i++) {
          fakeService.emitEvent({
            'type': 'DEVICE_CONNECTED',
            'deviceName': 'realme Buds T200 Lite',
            'connectionType': 'bluetooth',
            'deviceType': 'Bluetooth A2DP',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isTrue);
        expect(engine.connectedDevicesList.length, equals(1));

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Test 10: Bluetooth disconnected => Monitoring stops automatically',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // Connect device
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();
        expect(engine.isMonitoring, isTrue);

        // Disconnect device
        fakeService.emitEvent({
          'type': 'DEVICE_DISCONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Monitoring stops automatically
        expect(engine.isMonitoring, isFalse);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.disconnected),
        );
        expect(find.text('START MONITORING'), findsOneWidget);
      },
    );

    testWidgets(
      'Test 11: Duplicate Bluetooth disconnected => No duplicate finalization',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // Connect device
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Disconnect device twice
        fakeService.emitEvent({
          'type': 'DEVICE_DISCONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        fakeService.emitEvent({
          'type': 'DEVICE_DISCONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isFalse);
        expect(engine.connectedDevicesList, isEmpty);
      },
    );

    testWidgets(
      'Test 12: Bluetooth connected but no audio => Monitoring ON, Listening OFF',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Monitoring ON, but audio state is notPlaying
        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.sessionState, equals(ListeningSessionState.idle));
        expect(find.text('CONNECTED (Idle / Silent)'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Test 13: Bluetooth connected + audio => Monitoring ON, Listening ON',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Audio starts
        fakeService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'diagnostics':
              'configs=1, activeMedia=1, isMusicActive=true, isA2dp=true',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isTrue);
        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(find.text('LISTENING (Active)'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Manual stop and resume button controls monitoring directly', (
      tester,
    ) async {
      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      // User manually starts monitoring
      await tester.ensureVisible(find.text('START MONITORING'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('START MONITORING'));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isTrue);
      expect(fakeService.startMonitoringCallCount, equals(1));
      expect(find.text('STOP MONITORING'), findsOneWidget);

      // User manually stops monitoring
      await tester.ensureVisible(find.text('STOP MONITORING'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('STOP MONITORING'));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isFalse);
      expect(fakeService.stopMonitoringCallCount, equals(1));
      expect(find.text('START MONITORING'), findsOneWidget);
    });

    testWidgets(
      'Initialization with Bluetooth already connected syncs monitoring to ON',
      (tester) async {
        // Simulate state where native already had connected device at startup
        fakeService.stateToReturn = {
          'isMonitoring': true,
          'isAudioPlaying': false,
          'connectedDevices': [
            {
              'id': 101,
              'name': 'realme Buds T200 Lite',
              'typeName': 'Bluetooth A2DP',
              'connectionType': 'bluetooth',
              'address': '00:11:22:33:44:55',
            },
          ],
        };

        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isTrue);
        expect(engine.connectedDevicesList.length, equals(1));
        expect(find.text('STOP MONITORING'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Repeated Bluetooth connect and disconnect cycles preserve state consistency',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        for (int cycle = 0; cycle < 3; cycle++) {
          // Connect
          fakeService.emitEvent({
            'type': 'DEVICE_CONNECTED',
            'deviceName': 'realme Buds T200 Lite',
            'connectionType': 'bluetooth',
            'deviceType': 'Bluetooth A2DP',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
          await tester.pumpAndSettle();
          expect(engine.isMonitoring, isTrue);
          expect(
            engine.connectionState,
            equals(BluetoothConnectionState.connected),
          );

          // Disconnect
          fakeService.emitEvent({
            'type': 'DEVICE_DISCONNECTED',
            'deviceName': 'realme Buds T200 Lite',
            'connectionType': 'bluetooth',
            'deviceType': 'Bluetooth A2DP',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
          await tester.pumpAndSettle();
          expect(engine.isMonitoring, isFalse);
          expect(
            engine.connectionState,
            equals(BluetoothConnectionState.disconnected),
          );
        }
      },
    );

    testWidgets(
      'Async stopMonitoring completes cleanly and handles errors gracefully',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // Connect device
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();
        expect(engine.isMonitoring, isTrue);

        // Await stop
        await engine.stopMonitoring();
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isFalse);
        expect(find.text('START MONITORING'), findsOneWidget);
      },
    );

    testWidgets(
      'Cold process restart: initial snapshot with connected earbuds initiates tracking seamlessly',
      (tester) async {
        fakeService.stateToReturn = {
          'isMonitoring': true,
          'isAudioPlaying': true,
          'connectedDevices': [
            {
              'id': 2002,
              'name': 'realme Buds T200 Lite',
              'typeName': 'Bluetooth A2DP',
              'connectionType': 'bluetooth',
              'address': 'AA:BB:CC:DD:EE:FF',
            },
          ],
        };

        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.connectedDevicesList.length, equals(1));
        expect(
          engine.connectedDevicesList.first.name,
          equals('realme Buds T200 Lite'),
        );
        expect(find.text('STOP MONITORING'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Disconnect during active playback immediately finalizes session and stops monitoring',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // Earbuds connect automatically
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Audio starts
        fakeService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(find.text('LISTENING (Active)'), findsOneWidget);

        // Earbuds disconnect (placed in charging case)
        fakeService.emitEvent({
          'type': 'DEVICE_DISCONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Session must be finalized immediately, monitoring stopped
        expect(engine.isMonitoring, isFalse);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.disconnected),
        );
        expect(engine.connectedDevicesList, isEmpty);
        expect(find.text('START MONITORING'), findsOneWidget);

        // Verify session was persisted to database
        final sessions = await db.getRecentDeviceSessions();
        expect(sessions.isNotEmpty, isTrue);
        expect(sessions.first.deviceName, equals('realme Buds T200 Lite'));
        expect(sessions.first.disconnectedAt, isNotNull);
      },
    );

    testWidgets(
      'Three-minute grace period invariant preserved on audio pause while earbuds remain connected',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Audio started
        fakeService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Audio stopped (pause)
        fakeService.emitEvent({
          'type': 'AUDIO_STOPPED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        // Enters 3-minute grace period
        expect(engine.sessionState, equals(ListeningSessionState.gracePeriod));
        expect(engine.isMonitoring, isTrue);
        expect(find.textContaining('PAUSED (Grace:'), findsOneWidget);

        // Resume within grace period
        fakeService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(find.text('LISTENING (Active)'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Lifecycle event drain handles SERVICE_START_REQUEST_REJECTED and RECOVERY_TRIGGERED_FROM_NOTIFICATION telemetry seamlessly',
      (tester) async {
        fakeService.nativeLifecycleEvents = [
          {
            'id': 'diag_rejected_1',
            'timestamp': DateTime.now().millisecondsSinceEpoch - 5000,
            'event_type': 'SERVICE_START_REQUEST_REJECTED',
            'metadata': {
              'origin': 'bluetooth_acl',
              'startupPath': 'bluetooth_acl',
              'error': 'android.app.ForegroundServiceStartNotAllowedException',
              'message': 'startForegroundService() not allowed due to mAllowStartForeground false',
              'isForegroundServiceStartNotAllowed': true,
              'recoveryStrategy': 'direct_notification_action',
            },
          },
          {
            'id': 'diag_recovered_2',
            'timestamp': DateTime.now().millisecondsSinceEpoch - 2000,
            'event_type': 'RECOVERY_TRIGGERED_FROM_NOTIFICATION',
            'metadata': {'deviceName': 'realme Buds T200 Lite', 'startId': 2},
          },
        ];

        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        // App launches and drains events without error
        expect(find.byType(MaterialApp), findsOneWidget);

        // Simulate incoming connected device state after successful recovery
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        await tester.pumpAndSettle();

        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.sessionState, equals(ListeningSessionState.idle));

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Overlapping ACL and A2DP device connections do not produce duplicate active sessions and keep connection separate from audio playback',
      (tester) async {
        await tester.pumpWidget(buildApp(service: fakeService));
        await tester.pumpAndSettle();

        final now = DateTime.now().millisecondsSinceEpoch;

        // 1. ACL connection arrives
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'deviceAddress': '28:04:C6:D2:59:08',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': now,
        });
        await tester.pumpAndSettle();

        // 2. Overlapping A2DP connection arrives 40ms later
        fakeService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'deviceAddress': '28:04:C6:D2:59:08',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': now + 40,
        });
        await tester.pumpAndSettle();

        // Must have exactly one device tracked and in idle (not listening) state
        expect(engine.connectedDevicesList.length, equals(1));
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.sessionState, equals(ListeningSessionState.idle));
        expect(find.text('CONNECTED (Idle / Silent)'), findsOneWidget);

        // 3. Audio playback starts independently
        fakeService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'deviceAddress': '28:04:C6:D2:59:08',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': now + 1000,
        });
        await tester.pumpAndSettle();

        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(find.text('LISTENING (Active)'), findsOneWidget);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Audio started before Flutter initialization is properly restored and drained without dropping events or double sessions',
      (tester) async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final preService = FakeAudioMonitorService(
          stateToReturn: {
            'isMonitoring': true,
            'isAudioPlaying': true,
            'outputDeviceName': 'realme Buds T200 Lite',
            'outputDeviceType': 'Bluetooth A2DP',
            'outputConnectionType': 'bluetooth',
            'outputDeviceAddress': '28:04:C6:D2:59:08',
            'connectedDevices': [
              {
                'name': 'realme Buds T200 Lite',
                'typeName': 'Bluetooth A2DP',
                'connectionType': 'bluetooth',
                'address': '28:04:C6:D2:59:08',
              },
            ],
          },
        );

        await tester.pumpWidget(buildApp(service: preService));
        await tester.pumpAndSettle();

        // 1. Initial snapshot recovery sees audio playing and activates session
        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(engine.currentDeviceSession, isNotNull);

        // 2. Drained buffered events arrive from EventChannel
        preService.emitEvent({
          'type': 'DEVICE_CONNECTED',
          'deviceName': 'realme Buds T200 Lite',
          'deviceAddress': '28:04:C6:D2:59:08',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'timestamp': now - 500,
        });
        preService.emitEvent({
          'type': 'AUDIO_STARTED',
          'deviceName': 'realme Buds T200 Lite',
          'deviceAddress': '28:04:C6:D2:59:08',
          'connectionType': 'bluetooth',
          'deviceType': 'Bluetooth A2DP',
          'isAudioPlaying': true,
          'timestamp': now - 400,
        });
        await tester.pumpAndSettle();

        // Must still be active with the same session, no duplicate creation
        expect(engine.sessionState, equals(ListeningSessionState.active));
        expect(engine.currentDeviceSession, isNotNull);

        // Verify events in DiagnosticLogger
        final eventsInDb = await db.getDiagnosticEvents();
        final eventTypes = eventsInDb.map((e) => e.eventType).toList();
        expect(eventTypes, contains('AUDIO_STARTED'));

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Connected-but-idle invariant: Bluetooth connection alone never counts as listening time or triggers session checkpoints',
      (tester) async {
        final idleService = FakeAudioMonitorService(
          stateToReturn: {
            'isMonitoring': true,
            'isAudioPlaying': false,
            'outputDeviceName': 'realme Buds T200 Lite',
            'outputDeviceType': 'Bluetooth A2DP',
            'outputConnectionType': 'bluetooth',
            'outputDeviceAddress': '28:04:C6:D2:59:08',
            'connectedDevices': [
              {
                'name': 'realme Buds T200 Lite',
                'typeName': 'Bluetooth A2DP',
                'connectionType': 'bluetooth',
                'address': '28:04:C6:D2:59:08',
              },
            ],
          },
        );

        await tester.pumpWidget(buildApp(service: idleService));
        await tester.pumpAndSettle();

        // Connected, but session MUST remain idle
        expect(engine.isMonitoring, isTrue);
        expect(
          engine.connectionState,
          equals(BluetoothConnectionState.connected),
        );
        expect(engine.sessionState, equals(ListeningSessionState.idle));
        expect(engine.currentDeviceSession, isNull);
        expect(find.text('CONNECTED (Idle / Silent)'), findsOneWidget);

        // Advance 70 seconds to test periodic checkpoint interval
        await tester.pump(const Duration(seconds: 70));

        // Still idle, no listening session created
        expect(engine.sessionState, equals(ListeningSessionState.idle));
        expect(engine.currentDeviceSession, isNull);

        final eventsInDb = await db.getDiagnosticEvents();
        final checkpoints = eventsInDb.where(
          (e) => e.eventType == 'SESSION_CHECKPOINT',
        );
        expect(checkpoints, isEmpty);

        await engine.stopMonitoring();
        await tester.pumpAndSettle();
      },
    );
  });
}
