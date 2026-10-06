import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/models/audio_device.dart';
import 'package:listening_tracker/models/listening_session.dart';
import 'package:listening_tracker/models/continuous_session.dart';
import 'package:listening_tracker/models/daily_stats.dart';

void main() {
  group('AudioDevice model tests', () {
    test('generateStableId with MAC address', () {
      final id = AudioDevice.generateStableId(
        name: 'realme Buds T200 Lite',
        connectionType: 'bluetooth',
        address: '88:C9:E8:12:34:56',
      );
      expect(id, equals('addr_88_c9_e8_12_34_56'));
    });

    test('generateStableId fallback without address', () {
      final id1 = AudioDevice.generateStableId(
        name: 'realme Buds T200 Lite',
        connectionType: 'bluetooth',
      );
      final id2 = AudioDevice.generateStableId(
        name: 'realme Buds T200 Lite',
        connectionType: 'bluetooth',
      );
      expect(id1, equals('bluetooth_realme_buds_t200_lite'));
      // Identical device generates identical stable ID across reconnects
      expect(id1, equals(id2));
    });

    test('generateStableId for wired headphones', () {
      final id = AudioDevice.generateStableId(
        name: 'Wired Headphones',
        connectionType: 'wired_3.5mm',
      );
      expect(id, equals('wired_3_5mm_wired_headphones'));
    });
  });

  group('ListeningSession model tests', () {
    test('durations and mathematical invariant', () {
      final now = DateTime.now();
      const connectedSecs = 360; // 6 minutes
      const activeSecs = 318; // 5m 18s
      const silentSecs = 42; // 42s

      final session = ListeningSession(
        id: 'ds_test_1',
        deviceId: 'bluetooth_realme_buds_t200_lite',
        deviceName: 'realme Buds T200 Lite',
        deviceType: 'Bluetooth A2DP',
        connectedAt: now,
        disconnectedAt: now.add(const Duration(minutes: 6)),
        connectedDurationSeconds: connectedSecs,
        activeListeningDurationSeconds: activeSecs,
        silentDurationSeconds: silentSecs,
        status: 'completed',
      );

      // Verify invariant: connected == active + silent
      expect(
        session.connectedDurationSeconds,
        equals(session.activeListeningDurationSeconds + session.silentDurationSeconds),
      );

      // Verify formatted strings
      expect(session.connectedDurationFormatted, equals('6m 0s'));
      expect(session.activeListeningDurationFormatted, equals('5m 18s'));
      expect(session.silentDurationFormatted, equals('42s'));
    });
  });

  group('ContinuousListeningSession model tests', () {
    test('multi-device continuous tracking', () {
      final now = DateTime.now();
      final session = ContinuousListeningSession(
        id: 'cs_test_1',
        startedAt: now,
        endedAt: now.add(const Duration(minutes: 75)),
        activeListeningDurationSeconds: 4500, // 1h 15m
        pausedDurationSeconds: 120, // 2m paused during device switch
        deviceIds: [
          'bluetooth_realme_buds_t200_lite',
          'bluetooth_sony_wh1000xm4',
        ],
        deviceNames: [
          'realme Buds T200 Lite',
          'Sony WH-1000XM4',
        ],
        status: 'completed',
      );

      expect(session.deviceIds.length, equals(2));
      expect(session.deviceNames.contains('realme Buds T200 Lite'), isTrue);
      expect(session.deviceNames.contains('Sony WH-1000XM4'), isTrue);
      expect(session.activeListeningDurationFormatted, equals('1h 15m 0s'));
    });
  });

  group('DailyStats model tests', () {
    test('daily aggregations format properly', () {
      final today = DateTime.now();
      final stats = DailyStats(
        date: today,
        totalConnectedSeconds: 8040, // 2h 14m
        totalActiveListeningSeconds: 6420, // 1h 47m
        totalSilentSeconds: 1620, // 27m
        deviceSessionCount: 4,
        continuousSessionCount: 2,
        devicesUsedCount: 2,
        longestContinuousSessionSeconds: 4500, // 1h 15m
      );

      expect(stats.totalConnectedFormatted, equals('2h 14m'));
      expect(stats.totalActiveListeningFormatted, equals('1h 47m'));
      expect(stats.totalSilentFormatted, equals('27m'));
      expect(stats.deviceSessionCount, equals(4));
      expect(stats.devicesUsedCount, equals(2));
    });
  });

  group('UI responsiveness and overflow check', () {
    testWidgets('responsive rows do not overflow on narrow screens', (tester) async {
      // Simulate a small/narrow phone screen (width 320, height 640)
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          // Long device name row
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      minWidth: 90, maxWidth: 130),
                                  child: const Text('Name'),
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'realme Buds T200 Lite Bluetooth Stereo Earphones',
                                    textAlign: TextAlign.end,
                                    softWrap: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Long status string row
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      minWidth: 90, maxWidth: 130),
                                  child: const Text('Grace Period'),
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    '3 min (EXPERIMENTAL CONFIGURABLE)',
                                    textAlign: TextAlign.end,
                                    softWrap: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Ensure zero overflow errors occurred
      expect(tester.takeException(), isNull);
      expect(find.text('realme Buds T200 Lite Bluetooth Stereo Earphones'), findsOneWidget);
      expect(find.text('3 min (EXPERIMENTAL CONFIGURABLE)'), findsOneWidget);
    });
  });
}
