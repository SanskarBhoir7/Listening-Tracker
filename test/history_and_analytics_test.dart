import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/models/connection_record.dart';
import 'package:listening_tracker/models/listening_session.dart';
import 'package:listening_tracker/views/analytics_view.dart';
import 'package:listening_tracker/views/history_view.dart';

void main() {
  late InMemoryDatabaseAdapter db;

  setUp(() {
    db = InMemoryDatabaseAdapter();
  });

  Widget buildTestApp({
    required Widget child,
    double? textScaleFactor,
    Size? surfaceSize,
  }) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final mediaQuery = MediaQuery.of(context).copyWith(
              textScaler: textScaleFactor != null
                  ? TextScaler.linear(textScaleFactor)
                  : null,
            );
            return MediaQuery(
              data: mediaQuery,
              child: child,
            );
          },
        ),
      ),
    );
  }

  group('History View Widget Tests', () {
    testWidgets('1. History tab displays correctly', (tester) async {
      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Daily Summary'), findsOneWidget);
      expect(find.textContaining('Recorded Sessions'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_today), findsOneWidget);
    });

    testWidgets('2. Today loads correctly with populated sessions and stats', (tester) async {
      final now = DateTime.now();
      final startTime = DateTime(now.year, now.month, now.day, 10, 0, 0);
      final endTime = startTime.add(const Duration(minutes: 30));

      // Save a connection record (strictly for connection time: 1800s -> 30m)
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-1',
        deviceId: 'bt-wh-1000xm4',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: startTime,
        disconnectedAt: endTime,
        durationSeconds: 1800,
      ));

      // Save a listening session (active listening duration: 1200s -> 20m)
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-1',
        deviceId: 'bt-wh-1000xm4',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: startTime,
        disconnectedAt: endTime,
        listeningStartedAt: startTime,
        listeningEndedAt: endTime,
        connectedDurationSeconds: 1800,
        activeListeningDurationSeconds: 1200,
        silentDurationSeconds: 600,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      // Check daily summary metrics (PeriodStats formats as "20m", "30m", "10m")
      expect(find.text('Daily Summary'), findsOneWidget);
      expect(find.text('20m'), findsWidgets); // Active listening (1200s)
      expect(find.text('30m'), findsWidgets); // Connected time (1800s)
      expect(find.text('10m'), findsWidgets); // Silent time (600s)

      // Check session card
      expect(find.text('Sony WH-1000XM4'), findsOneWidget);
      expect(find.text('Listening Time'), findsOneWidget);
    });

    testWidgets('3. Changing date updates the displayed data', (tester) async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayStart = DateTime(yesterday.year, yesterday.month, yesterday.day, 14, 0, 0);
      final yesterdayEnd = yesterdayStart.add(const Duration(minutes: 45));

      // Save a session for yesterday
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-yesterday',
        deviceId: 'airpods-pro',
        deviceName: 'AirPods Pro',
        deviceType: 'Bluetooth Headphones',
        connectedAt: yesterdayStart,
        disconnectedAt: yesterdayEnd,
        durationSeconds: 2700,
      ));

      await db.saveDeviceSession(ListeningSession(
        id: 'sess-yesterday',
        deviceId: 'airpods-pro',
        deviceName: 'AirPods Pro',
        deviceType: 'Bluetooth Headphones',
        connectedAt: yesterdayStart,
        disconnectedAt: yesterdayEnd,
        listeningStartedAt: yesterdayStart,
        listeningEndedAt: yesterdayEnd,
        connectedDurationSeconds: 2700,
        activeListeningDurationSeconds: 2400,
        silentDurationSeconds: 300,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      // Initially Today has no sessions
      expect(find.text('No Sessions Recorded'), findsOneWidget);

      // Tap previous day button
      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();

      // Yesterday should now show the session
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('AirPods Pro'), findsOneWidget);
      expect(find.text('40m'), findsWidgets); // Active listening (2400s)

      // Tap Today button to navigate back
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('3b. Tapping refresh button re-queries database and updates displayed data immediately', (tester) async {
      final now = DateTime.now();
      final session1Start = DateTime(now.year, now.month, now.day, 10, 0, 0);
      final session1End = session1Start.add(const Duration(minutes: 20));

      // 1. Initial state: 1 session in database for Today
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-1',
        deviceId: 'realme-buds',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth Headphones',
        connectedAt: session1Start,
        disconnectedAt: session1End,
        durationSeconds: 1200,
      ));
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-1',
        deviceId: 'realme-buds',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth Headphones',
        connectedAt: session1Start,
        disconnectedAt: session1End,
        listeningStartedAt: session1Start,
        listeningEndedAt: session1End,
        connectedDurationSeconds: 1200,
        activeListeningDurationSeconds: 1200,
        silentDurationSeconds: 0,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      // Verify initial state: exactly 1 session displayed
      expect(find.text('Recorded Sessions (1)'), findsOneWidget);
      expect(find.text('realme Buds T200 Lite'), findsOneWidget);
      expect(find.text('20m'), findsWidgets);

      // 2. A new session is finalized while History view is open on Today
      final session2Start = DateTime(now.year, now.month, now.day, 12, 0, 0);
      final session2End = session2Start.add(const Duration(minutes: 30));
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-2',
        deviceId: 'wh-1000xm4',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: session2Start,
        disconnectedAt: session2End,
        durationSeconds: 1800,
      ));
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-2',
        deviceId: 'wh-1000xm4',
        deviceName: 'Sony WH-1000XM4',
        deviceType: 'Bluetooth Headphones',
        connectedAt: session2Start,
        disconnectedAt: session2End,
        listeningStartedAt: session2Start,
        listeningEndedAt: session2End,
        connectedDurationSeconds: 1800,
        activeListeningDurationSeconds: 1800,
        silentDurationSeconds: 0,
        status: 'completed',
      ));

      // Without refresh, screen still shows 1 session
      expect(find.text('Recorded Sessions (1)'), findsOneWidget);
      expect(find.text('Sony WH-1000XM4'), findsNothing);

      // 3. Tap the refresh button in History view
      await tester.tap(find.byKey(const Key('history_refresh_button')));
      await tester.pumpAndSettle();

      // 4. Verify History immediately updated to show 2 sessions and combined duration
      expect(find.text('Recorded Sessions (2)'), findsOneWidget);
      expect(find.text('realme Buds T200 Lite'), findsOneWidget);
      expect(find.text('Sony WH-1000XM4'), findsOneWidget);
      expect(find.text('50m'), findsWidgets); // 20m + 30m = 50m active listening
    });

    testWidgets('4. Empty date shows empty state without error', (tester) async {
      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('No Sessions Recorded'), findsOneWidget);
      expect(find.text('0s'), findsWidgets);
    });

    testWidgets('5. Session information is displayed correctly', (tester) async {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9, 15, 0);
      final end = start.add(const Duration(minutes: 25));

      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-bose',
        deviceId: 'bose-qc45',
        deviceName: 'Bose QC45',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start,
        disconnectedAt: end,
        durationSeconds: 1500,
      ));

      await db.saveDeviceSession(ListeningSession(
        id: 'sess-bose',
        deviceId: 'bose-qc45',
        deviceName: 'Bose QC45',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start,
        disconnectedAt: end,
        listeningStartedAt: start,
        listeningEndedAt: end,
        connectedDurationSeconds: 1500,
        activeListeningDurationSeconds: 1200,
        silentDurationSeconds: 300,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      expect(find.text('Bose QC45'), findsOneWidget);
      expect(find.textContaining('9:15 AM'), findsOneWidget);
      expect(find.textContaining('9:40 AM'), findsOneWidget);
      expect(find.text('20m'), findsWidgets);
    });

    testWidgets('6. Connection and listening durations are displayed separately', (tester) async {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 8, 0, 0);
      final end = start.add(const Duration(minutes: 60));

      // Connection is 60 minutes, Active listening is only 15 minutes, Silent is 45 minutes
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-sep',
        deviceId: 'sony-xm5',
        deviceName: 'Sony WH-1000XM5',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start,
        disconnectedAt: end,
        durationSeconds: 3600,
      ));

      await db.saveDeviceSession(ListeningSession(
        id: 'sess-sep',
        deviceId: 'sony-xm5',
        deviceName: 'Sony WH-1000XM5',
        deviceType: 'Bluetooth Headphones',
        connectedAt: start,
        disconnectedAt: end,
        listeningStartedAt: start,
        listeningEndedAt: end,
        connectedDurationSeconds: 3600,
        activeListeningDurationSeconds: 900,
        silentDurationSeconds: 2700,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      // Daily summary must separately reflect 15m active vs 1h connection
      expect(find.text('15m'), findsWidgets); // Active listening
      expect(find.text('1h'), findsWidgets);  // Bluetooth connected
      expect(find.text('45m'), findsWidgets); // Silent / paused
    });
  });

  group('Analytics View Widget Tests', () {
    testWidgets('7. Today period loads correctly', (tester) async {
      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      expect(find.text('Period Summary'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('7 Days'), findsOneWidget);
      expect(find.text('30 Days'), findsOneWidget);
    });

    testWidgets('8. Last 7 days period loads correctly', (tester) async {
      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('7 Days'));
      await tester.pumpAndSettle();

      expect(find.text('Period Summary'), findsOneWidget);
      expect(find.text('Daily Trend (7 days)'), findsOneWidget);
    });

    testWidgets('9. Last 30 days period loads correctly', (tester) async {
      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('30 Days'));
      await tester.pumpAndSettle();

      expect(find.text('Period Summary'), findsOneWidget);
      expect(find.text('Daily Trend (30 days)'), findsOneWidget);
    });

    testWidgets('10. Summary metrics display correctly using AnalyticsCalculator', (tester) async {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 11, 0, 0);
      final end = start.add(const Duration(minutes: 50));

      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-a',
        deviceId: 'dev-1',
        deviceName: 'Pixel Buds Pro',
        deviceType: 'Bluetooth Earbuds',
        connectedAt: start,
        disconnectedAt: end,
        durationSeconds: 3000,
      ));

      await db.saveDeviceSession(ListeningSession(
        id: 'sess-a',
        deviceId: 'dev-1',
        deviceName: 'Pixel Buds Pro',
        deviceType: 'Bluetooth Earbuds',
        connectedAt: start,
        disconnectedAt: end,
        listeningStartedAt: start,
        listeningEndedAt: end,
        connectedDurationSeconds: 3000,
        activeListeningDurationSeconds: 1500, // 50% ratio
        silentDurationSeconds: 1500,
        status: 'completed',
      ));

      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      // Check summary fields (1500s -> 25m, 3000s -> 50m)
      expect(find.text('Total Listening Time'), findsOneWidget);
      expect(find.text('25m'), findsWidgets);
      expect(find.text('Total Bluetooth Time'), findsOneWidget);
      expect(find.text('50m'), findsWidgets);
      expect(find.text('Listening Ratio'), findsOneWidget);
      expect(find.text('50.0%'), findsWidgets); // 1500 / 3000 = 50.0%
      expect(find.text('Pixel Buds Pro'), findsWidgets); // Most used device
    });

    testWidgets('11. Device breakdown displays correctly with connection-only device', (tester) async {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 12, 0, 0);
      final endActive = start.add(const Duration(minutes: 30));

      // Device A: has listening
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-active',
        deviceId: 'active-headset',
        deviceName: 'Active Headset',
        deviceType: 'Bluetooth',
        connectedAt: start,
        disconnectedAt: endActive,
        durationSeconds: 1800,
      ));
      await db.saveDeviceSession(ListeningSession(
        id: 'sess-active',
        deviceId: 'active-headset',
        deviceName: 'Active Headset',
        deviceType: 'Bluetooth',
        connectedAt: start,
        disconnectedAt: endActive,
        listeningStartedAt: start,
        listeningEndedAt: endActive,
        connectedDurationSeconds: 1800,
        activeListeningDurationSeconds: 1200,
        silentDurationSeconds: 600,
        status: 'completed',
      ));

      // Device B: Connected ONLY (no listening sessions)
      await db.saveConnectionRecord(ConnectionRecord(
        id: 'conn-idle',
        deviceId: 'idle-car',
        deviceName: 'Car Bluetooth',
        deviceType: 'Bluetooth Car',
        connectedAt: start,
        disconnectedAt: start.add(const Duration(minutes: 20)),
        durationSeconds: 1200,
      ));

      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      expect(find.text('Active Headset'), findsWidgets);
      expect(find.text('Car Bluetooth'), findsOneWidget);
      expect(find.text('CONNECTED ONLY'), findsOneWidget); // Badge for connection-only device
    });

    testWidgets('12. Daily trend displays correctly preserving empty days', (tester) async {
      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      // Switch to 7 days
      await tester.tap(find.text('7 Days'));
      await tester.pumpAndSettle();

      // The 7 days should all be rendered even when empty
      expect(find.text('Daily Trend (7 days)'), findsOneWidget);
      expect(find.text('No activity'), findsWidgets);
    });

    testWidgets('13. Empty analytics state works cleanly without errors', (tester) async {
      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('0.0%'), findsOneWidget); // Zero ratio
      expect(find.text('None'), findsOneWidget); // Most-used device
      expect(find.text('No device activity in this period.'), findsOneWidget);
    });
  });

  group('Responsiveness & Overflow Prevention Tests', () {
    testWidgets('14. History at 320px logical width has no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Daily Summary'), findsOneWidget);
    });

    testWidgets('15. Analytics at 320px logical width has no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Period Summary'), findsOneWidget);
    });

    testWidgets('16. History at 360px logical width has no overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp(child: HistoryView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Daily Summary'), findsOneWidget);
    });

    testWidgets('17. Analytics at 360px logical width has no overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(buildTestApp(child: AnalyticsView(database: db)));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Period Summary'), findsOneWidget);
    });

    testWidgets('18. Increased text scaling (1.8x) does not cause RenderFlex overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      // Test History with 1.8x text scaling
      await tester.pumpWidget(buildTestApp(
        child: HistoryView(database: db),
        textScaleFactor: 1.8,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Test Analytics with 1.8x text scaling
      await tester.pumpWidget(buildTestApp(
        child: AnalyticsView(database: db),
        textScaleFactor: 1.8,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
