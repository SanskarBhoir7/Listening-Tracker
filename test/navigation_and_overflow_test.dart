import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/main.dart';
import 'package:listening_tracker/models/connection_record.dart';
import 'package:listening_tracker/models/listening_session.dart';
import 'package:listening_tracker/session_engine.dart';

void main() {
  late InMemoryDatabaseAdapter db;
  late SessionEngine engine;

  setUp(() {
    db = InMemoryDatabaseAdapter();
    engine = SessionEngine(database: db);
  });

  tearDown(() {
    engine.dispose();
  });

  Widget buildTestApp({Widget? child, double? textScaleFactor}) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) {
          final mediaQuery = MediaQuery.of(context).copyWith(
            textScaler: textScaleFactor != null
                ? TextScaler.linear(textScaleFactor)
                : null,
          );
          return MediaQuery(
            data: mediaQuery,
            child: child ?? MonitorDashboard(engine: engine, database: db),
          );
        },
      ),
    );
  }

  group('Navigation Architecture Widget Tests', () {
    testWidgets('Live Monitor is initial tab and displays live content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Verify default tab is Live Monitor
      expect(find.text('LISTENING TRACKER — LIVE MONITOR'), findsOneWidget);
      expect(find.text('Live Monitor'), findsWidgets);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Analytics'), findsOneWidget);

      // Verify core Live Monitor cards are present
      expect(find.text('START MONITORING'), findsOneWidget);
      expect(find.text('Live Session Tracking (Separated)'), findsOneWidget);
      expect(find.text('Bluetooth State'), findsOneWidget);
      expect(find.text('Event Log'), findsOneWidget);
    });

    testWidgets('Tapping History changes section to History view', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Tap History in NavigationBar
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      // Title updates
      expect(find.text('LISTENING HISTORY'), findsOneWidget);
      // History view elements are visible
      expect(find.text('Daily Summary'), findsOneWidget);
      expect(find.textContaining('Recorded Sessions'), findsOneWidget);
    });

    testWidgets('Tapping AppBar refresh button on History tab reloads current day history data', (tester) async {
      final now = DateTime.now();
      final start1 = DateTime(now.year, now.month, now.day, 8, 0, 0);
      final end1 = start1.add(const Duration(minutes: 15));

      // Initially 1 session
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-history-1',
        deviceId: 'buds-1',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start1,
        disconnectedAt: end1,
        durationSeconds: 900,
      ));
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-history-1',
        deviceId: 'buds-1',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start1,
        disconnectedAt: end1,
        listeningStartedAt: start1,
        listeningEndedAt: end1,
        connectedDurationSeconds: 900,
        activeListeningDurationSeconds: 900,
        silentDurationSeconds: 0,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Navigate to History tab
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('Recorded Sessions (1)'), findsOneWidget);
      expect(find.text('realme Buds T200 Lite'), findsOneWidget);

      // Now a 2nd session is recorded in DB (e.g. while looking at History view)
      final start2 = DateTime(now.year, now.month, now.day, 11, 0, 0);
      final end2 = start2.add(const Duration(minutes: 25));
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-history-2',
        deviceId: 'buds-2',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start2,
        disconnectedAt: end2,
        durationSeconds: 1500,
      ));
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-history-2',
        deviceId: 'buds-2',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start2,
        disconnectedAt: end2,
        listeningStartedAt: start2,
        listeningEndedAt: end2,
        connectedDurationSeconds: 1500,
        activeListeningDurationSeconds: 1500,
        silentDurationSeconds: 0,
        status: 'completed',
      ));

      // Before tapping refresh, screen still shows only 1 session
      expect(find.text('Recorded Sessions (1)'), findsOneWidget);

      // Tap AppBar refresh button
      await tester.tap(find.byKey(const Key('appbar_refresh_button')));
      await tester.pumpAndSettle();

      // Immediately reloaded to 2 sessions with both devices visible
      expect(find.text('Recorded Sessions (2)'), findsOneWidget);
      expect(find.text('realme Buds T200 Lite'), findsOneWidget);
      expect(find.text('Sony WH-1000XM4'), findsOneWidget);
      expect(find.text('40m'), findsWidgets); // 15m + 25m = 40m
    });

    testWidgets('Tapping Analytics changes section to Analytics view', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Tap Analytics in NavigationBar
      await tester.tap(find.text('Analytics'));
      await tester.pumpAndSettle();

      // Title updates
      expect(find.text('LISTENING ANALYTICS'), findsOneWidget);
      // Analytics view elements are visible
      expect(find.text('Period Summary'), findsOneWidget);
      expect(find.textContaining('Device Breakdown'), findsOneWidget);
    });

    testWidgets('Returning to Live Monitor preserves state and content', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Navigate away to History
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('LISTENING HISTORY'), findsOneWidget);

      // Return to Live Monitor
      await tester.tap(find.text('Live Monitor'));
      await tester.pumpAndSettle();

      // Live Monitor content restored
      expect(find.text('LISTENING TRACKER — LIVE MONITOR'), findsOneWidget);
      expect(find.text('Live Session Tracking (Separated)'), findsOneWidget);
      expect(find.text('Bluetooth State'), findsOneWidget);
    });
  });

  group('UI Responsiveness & Overflow Prevention Tests', () {
    testWidgets('Narrow screen 320 logical pixels renders with zero RenderFlex overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Ensure zero overflow errors occurred
      expect(tester.takeException(), isNull);

      // Verify Event Log buttons are visible and functional
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);

      await tester.ensureVisible(find.text('Clear'));
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Standard mobile 360 logical pixels renders cleanly without overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Live Session Tracking (Separated)'), findsOneWidget);
      expect(find.text('Event Log'), findsOneWidget);
    });

    testWidgets('Increased accessibility text scaling (1.8x) on narrow width (320px) has zero overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp(textScaleFactor: 1.8));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Event Log'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });
  });
}
