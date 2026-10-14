import 'package:flutter_test/flutter_test.dart';
import 'package:listening_tracker/database/database_adapter.dart';
import 'package:listening_tracker/services/break_engine.dart';
import 'package:listening_tracker/services/break_notification_service.dart';
import 'package:listening_tracker/session_engine.dart';
import 'package:listening_tracker/tracking_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snooze and dismiss do not advance simulated listening time', () async {
    final notifications = FakeBreakNotificationService();
    final breakEngine = BreakEngine(notificationService: notifications);
    final database = InMemoryDatabaseAdapter();
    final sessionEngine = SessionEngine(
      database: database,
      breakEngine: breakEngine,
    );
    await sessionEngine.initialize();
    sessionEngine.startMonitoring();
    addTearDown(sessionEngine.dispose);

    sessionEngine.debugSimulateContinuousListening(const Duration(minutes: 45));
    expect(sessionEngine.breakState.continuousListeningDuration,
        const Duration(minutes: 45));
    expect(sessionEngine.breakState.isSimulated, isTrue);

    await sessionEngine.snoozeBreakReminder(const Duration(minutes: 5));
    expect(sessionEngine.breakState.continuousListeningDuration,
        const Duration(minutes: 45));
    expect(breakEngine.debugSimulatedOffset, const Duration(minutes: 45));

    await sessionEngine.dismissBreakReminder();
    expect(sessionEngine.breakState.continuousListeningDuration,
        const Duration(minutes: 45));
    expect(breakEngine.debugSimulatedOffset, const Duration(minutes: 45));

    await sessionEngine.snoozeBreakReminder(const Duration(minutes: 5));
    await sessionEngine.dismissBreakReminder();
    expect(sessionEngine.breakState.continuousListeningDuration,
        const Duration(minutes: 45));
    expect(breakEngine.debugSimulatedOffset, const Duration(minutes: 45));
    expect(sessionEngine.sessionState, ListeningSessionState.idle);
    expect(database.deviceSessions, isEmpty);
    expect(database.connectionRecords, isEmpty);
  });
}
