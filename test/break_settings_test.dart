import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/models/audio_device.dart';
import 'package:listening_tracker/models/break_reminder_settings.dart';
import 'package:listening_tracker/models/break_state.dart';
import 'package:listening_tracker/services/break_engine.dart';
import 'package:listening_tracker/services/break_notification_service.dart';
import 'package:listening_tracker/main.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/views/break_settings_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testDevice = AudioDevice(
    id: 'test-device-1',
    name: 'Sony WH-1000XM5',
    deviceType: 'Bluetooth A2DP',
    connectionType: 'bluetooth',
    firstSeen: DateTime(2026, 1, 1),
    lastSeen: DateTime(2026, 1, 1),
  );

  group('BreakReminderSettings Model & Defaults', () {
    test('Default values preserve 45-minute interval and 10-minute snooze', () {
      const settings = BreakReminderSettings();
      expect(settings.enabled, isTrue);
      expect(settings.intervalMinutes, 45);
      expect(settings.snoozeMinutes, 10);
    });

    test('Validates intervals strictly within 15-120 minutes', () {
      expect(BreakReminderSettings.isValidInterval(14), isFalse);
      expect(BreakReminderSettings.isValidInterval(15), isTrue);
      expect(BreakReminderSettings.isValidInterval(30), isTrue);
      expect(BreakReminderSettings.isValidInterval(45), isTrue);
      expect(BreakReminderSettings.isValidInterval(60), isTrue);
      expect(BreakReminderSettings.isValidInterval(120), isTrue);
      expect(BreakReminderSettings.isValidInterval(121), isFalse);
    });

    test('Validates snooze choices (5, 10, 15 minutes)', () {
      expect(BreakReminderSettings.isValidSnooze(5), isTrue);
      expect(BreakReminderSettings.isValidSnooze(10), isTrue);
      expect(BreakReminderSettings.isValidSnooze(15), isTrue);
      expect(BreakReminderSettings.isValidSnooze(20), isFalse);
      expect(BreakReminderSettings.isValidSnooze(0), isFalse);
    });

    test('Converts to BreakRuleConfig with deterministic thresholds', () {
      const settings = BreakReminderSettings(
        enabled: true,
        intervalMinutes: 30,
        snoozeMinutes: 5,
      );
      final config = settings.toBreakRuleConfig();
      expect(config.enabled, isTrue);
      expect(config.breakSoonThreshold, const Duration(minutes: 30));
      expect(config.breakRecommendedThreshold, const Duration(minutes: 45));
      expect(config.snoozeDuration, const Duration(minutes: 5));
    });

    test('Serialization round-trip clamps out-of-range intervals', () {
      final invalidMap = {
        'enabled': 1,
        'interval_minutes': 300,
        'snooze_minutes': 99,
      };
      final parsed = BreakReminderSettings.fromMap(invalidMap);
      expect(parsed.intervalMinutes, 120); // Clamped to max
      expect(parsed.snoozeMinutes, 10); // Reverted to default snooze
    });
  });

  group('Settings Persistence via DatabaseAdapter', () {
    late InMemoryDatabaseAdapter db;

    setUp(() {
      db = InMemoryDatabaseAdapter();
    });

    test('Returns default 45m settings when no preferences have been saved yet', () async {
      final settings = await db.getBreakReminderSettings();
      expect(settings.enabled, isTrue);
      expect(settings.intervalMinutes, 45);
      expect(settings.snoozeMinutes, 10);
    });

    test('Persists and retrieves custom break settings', () async {
      const custom = BreakReminderSettings(
        enabled: false,
        intervalMinutes: 60,
        snoozeMinutes: 15,
      );
      await db.saveBreakReminderSettings(custom);

      final loaded = await db.getBreakReminderSettings();
      expect(loaded.enabled, isFalse);
      expect(loaded.intervalMinutes, 60);
      expect(loaded.snoozeMinutes, 15);
    });
  });

  group('BreakEngine Dynamic Settings, Snooze, & Dismissal', () {
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;

    setUp(() {
      notificationService = FakeBreakNotificationService();
      breakEngine = BreakEngine(
        notificationService: notificationService,
        config: const BreakRuleConfig(
          enabled: true,
          breakSoonThreshold: Duration(minutes: 45),
          breakRecommendedThreshold: Duration(minutes: 60),
          snoozeDuration: Duration(minutes: 10),
        ),
      );
    });

    test('Disabled reminders suppress notifications and keep normal status', () async {
      await breakEngine.updateConfig(
        const BreakRuleConfig(enabled: false),
      );

      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 50),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );

      expect(breakEngine.state.status, BreakStatus.normal);
      expect(breakEngine.state.isEnabled, isFalse);
      expect(notificationService.shownNotifications, isEmpty);
    });

    test('Dynamic updateConfig immediately reapplies thresholds without restart', () async {
      // 35 minutes is normal under 45m threshold
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 35),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.normal);
      expect(notificationService.shownNotifications, isEmpty);

      // Reconfigure threshold to 30m
      await breakEngine.updateConfig(
        const BreakRuleConfig(
          enabled: true,
          breakSoonThreshold: Duration(minutes: 30),
          breakRecommendedThreshold: Duration(minutes: 45),
        ),
      );

      expect(breakEngine.state.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);
    });

    test('Snooze suppresses notifications until snooze duration elapses', () async {
      // Reach threshold at 45m
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      // Snooze for 10 minutes
      await breakEngine.snooze(const Duration(minutes: 10));
      expect(breakEngine.isSnoozed, isTrue);
      expect(breakEngine.state.isSnoozed, isTrue);
      expect(notificationService.shownNotifications, isEmpty); // Active notification cancelled

      // At 50 minutes (still snoozed)
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 50),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.isSnoozed, isTrue);
      expect(notificationService.shownNotifications, isEmpty); // No notification during snooze

      // At 55 minutes (snooze expired: 45 + 10 = 55m)
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 55),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.isSnoozed, isFalse);
      expect(notificationService.shownNotifications.length, 1); // Dispatched again after snooze!
    });

    test('Dismiss cancels notification and prevents re-triggering for current status', () async {
      // Reach threshold at 45m
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications.length, 1);

      // Dismiss current reminder
      await breakEngine.dismiss();
      expect(breakEngine.state.isDismissed, isTrue);
      expect(notificationService.shownNotifications, isEmpty);

      // Continued listening at 48m does NOT trigger duplicate notification
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 48),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(notificationService.shownNotifications, isEmpty);

      // Reaching next threshold at 60m WILL trigger the new urgent reminder
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 60),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      expect(breakEngine.state.status, BreakStatus.breakRecommended);
      expect(notificationService.shownNotifications.length, 1);
    });

    test('Reset clears snooze, dismissal, and cancels notifications', () async {
      await breakEngine.update(
        continuousListeningDuration: const Duration(minutes: 45),
        isAudioPlaying: true,
        isInGracePeriod: false,
        activeDevice: testDevice,
      );
      await breakEngine.snooze(const Duration(minutes: 10));
      expect(breakEngine.isSnoozed, isTrue);

      await breakEngine.reset();
      expect(breakEngine.isSnoozed, isFalse);
      expect(breakEngine.state.continuousListeningDuration, Duration.zero);
      expect(breakEngine.state.status, BreakStatus.normal);
      expect(breakEngine.state.isDismissed, isFalse);
    });
  });

  group('SessionEngine Integration with Break Settings & Native Actions', () {
    late InMemoryDatabaseAdapter db;
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;
    late SessionEngine sessionEngine;
    late DateTime baseTime;

    setUp(() async {
      baseTime = DateTime(2026, 10, 12, 10, 0, 0);
      db = InMemoryDatabaseAdapter();
      notificationService = FakeBreakNotificationService();
      breakEngine = BreakEngine(
        notificationService: notificationService,
        config: const BreakRuleConfig(
          breakSoonThreshold: Duration(seconds: 4),
          breakRecommendedThreshold: Duration(seconds: 8),
          snoozeDuration: Duration(seconds: 2),
        ),
      );
      sessionEngine = SessionEngine(
        database: db,
        breakEngine: breakEngine,
      );
      await sessionEngine.initialize();
      await breakEngine.updateConfig(
        const BreakRuleConfig(
          breakSoonThreshold: Duration(seconds: 4),
          breakRecommendedThreshold: Duration(seconds: 8),
          snoozeDuration: Duration(seconds: 2),
        ),
      );
      sessionEngine.startMonitoring();
    });

    tearDown(() {
      sessionEngine.dispose();
    });

    test('Handles native BREAK_ACTION snooze event from NotificationManager', () async {
      // Connect and start audio playback with explicit baseTime
      await sessionEngine.handleNativeEvent({
        'type': 'DEVICE_CONNECTED',
        'deviceName': 'Sony WH-1000XM5',
        'connectionType': 'bluetooth',
        'address': '00:11:22:33:44:55',
        'timestamp': baseTime.millisecondsSinceEpoch,
      });
      await sessionEngine.handleNativeEvent({
        'type': 'AUDIO_STARTED',
        'deviceName': 'Sony WH-1000XM5',
        'connectionType': 'bluetooth',
        'address': '00:11:22:33:44:55',
        'timestamp': baseTime.millisecondsSinceEpoch,
      });

      // Advance past 4-second threshold
      sessionEngine.triggerTickForTesting(baseTime);
      for (int i = 1; i <= 4; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }

      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);
      expect(notificationService.shownNotifications.length, 1);

      // Simulate native notification action BroadcastReceiver dispatch
      await sessionEngine.handleNativeEvent({
        'type': 'BREAK_ACTION',
        'action': 'snooze',
        'id': 3001,
        'snoozeMinutes': 5,
        'timestamp': baseTime.add(const Duration(seconds: 4)).millisecondsSinceEpoch,
      });

      expect(sessionEngine.breakState.isSnoozed, isTrue);
      expect(notificationService.shownNotifications, isEmpty);
    });

    test('Handles native BREAK_ACTION dismiss event from NotificationManager', () async {
      await sessionEngine.handleNativeEvent({
        'type': 'DEVICE_CONNECTED',
        'deviceName': 'Sony WH-1000XM5',
        'connectionType': 'bluetooth',
        'address': '00:11:22:33:44:55',
        'timestamp': baseTime.millisecondsSinceEpoch,
      });
      await sessionEngine.handleNativeEvent({
        'type': 'AUDIO_STARTED',
        'deviceName': 'Sony WH-1000XM5',
        'connectionType': 'bluetooth',
        'address': '00:11:22:33:44:55',
        'timestamp': baseTime.millisecondsSinceEpoch,
      });

      sessionEngine.triggerTickForTesting(baseTime);
      for (int i = 1; i <= 4; i++) {
        sessionEngine.triggerTickForTesting(baseTime.add(Duration(seconds: i)));
      }

      expect(sessionEngine.breakState.status, BreakStatus.breakSoon);

      // Simulate native dismiss action
      await sessionEngine.handleNativeEvent({
        'type': 'BREAK_ACTION',
        'action': 'dismiss',
        'id': 3001,
        'timestamp': baseTime.add(const Duration(seconds: 4)).millisecondsSinceEpoch,
      });

      expect(sessionEngine.breakState.isDismissed, isTrue);
      expect(notificationService.shownNotifications, isEmpty);
    });

    test('updateBreakReminderSettings persists and updates SessionEngine dynamically', () async {
      const newSettings = BreakReminderSettings(
        enabled: true,
        intervalMinutes: 60,
        snoozeMinutes: 15,
      );
      await sessionEngine.updateBreakReminderSettings(newSettings);

      final loaded = await sessionEngine.getBreakReminderSettings();
      expect(loaded.intervalMinutes, 60);
      expect(loaded.snoozeMinutes, 15);
      expect(sessionEngine.breakEngine.config.breakSoonThreshold, const Duration(minutes: 60));
    });
  });

  group('BreakSettingsView UI Widget Tests', () {
    late InMemoryDatabaseAdapter db;
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;
    late SessionEngine sessionEngine;

    setUp(() async {
      db = InMemoryDatabaseAdapter();
      notificationService = FakeBreakNotificationService();
      breakEngine = BreakEngine(notificationService: notificationService);
      sessionEngine = SessionEngine(
        database: db,
        breakEngine: breakEngine,
      );
      await sessionEngine.initialize();
    });

    tearDown(() {
      sessionEngine.dispose();
    });

    testWidgets('Renders all quick chips and toggle with defaults', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BreakSettingsView(sessionEngine: sessionEngine),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Break Reminder Settings'), findsOneWidget);
      expect(find.byKey(const Key('break_reminder_enable_switch')), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_30')), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_45')), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_60')), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_custom')), findsOneWidget);
      expect(find.byKey(const Key('snooze_chip_5')), findsOneWidget);
      expect(find.byKey(const Key('snooze_chip_10')), findsOneWidget);
      expect(find.byKey(const Key('snooze_chip_15')), findsOneWidget);
    });

    testWidgets('Selecting quick interval updates state and saves to engine', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BreakSettingsView(sessionEngine: sessionEngine),
        ),
      );
      await tester.pumpAndSettle();

      // Tap 30 min chip
      await tester.tap(find.byKey(const Key('interval_chip_30')));
      await tester.pumpAndSettle();

      // Tap save in appbar
      await tester.tap(find.byKey(const Key('save_break_settings_button')));
      await tester.pumpAndSettle();

      final saved = await sessionEngine.getBreakReminderSettings();
      expect(saved.intervalMinutes, 30);
    });

    testWidgets('Custom interval validates 15-120 range', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BreakSettingsView(sessionEngine: sessionEngine),
        ),
      );
      await tester.pumpAndSettle();

      // Select Custom
      await tester.tap(find.byKey(const Key('interval_chip_custom')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('custom_interval_field')), findsOneWidget);

      // Enter out-of-range value (10 min)
      await tester.enterText(find.byKey(const Key('custom_interval_field')), '10');
      await tester.pumpAndSettle();

      expect(find.text('Must be between 15 and 120 minutes'), findsOneWidget);

      // Enter valid value (50 min)
      await tester.enterText(find.byKey(const Key('custom_interval_field')), '50');
      await tester.pumpAndSettle();

      expect(find.text('Must be between 15 and 120 minutes'), findsNothing);

      // Save via AppBar button
      await tester.tap(find.byKey(const Key('save_break_settings_button')));
      await tester.pumpAndSettle();

      final saved = await sessionEngine.getBreakReminderSettings();
      expect(saved.intervalMinutes, 50);
    });

    testWidgets('Disabling master toggle disables reminders', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BreakSettingsView(sessionEngine: sessionEngine),
        ),
      );
      await tester.pumpAndSettle();

      // Toggle off
      await tester.tap(find.byKey(const Key('break_reminder_enable_switch')));
      await tester.pumpAndSettle();

      // Save via AppBar button
      await tester.tap(find.byKey(const Key('save_break_settings_button')));
      await tester.pumpAndSettle();

      final saved = await sessionEngine.getBreakReminderSettings();
      expect(saved.enabled, isFalse);
      expect(sessionEngine.breakEngine.config.enabled, isFalse);
    });
  });

  group('Live Monitor Dashboard -> Break Settings Navigation Widget Tests', () {
    late InMemoryDatabaseAdapter db;
    late FakeBreakNotificationService notificationService;
    late BreakEngine breakEngine;
    late SessionEngine engine;

    setUp(() {
      db = InMemoryDatabaseAdapter();
      notificationService = FakeBreakNotificationService();
      breakEngine = BreakEngine(notificationService: notificationService);
      engine = SessionEngine(database: db, breakEngine: breakEngine);
    });

    tearDown(() {
      engine.dispose();
    });

    Widget buildTestApp() {
      return MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MonitorDashboard(engine: engine, database: db),
      );
    }

    testWidgets('Break Engine card displays visible settings icon next to heading and opens settings screen', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      final headingSettingsIconFinder = find.byKey(const Key('break_engine_settings_icon_button'));
      expect(headingSettingsIconFinder, findsOneWidget);

      await tester.tap(headingSettingsIconFinder);
      await tester.pumpAndSettle();

      expect(find.text('Break Reminder Settings'), findsOneWidget);
      expect(find.byKey(const Key('break_reminder_enable_switch')), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_45')), findsOneWidget);
    });

    testWidgets('Break Engine card displays visible Break Settings button and opens settings screen', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      final cardButtonFinder = find.byKey(const Key('card_break_settings_button'));
      expect(cardButtonFinder, findsOneWidget);
      expect(find.text('Break Settings'), findsOneWidget);

      await tester.ensureVisible(cardButtonFinder);
      await tester.pumpAndSettle();

      await tester.tap(cardButtonFinder);
      await tester.pumpAndSettle();

      expect(find.text('Break Reminder Settings'), findsOneWidget);
      expect(find.byKey(const Key('interval_chip_30')), findsOneWidget);
    });

    testWidgets('Break Settings button is rendered directly below debug simulation section in Live Monitor', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      final debugSimHeaderFinder = find.text('DEBUG TEST SIMULATION');
      expect(debugSimHeaderFinder, findsOneWidget);

      final cardButtonFinder = find.byKey(const Key('card_break_settings_button'));
      expect(cardButtonFinder, findsOneWidget);

      // Verify button is positioned below the debug simulation section
      final debugSimTop = tester.getTopLeft(debugSimHeaderFinder).dy;
      final buttonTop = tester.getTopLeft(cardButtonFinder).dy;
      expect(buttonTop, greaterThan(debugSimTop));
    });
  });
}
