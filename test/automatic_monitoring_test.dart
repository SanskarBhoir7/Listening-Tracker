import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/audio_monitor_service.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/main.dart';
import 'package:listening_tracker/session_engine.dart';

class FakeAudioMonitorService implements AudioMonitorService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, bool> permissionsToReturn;
  int startMonitoringCallCount = 0;
  int stopMonitoringCallCount = 0;
  int requestPermissionsCallCount = 0;

  FakeAudioMonitorService({
    this.permissionsToReturn = const {
      'bluetooth_connect': true,
      'post_notifications': true,
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
    return true;
  }

  @override
  Future<bool> stopMonitoring() async {
    stopMonitoringCallCount++;
    return true;
  }

  @override
  Future<Map<String, dynamic>> getCurrentState() async {
    return {
      'isAudioPlaying': false,
      'connectedDevices': [],
    };
  }

  void emitEvent(Map<String, dynamic> event) {
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}

void main() {
  group('Automatic Monitoring on Launch & Permission Grant', () {
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

    testWidgets('Automatically starts monitoring on app launch when permissions are available', (tester) async {
      fakeService.permissionsToReturn = {
        'bluetooth_connect': true,
        'post_notifications': true,
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      // Should automatically have started monitoring
      expect(fakeService.startMonitoringCallCount, equals(1));
      expect(engine.isMonitoring, isTrue);

      // UI button displays STOP MONITORING
      expect(find.text('STOP MONITORING'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Does not start monitoring on launch if permissions are missing', (tester) async {
      fakeService.permissionsToReturn = {
        'bluetooth_connect': false,
        'post_notifications': false,
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      // Monitoring must not have started
      expect(fakeService.startMonitoringCallCount, equals(0));
      expect(engine.isMonitoring, isFalse);

      // Permissions card is visible
      expect(find.text('PERMISSIONS NEEDED'), findsOneWidget);
      expect(find.text('START MONITORING'), findsOneWidget);
    });

    testWidgets('Starts monitoring automatically after user grants permissions', (tester) async {
      fakeService.permissionsToReturn = {
        'bluetooth_connect': false,
        'post_notifications': false,
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isFalse);
      expect(fakeService.startMonitoringCallCount, equals(0));

      // Tap Grant Permissions
      await tester.tap(find.text('Grant Permissions'));
      // Pump past delay in _requestPermissions
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // Permissions granted and monitoring auto-started
      expect(fakeService.requestPermissionsCallCount, equals(1));
      expect(fakeService.startMonitoringCallCount, equals(1));
      expect(engine.isMonitoring, isTrue);
      expect(find.text('STOP MONITORING'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Prevents duplicate monitoring when already active', (tester) async {
      fakeService.permissionsToReturn = {
        'bluetooth_connect': true,
        'post_notifications': true,
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      expect(fakeService.startMonitoringCallCount, equals(1));
      expect(engine.isMonitoring, isTrue);

      // Manually trigger or pump: call count must remain 1
      await tester.pumpAndSettle();
      expect(fakeService.startMonitoringCallCount, equals(1));

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });

    testWidgets('Manual stop button successfully stops monitoring', (tester) async {
      fakeService.permissionsToReturn = {
        'bluetooth_connect': true,
        'post_notifications': true,
      };

      await tester.pumpWidget(buildApp(service: fakeService));
      await tester.pumpAndSettle();

      expect(engine.isMonitoring, isTrue);
      expect(find.text('STOP MONITORING'), findsOneWidget);

      // Tap STOP MONITORING
      await tester.tap(find.text('STOP MONITORING'));
      await tester.pumpAndSettle();

      expect(fakeService.stopMonitoringCallCount, equals(1));
      expect(engine.isMonitoring, isFalse);
      expect(find.text('START MONITORING'), findsOneWidget);

      // Tapping START MONITORING restarts it
      await tester.tap(find.text('START MONITORING'));
      await tester.pumpAndSettle();

      expect(fakeService.startMonitoringCallCount, equals(2));
      expect(engine.isMonitoring, isTrue);
      expect(find.text('STOP MONITORING'), findsOneWidget);

      await engine.stopMonitoring();
      await tester.pumpAndSettle();
    });
  });
}
