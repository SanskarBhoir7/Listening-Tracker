import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/models/audio_device.dart';
import 'package:listening_tracker/models/break_state.dart';
import 'package:listening_tracker/services/break_engine.dart';
import 'package:listening_tracker/services/break_notification_service.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/tracking_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BreakEngine Unit Tests', () {
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;
    final testDevice = AudioDevice(
      id: 'dev-1',
      name: 'realme Buds T200 Lite',
      deviceType: 'Bluetooth A2DP',
      connectionType: 'bluetooth',
      firstSeen: DateTime(2026, 1, 1),
      lastSeen: DateTime(2026, 1, 1),
    );

    setUp(() {
      notificationService = FakeBreakNotificationService();
      breakEngine = BreakEngine(
        notificationService: notificationService,
        config: const BreakRuleConfig(
          breakSoonThreshold: Duration(minutes: 45),
          breakRecommendedThreshold: Duration(minutes: 60),
        ),
      );
    });

    test('Initial state is normal with 0 duration', () {
      final state = breakEngine.state;
      expect(state.status, BreakStatus.normal);
      expect(state.continuousListeningDuration, Duration.zero);
      expect(state.timeUntilNextThreshold, const Duration(minutes: 45));
      expect(state.statusLabel, 'NORMAL');
      expect(state.listeningDurationFormatted, '00:00');
      expect(state.timeUntilNextThresholdFormatted, '45m 0s remaining');
    });

    test('Transitions from normal to breakSoon at 45 minutes', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 44, seconds: 59),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.normal);
      expect(notificationService.shownNotifications.length, 0);

      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.breakSoon);
      expect(breakEngine.state.timeUntilNextThreshold, const Duration(minutes: 15));
      expect(notificationService.shownNotifications.length, 1);
      expect(notificationService.shownNotifications.first['id'], 3001);
      expect(
        notificationService.shownNotifications.first['title'],
        'Break Soon Recommended',
      );
    });

    test('Prevents duplicate notifications for the same threshold', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      // Subsequent ticks past 45 minutes
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 46),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 50),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);
    });

    test('Transitions to breakRecommended at 60 minutes and dispatches alert', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 60),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.breakRecommended);
      expect(breakEngine.state.timeUntilNextThresholdFormatted, 'Threshold reached');
      expect(notificationService.shownNotifications.length, 2);
      expect(notificationService.shownNotifications[1]['id'], 3002);
      expect(
        notificationService.shownNotifications[1]['title'],
        'Time for an Ear Rest',
      );

      // Further ticks at 65 minutes should not send a 3rd notification
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 65),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 2);
    });

    test('Device switching preserves continuous session and updates device name', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 30),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.activeDeviceName, 'realme Buds T200 Lite');

      final deviceB = AudioDevice(
        id: 'dev-b',
        name: 'Headphones B',
        deviceType: 'Bluetooth A2DP',
        connectionType: 'bluetooth',
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );
      breakEngine.onDeviceSwitched(deviceB);
      expect(breakEngine.state.activeDeviceName, 'Headphones B');
      expect(breakEngine.state.continuousListeningDuration, const Duration(minutes: 30));
    });

    test('Reset clears continuous duration, state, and cancels notifications', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      await breakEngine.reset();
      expect(breakEngine.state.status, BreakStatus.normal);
      expect(breakEngine.state.continuousListeningDuration, Duration.zero);
      expect(notificationService.cancelAllCallCount, 1);

      // After reset, a new 45-minute continuous listening period can notify again
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);
    });

    test('Handles denied notification permission gracefully without error', () async {
      final deniedService = FakeBreakNotificationService(permissionGranted: false);
      final engineWithDenied = BreakEngine(
        notificationService: deniedService,
      );

      // Should not throw
      await engineWithDenied.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(engineWithDenied.state.status, BreakStatus.breakSoon);
      expect(deniedService.shownNotifications.isEmpty, true);
    });
  });

  group('SessionEngine + BreakEngine Integration Tests', () {
    late InMemoryDatabaseAdapter db;
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;
    late SessionEngine sessionEngine;
    late DateTime baseTime;

    setUp(() {
      baseTime = DateTime(2026, 10, 12, 10, 0, 0);
      db = InMemoryDatabaseAdapter();
      notificationService = FakeBreakNotificationService();
      // Use short thresholds for deterministic integration tests
      breakEngine = BreakEngine(
        notificationService: notificationService,
        config: const BreakRuleConfig(
          breakSoonThreshold: Duration(seconds: 4),
          breakRecommendedThreshold: Duration(seconds: 6),
        ),
      );
      sessionEngine = SessionEngine(
        database: db,
        breakEngine: breakEngine,
      );
      sessionEngine.startMonitoring();
    });

    tearDown(() {
      sessionEngine.dispose();
    });

    Map<String, dynamic> btConnectEvent({
      String name = 'realme Buds T200 Lite',
      int? timeMs,
    }) {
      return {
        'type': 'DEVICE_CONNECTED',
        'deviceName': name,
        'connectionType': 'bluetooth',
        'deviceAddress': '88:C9:E8:12:34:56',
        'deviceType': 'Bluetooth A2DP',
        'timestamp': timeMs ?? baseTime.millisecondsSinceEpoch,
      };
    }

    Map<String, dynamic> btDisconnectEvent({
      String name = 'realme Buds T200 Lite',
      int? timeMs,
    }) {
      return {
        'type': 'DEVICE_DISCONNECTED',
        'deviceName': name,
        'connectionType': 'bluetooth',
        'deviceAddress': '88:C9:E8:12:34:56',
        'deviceType': 'Bluetooth A2DP',
        'timestamp': timeMs ?? baseTime.millisecondsSinceEpoch,
      };
    }

    Map<String, dynamic> audioStartEvent({int? timeMs}) {
      return {
        'type': 'AUDIO_STARTED',
        'isAudioPlaying': true,
        'timestamp': timeMs ?? baseTime.millisecondsSinceEpoch,
      };
    }

    Map<String, dynamic> audioStopEvent({int? timeMs}) {
      return {
        'type': 'AUDIO_STOPPED',
        'isAudioPlaying': false,
        'timestamp': timeMs ?? baseTime.millisecondsSinceEpoch,
      };
    }

    test('Bluetooth connected but idle does not advance continuous listening duration', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent());
      expect(sessionEngine.connectionState, BluetoothConnectionState.connected);
      expect(sessionEngine.sessionState, ListeningSessionState.idle);

      // Simulate 5 seconds of idle connection
      for (int i = 1; i <= 5; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }

      expect(sessionEngine.breakState.continuousListeningDuration, Duration.zero);
      expect(sessionEngine.breakState.status, BreakStatus.normal);
      expect(notificationService.shownNotifications.isEmpty, true);
    });

    test('Continuous listening triggers break thresholds and prevents duplicate alerts', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent(timeMs: baseTime.millisecondsSinceEpoch));
      await sessionEngine.handleNativeEvent(audioStartEvent(timeMs: baseTime.millisecondsSinceEpoch));
      expect(sessionEngine.sessionState, ListeningSessionState.active);

      // Tick 3 seconds -> below 4s threshold -> normal
      for (int i = 1; i <= 3; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }
      expect(sessionEngine.breakState.status, BreakStatus.normal);
      expect(notificationService.shownNotifications.isEmpty, true);

      // Tick 4th second -> reach 4s breakSoon threshold
      sessionEngine.triggerTickForTesting(baseTime.add(const Duration(seconds: 4)));
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);
      expect(notificationService.shownNotifications.first['id'], 3001);

      // Tick 5th second -> still breakSoon, NO duplicate notification
      sessionEngine.triggerTickForTesting(baseTime.add(const Duration(seconds: 5)));
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);

      // Tick 6th second -> reach 6s breakRecommended threshold
      sessionEngine.triggerTickForTesting(baseTime.add(const Duration(seconds: 6)));
      expect(sessionEngine.breakState.status, BreakStatus.breakRecommended);
      expect(notificationService.shownNotifications.length, 2);
      expect(notificationService.shownNotifications[1]['id'], 3002);

      // Tick 7th second -> still breakRecommended, NO duplicate
      sessionEngine.triggerTickForTesting(baseTime.add(const Duration(seconds: 7)));
      expect(sessionEngine.breakState.status, BreakStatus.breakRecommended);
      expect(notificationService.shownNotifications.length, 2);
    });

    test('Temporary pause within 3-minute grace period preserves continuous listening count', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent(timeMs: baseTime.millisecondsSinceEpoch));
      await sessionEngine.handleNativeEvent(audioStartEvent(timeMs: baseTime.millisecondsSinceEpoch));

      // Play for 3 seconds
      for (int i = 1; i <= 3; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }
      expect(sessionEngine.breakState.continuousListeningDuration.inSeconds, 3);

      // Pause audio at t=3s -> enters grace period
      final pauseTime = baseTime.add(const Duration(seconds: 3));
      await sessionEngine.handleNativeEvent(audioStopEvent(timeMs: pauseTime.millisecondsSinceEpoch));
      expect(sessionEngine.sessionState, ListeningSessionState.gracePeriod);

      // 2 ticks while paused in grace period: listening duration must NOT advance
      sessionEngine.triggerTickForTesting(pauseTime.add(const Duration(seconds: 1)));
      sessionEngine.triggerTickForTesting(pauseTime.add(const Duration(seconds: 2)));
      expect(sessionEngine.breakState.continuousListeningDuration.inSeconds, 3);

      // Resume audio before grace period expires (at t=6s)
      final resumeTime = pauseTime.add(const Duration(seconds: 3));
      await sessionEngine.handleNativeEvent(audioStartEvent(timeMs: resumeTime.millisecondsSinceEpoch));
      expect(sessionEngine.sessionState, ListeningSessionState.active);

      // Tick 1 more second (total 4s active listening) -> triggers breakSoon threshold
      sessionEngine.triggerTickForTesting(resumeTime.add(const Duration(seconds: 1)));
      expect(sessionEngine.breakState.continuousListeningDuration.inSeconds, 4);
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);
    });

    test('Grace period expiration finalizes session and resets BreakEngine', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent(timeMs: baseTime.millisecondsSinceEpoch));
      await sessionEngine.handleNativeEvent(audioStartEvent(timeMs: baseTime.millisecondsSinceEpoch));

      // Play for 4 seconds -> triggers breakSoon
      for (int i = 1; i <= 4; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);

      // Pause audio at t=4s
      final pauseTime = baseTime.add(const Duration(seconds: 4));
      await sessionEngine.handleNativeEvent(audioStopEvent(timeMs: pauseTime.millisecondsSinceEpoch));
      expect(sessionEngine.sessionState, ListeningSessionState.gracePeriod);

      // Expire grace period
      await sessionEngine.triggerGraceExpiredForTesting();

      // Session should be finalized and breakEngine reset
      expect(sessionEngine.sessionState, ListeningSessionState.idle);
      expect(sessionEngine.breakState.status, BreakStatus.normal);
      expect(sessionEngine.breakState.continuousListeningDuration, Duration.zero);
      expect(notificationService.cancelAllCallCount, greaterThanOrEqualTo(1));

      // Check DB persistence remains intact
      expect(db.deviceSessions.length, 1);
      expect(db.deviceSessions.first.activeListeningDurationSeconds, 4);
    });

    test('Bluetooth disconnection finalizes session and cancels notifications', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent(timeMs: baseTime.millisecondsSinceEpoch));
      await sessionEngine.handleNativeEvent(audioStartEvent(timeMs: baseTime.millisecondsSinceEpoch));

      // Play for 4 seconds -> breakSoon triggered
      for (int i = 1; i <= 4; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);

      // Disconnect Bluetooth at t=5s
      final disconnectTime = baseTime.add(const Duration(seconds: 5));
      await sessionEngine.handleNativeEvent(btDisconnectEvent(timeMs: disconnectTime.millisecondsSinceEpoch));
      expect(sessionEngine.connectionState, BluetoothConnectionState.disconnected);
      expect(sessionEngine.sessionState, ListeningSessionState.idle);

      // Break engine reset
      expect(sessionEngine.breakState.status, BreakStatus.normal);
      expect(sessionEngine.breakState.continuousListeningDuration, Duration.zero);
      expect(notificationService.cancelAllCallCount, greaterThanOrEqualTo(1));

      // Historical session is preserved in DB
      expect(db.deviceSessions.length, 1);
      expect(db.deviceSessions.first.activeListeningDurationSeconds, 5);
    });

    test('Audio output changed updates BreakEngine active device name', () async {
      await sessionEngine.handleNativeEvent(btConnectEvent(name: 'realme Buds T200 Lite'));
      await sessionEngine.handleNativeEvent(audioStartEvent());
      sessionEngine.triggerTickForTesting();

      expect(sessionEngine.breakState.activeDeviceName, 'realme Buds T200 Lite');

      await sessionEngine.handleNativeEvent({
        'type': 'AUDIO_OUTPUT_CHANGED',
        'deviceName': 'Sony WH-1000XM4',
        'connectionType': 'bluetooth',
        'deviceType': 'Bluetooth A2DP',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      expect(sessionEngine.breakState.activeDeviceName, 'Sony WH-1000XM4');
    });
  });

  group('Debug Simulation Mechanism Tests', () {
    late FakeBreakNotificationService notificationService;
    late InMemoryDatabaseAdapter db;
    late BreakEngine breakEngine;
    late SessionEngine sessionEngine;
    final baseTime = DateTime(2026, 1, 1, 12, 0, 0);

    setUp(() async {
      notificationService = FakeBreakNotificationService();
      db = InMemoryDatabaseAdapter();
      breakEngine = BreakEngine(
        notificationService: notificationService,
        config: const BreakRuleConfig(
          breakSoonThreshold: Duration(minutes: 45),
          breakRecommendedThreshold: Duration(minutes: 60),
        ),
      );
      sessionEngine = SessionEngine(
        database: db,
        breakEngine: breakEngine,
      );
      await sessionEngine.initialize();
      sessionEngine.startMonitoring();
    });

    tearDown(() {
      sessionEngine.dispose();
    });

    test('BreakEngine debug simulation advances state, marks isSimulated, and triggers notifications', () async {
      final testDevice = AudioDevice(
        id: 'dev-1',
        name: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth A2DP',
        connectionType: 'bluetooth',
        firstSeen: baseTime,
        lastSeen: baseTime,
      );

      // Initially 0 duration
      await breakEngine.update(
        continuousListeningDuration: Duration.zero,
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.normal);
      expect(breakEngine.state.isSimulated, false);
      expect(notificationService.shownNotifications.length, 0);

      // Advance by 45 minutes
      breakEngine.debugAdvanceSimulatedListening(const Duration(minutes: 45));
      await breakEngine.update(
        continuousListeningDuration: Duration.zero,
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.breakSoon);
      expect(breakEngine.state.isSimulated, true);
      expect(breakEngine.state.continuousListeningDuration, const Duration(minutes: 45));
      expect(notificationService.shownNotifications.length, 1);
      expect(notificationService.shownNotifications.first['id'], 3001);

      // Duplicate suppression under simulation: updating again does not refire
      await breakEngine.update(
        continuousListeningDuration: Duration.zero,
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      // Advance by another 15 minutes to reach 60 minutes
      breakEngine.debugAdvanceSimulatedListening(const Duration(minutes: 15));
      await breakEngine.update(
        continuousListeningDuration: Duration.zero,
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.breakRecommended);
      expect(breakEngine.state.continuousListeningDuration, const Duration(minutes: 60));
      expect(notificationService.shownNotifications.length, 2);
      expect(notificationService.shownNotifications[1]['id'], 3002);

      // Reset simulated listening
      breakEngine.debugResetSimulatedListening();
      await breakEngine.update(
        continuousListeningDuration: Duration.zero,
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.isSimulated, false);
      expect(breakEngine.state.continuousListeningDuration, Duration.zero);
      expect(breakEngine.state.status, BreakStatus.normal);
    });

    test('SessionEngine debug simulation does NOT alter real session duration or SQLite persistence', () async {
      final startTime = DateTime.now();
      final connectEvent = {
        'type': 'DEVICE_CONNECTED',
        'deviceName': 'realme Buds T200 Lite',
        'deviceAddress': 'AA:BB:CC:DD:EE:FF',
        'connectionType': 'bluetooth',
        'deviceType': 'Bluetooth A2DP',
        'timestamp': startTime.millisecondsSinceEpoch,
      };
      final audioStart = {
        'type': 'AUDIO_STARTED',
        'deviceName': 'realme Buds T200 Lite',
        'deviceAddress': 'AA:BB:CC:DD:EE:FF',
        'connectionType': 'bluetooth',
        'timestamp': startTime.millisecondsSinceEpoch,
      };

      await sessionEngine.handleNativeEvent(connectEvent);
      await sessionEngine.handleNativeEvent(audioStart);

      expect(sessionEngine.breakState.status, BreakStatus.normal);
      expect(sessionEngine.breakState.isSimulated, false);
      expect(notificationService.shownNotifications.length, 0);

      // Debug simulate +45 minutes
      sessionEngine.debugSimulateContinuousListening(const Duration(minutes: 45));

      // Break state updates immediately
      expect(sessionEngine.breakState.isSimulated, true);
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(sessionEngine.breakState.continuousListeningDuration,
          greaterThanOrEqualTo(const Duration(minutes: 45)));
      expect(notificationService.shownNotifications.length, 1);
      expect(notificationService.shownNotifications.first['id'], 3001);

      // Advance by another 15 minutes (reach 60 min)
      sessionEngine.debugSimulateContinuousListening(const Duration(minutes: 15));
      expect(sessionEngine.breakState.status, BreakStatus.breakRecommended);
      expect(sessionEngine.breakState.continuousListeningDuration,
          greaterThanOrEqualTo(const Duration(minutes: 60)));
      expect(notificationService.shownNotifications.length, 2);
      expect(notificationService.shownNotifications[1]['id'], 3002);

      // Disconnect at t=5s
      final disconnectTime = startTime.add(const Duration(seconds: 5));
      await sessionEngine.handleNativeEvent({
        'type': 'DEVICE_DISCONNECTED',
        'deviceName': 'realme Buds T200 Lite',
        'deviceAddress': 'AA:BB:CC:DD:EE:FF',
        'connectionType': 'bluetooth',
        'timestamp': disconnectTime.millisecondsSinceEpoch,
      });

      // Break engine resets
      expect(sessionEngine.breakState.isSimulated, false);
      expect(sessionEngine.breakState.continuousListeningDuration, Duration.zero);

      // CRITICAL VERIFICATION: SQLite database records ONLY actual active listening seconds (5s)!
      expect(db.deviceSessions.length, 1);
      final savedSession = db.deviceSessions.first;
      expect(savedSession.activeListeningDurationSeconds, 5,
          reason: 'Simulated time must NEVER pollute SQLite listening duration records.');
      expect(savedSession.connectedDurationSeconds, 5,
          reason: 'Bluetooth connection duration must reflect actual connection time.');
    });

    test('Simulation while Bluetooth is idle does NOT fire notifications', () async {
      final now = DateTime.now();
      final connectEvent = {
        'type': 'DEVICE_CONNECTED',
        'deviceName': 'realme Buds T200 Lite',
        'deviceAddress': 'AA:BB:CC:DD:EE:FF',
        'connectionType': 'bluetooth',
        'deviceType': 'Bluetooth A2DP',
        'timestamp': now.millisecondsSinceEpoch,
      };

      await sessionEngine.handleNativeEvent(connectEvent);
      sessionEngine.triggerTickForTesting(now);

      // Idle connection: simulate +45 minutes
      sessionEngine.debugSimulateContinuousListening(const Duration(minutes: 45));

      // Break state shows breakSoon, but notification is NOT dispatched because isAudioPlaying is false
      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(sessionEngine.breakState.isSimulated, true);
      expect(notificationService.shownNotifications.length, 0,
          reason: 'Notifications must not fire when connected but idle/silent.');

      // Now start audio playback: notification should fire immediately on next tick/update
      final audioStart = {
        'type': 'AUDIO_STARTED',
        'deviceName': 'realme Buds T200 Lite',
        'deviceAddress': 'AA:BB:CC:DD:EE:FF',
        'connectionType': 'bluetooth',
        'timestamp': now.millisecondsSinceEpoch,
      };
      await sessionEngine.handleNativeEvent(audioStart);
      sessionEngine.triggerTickForTesting(now);

      expect(notificationService.shownNotifications.length, 1);
      expect(notificationService.shownNotifications.first['id'], 3001);
    });
  });
}
