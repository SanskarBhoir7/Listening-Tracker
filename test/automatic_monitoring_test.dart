import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/audio_monitor_service.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/main.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/tracking_state.dart';

class FakeAudioMonitorService implements AudioMonitorService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, bool> permissionsToReturn;
  Map<String, dynamic> stateToReturn;
  int startMonitoringCallCount = 0;
  int stopMonitoringCallCount = 0;
  int requestPermissionsCallCount = 0;

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
    stateToReturn = {
      'isMonitoring': true,
      'isAudioPlaying': false,
      'connectedDevices': stateToReturn['connectedDevices'] ?? [],
    };
    return true;
  }

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

  void emitEvent(Map<String, dynamic> event) {
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
      engine = SessionEngine(database: db);
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

    testWidgets('Initial state with no Bluetooth audio device: monitoring remains OFF', (tester) async {
      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isFalse);
      expect(find.text('START MONITORING'), findsOneWidget);
      expect(find.text('IDLE (Monitoring Off)'), findsOneWidget);
    });

    testWidgets('Test 8: Bluetooth connected => Monitoring starts automatically', (tester) async {
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
      expect(engine.connectionState, equals(BluetoothConnectionState.connected));
      expect(find.text('STOP MONITORING'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Test 9: Duplicate Bluetooth connected => No duplicate monitoring instance', (tester) async {
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
    });

    testWidgets('Test 10: Bluetooth disconnected => Monitoring stops automatically', (tester) async {
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
      expect(engine.connectionState, equals(BluetoothConnectionState.disconnected));
      expect(find.text('START MONITORING'), findsOneWidget);
    });

    testWidgets('Test 11: Duplicate Bluetooth disconnected => No duplicate finalization', (tester) async {
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
    });

    testWidgets('Test 12: Bluetooth connected but no audio => Monitoring ON, Listening OFF', (tester) async {
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
      expect(engine.connectionState, equals(BluetoothConnectionState.connected));
      expect(engine.sessionState, equals(ListeningSessionState.idle));
      expect(find.text('CONNECTED (Idle / Silent)'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Test 13: Bluetooth connected + audio => Monitoring ON, Listening ON', (tester) async {
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
        'diagnostics': 'configs=1, activeMedia=1, isMusicActive=true, isA2dp=true',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isTrue);
      expect(engine.sessionState, equals(ListeningSessionState.active));
      expect(find.text('LISTENING (Active)'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Manual stop and resume button controls monitoring directly', (tester) async {
      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      // User manually starts monitoring
      await tester.tap(find.text('START MONITORING'));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isTrue);
      expect(fakeService.startMonitoringCallCount, equals(1));
      expect(find.text('STOP MONITORING'), findsOneWidget);

      // User manually stops monitoring
      await tester.tap(find.text('STOP MONITORING'));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isFalse);
      expect(fakeService.stopMonitoringCallCount, equals(1));
      expect(find.text('START MONITORING'), findsOneWidget);
    });

    testWidgets('Initialization with Bluetooth already connected syncs monitoring to ON', (tester) async {
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
          }
        ],
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isTrue);
      expect(engine.connectedDevicesList.length, equals(1));
      expect(find.text('STOP MONITORING'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Repeated Bluetooth connect and disconnect cycles preserve state consistency', (tester) async {
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
        expect(engine.connectionState, equals(BluetoothConnectionState.connected));

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
        expect(engine.connectionState, equals(BluetoothConnectionState.disconnected));
      }
    });

    testWidgets('Async stopMonitoring completes cleanly and handles errors gracefully', (tester) async {
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
    });
  });
}
