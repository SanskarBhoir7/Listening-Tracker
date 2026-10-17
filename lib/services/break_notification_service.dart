import '../audio_monitor_service.dart';

/// Notification service interface for dispatching and cancelling break reminders.
abstract class BreakNotificationService {
  /// Displays a local notification for a break recommendation.
  Future<bool> showBreakNotification({
    required int id,
    required String title,
    required String body,
    int snoozeMinutes = 10,
    required String sessionGeneration,
  });

  /// Cancels an active break notification by its unique ID.
  Future<void> cancelBreakNotification(int id);

  /// Cancels all active break notifications.
  Future<void> cancelAllBreakNotifications();

  /// Checks whether notification permission is granted.
  Future<bool> hasNotificationPermission();

  /// Requests notification permission once without nagging if denied.
  Future<bool> requestNotificationPermission();
}

/// Native Android implementation of [BreakNotificationService] using MethodChannel.
class NativeBreakNotificationService implements BreakNotificationService {
  final AudioMonitorService _audioService;
  bool _hasPromptedPermission = false;

  static const int breakSoonNotificationId = 3001;
  static const int breakRecommendedNotificationId = 3002;

  NativeBreakNotificationService({AudioMonitorService? audioService})
      : _audioService = audioService ?? AudioMonitorService();

  @override
  Future<bool> showBreakNotification({
    required int id,
    required String title,
    required String body,
    int snoozeMinutes = 10,
    required String sessionGeneration,
  }) async {
    try {
      return await _audioService.showBreakNotification(
        id: id,
        title: title,
        body: body,
        snoozeMinutes: snoozeMinutes,
        sessionGeneration: sessionGeneration,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancelBreakNotification(int id) async {
    try {
      await _audioService.cancelBreakNotification(id);
    } catch (_) {}
  }

  @override
  Future<void> cancelAllBreakNotifications() async {
    try {
      await _audioService.cancelAllBreakNotifications();
    } catch (_) {}
  }

  @override
  Future<bool> hasNotificationPermission() async {
    try {
      final perms = await _audioService.checkPermissions();
      return perms['post_notifications'] ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    if (_hasPromptedPermission) {
      return hasNotificationPermission();
    }
    _hasPromptedPermission = true;
    try {
      await _audioService.requestPermissions();
    } catch (_) {}
    return hasNotificationPermission();
  }
}

/// In-memory fake implementation of [BreakNotificationService] for deterministic testing.
class FakeBreakNotificationService implements BreakNotificationService {
  final List<Map<String, dynamic>> shownNotifications = [];
  final List<int> cancelledNotificationIds = [];
  bool permissionGranted;
  int requestPermissionCallCount = 0;
  bool _hasPrompted = false;

  FakeBreakNotificationService({this.permissionGranted = true});

  @override
  Future<bool> showBreakNotification({
    required int id,
    required String title,
    required String body,
    int snoozeMinutes = 10,
    required String sessionGeneration,
  }) async {
    if (!permissionGranted) return false;
    shownNotifications.add({
      'id': id,
      'title': title,
      'body': body,
      'snoozeMinutes': snoozeMinutes,
      'sessionGeneration': sessionGeneration,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }

  @override
  Future<void> cancelBreakNotification(int id) async {
    cancelledNotificationIds.add(id);
    shownNotifications.removeWhere((n) => n['id'] == id);
  }

  int cancelAllCallCount = 0;

  @override
  Future<void> cancelAllBreakNotifications() async {
    cancelAllCallCount++;
    cancelledNotificationIds.addAll(
      shownNotifications.map((n) => n['id'] as int),
    );
    shownNotifications.clear();
  }

  @override
  Future<bool> hasNotificationPermission() async => permissionGranted;

  @override
  Future<bool> requestNotificationPermission() async {
    if (_hasPrompted) {
      return permissionGranted;
    }
    _hasPrompted = true;
    requestPermissionCallCount++;
    return permissionGranted;
  }
}
