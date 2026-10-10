import '../models/audio_device.dart';
import '../models/connection_record.dart';
import '../models/continuous_session.dart';
import '../models/daily_stats.dart';
import '../models/device_usage_stats.dart';
import '../models/diagnostic_event.dart';
import '../models/listening_session.dart';
import '../models/period_stats.dart';

/// Database adapter abstraction for SessionEngine.
///
/// Decouples SessionEngine from direct sqflite dependency,
/// allowing in-memory and mock implementations for deterministic testing.
abstract class DatabaseAdapter {
  Future<void> upsertDevice(AudioDevice device);
  Future<AudioDevice?> getDevice(String id);
  Future<List<AudioDevice>> getAllDevices();

  Future<void> saveDeviceSession(ListeningSession session);
  Future<List<ListeningSession>> getRecentDeviceSessions({int limit = 50});
  Future<List<ListeningSession>> getDeviceSessionsForDay(DateTime day);
  Future<List<ListeningSession>> getDeviceSessionsForDateRange(DateTime start, DateTime end);

  Future<void> saveContinuousSession(ContinuousListeningSession session);
  Future<List<ContinuousListeningSession>> getRecentContinuousSessions({int limit = 50});
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDay(DateTime day);
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDateRange(DateTime start, DateTime end);

  Future<void> saveConnectionRecord(ConnectionRecord record);
  Future<ConnectionRecord?> getConnectionRecord(String id);
  Future<ConnectionRecord?> getActiveConnectionRecord({String? deviceId});
  Future<List<ConnectionRecord>> getRecentConnectionRecords({int limit = 50});
  Future<List<ConnectionRecord>> getConnectionRecordsForDay(DateTime day);
  Future<List<ConnectionRecord>> getConnectionRecordsForDateRange(DateTime start, DateTime end);

  Future<DailyStats> getDailyStats(DateTime day);
  Future<PeriodStats> getPeriodStats(DateTime start, DateTime end);
  Future<List<DeviceUsageStats>> getDeviceUsageStats(DateTime start, DateTime end);
  Future<List<DateTime>> getDatesWithActivity();

  // Phase 5: Persistent Diagnostic Event Logging
  Future<void> saveDiagnosticEvent(DiagnosticEvent event);
  Future<void> saveDiagnosticEvents(List<DiagnosticEvent> events);
  Future<List<DiagnosticEvent>> getDiagnosticEvents({
    int limit = 100,
    int offset = 0,
    String? eventType,
    int? startTimeMs,
    int? endTimeMs,
  });
  Future<int> getDiagnosticEventCount({
    String? eventType,
    int? startTimeMs,
    int? endTimeMs,
  });
  Future<int> pruneDiagnosticEvents({int keepLatest = 10000});
  Future<void> clearDiagnosticEvents();
}

/// In-memory implementation of [DatabaseAdapter] for unit tests.
class InMemoryDatabaseAdapter implements DatabaseAdapter {
  final Map<String, AudioDevice> devices = {};
  final List<ListeningSession> deviceSessions = [];
  final List<ContinuousListeningSession> continuousSessions = [];
  final List<ConnectionRecord> connectionRecords = [];
  final List<DiagnosticEvent> diagnosticEvents = [];

  @override
  Future<void> upsertDevice(AudioDevice device) async {
    devices[device.id] = device;
  }

  @override
  Future<AudioDevice?> getDevice(String id) async {
    return devices[id];
  }

  @override
  Future<List<AudioDevice>> getAllDevices() async {
    final list = devices.values.toList();
    list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  @override
  Future<void> saveDeviceSession(ListeningSession session) async {
    final idx = deviceSessions.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      deviceSessions[idx] = session;
    } else {
      deviceSessions.add(session);
    }
  }

  @override
  Future<List<ListeningSession>> getRecentDeviceSessions({int limit = 50}) async {
    final list = List<ListeningSession>.from(deviceSessions);
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<ListeningSession>> getDeviceSessionsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;
    final list = deviceSessions.where((s) {
      final t = s.connectedAt.millisecondsSinceEpoch;
      return t >= startOfDay && t <= endOfDay;
    }).toList();
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list;
  }

  @override
  Future<void> saveContinuousSession(ContinuousListeningSession session) async {
    final idx = continuousSessions.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      continuousSessions[idx] = session;
    } else {
      continuousSessions.add(session);
    }
  }

  @override
  Future<List<ContinuousListeningSession>> getRecentContinuousSessions({int limit = 50}) async {
    final list = List<ContinuousListeningSession>.from(continuousSessions);
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;
    final list = continuousSessions.where((s) {
      final t = s.startedAt.millisecondsSinceEpoch;
      return t >= startOfDay && t <= endOfDay;
    }).toList();
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  @override
  Future<void> saveConnectionRecord(ConnectionRecord record) async {
    final idx = connectionRecords.indexWhere((r) => r.id == record.id);
    if (idx >= 0) {
      connectionRecords[idx] = record;
    } else {
      connectionRecords.add(record);
    }
  }

  @override
  Future<ConnectionRecord?> getConnectionRecord(String id) async {
    final idx = connectionRecords.indexWhere((r) => r.id == id);
    return idx >= 0 ? connectionRecords[idx] : null;
  }

  @override
  Future<ConnectionRecord?> getActiveConnectionRecord({String? deviceId}) async {
    final list = connectionRecords.where((r) {
      if (r.status != 'active') return false;
      if (deviceId != null && r.deviceId != deviceId) return false;
      return true;
    }).toList();
    if (list.isEmpty) return null;
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list.first;
  }

  @override
  Future<List<ConnectionRecord>> getRecentConnectionRecords({int limit = 50}) async {
    final list = List<ConnectionRecord>.from(connectionRecords);
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<ConnectionRecord>> getConnectionRecordsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;
    final list = connectionRecords.where((r) {
      final t = r.connectedAt.millisecondsSinceEpoch;
      return t >= startOfDay && t <= endOfDay;
    }).toList();
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list;
  }

  @override
  Future<DailyStats> getDailyStats(DateTime day) async {
    final daySessions = await getDeviceSessionsForDay(day);
    final dayContinuous = await getContinuousSessionsForDay(day);

    if (daySessions.isEmpty && dayContinuous.isEmpty) {
      return DailyStats.empty(day);
    }

    int totalConnected = 0;
    int totalListening = 0;
    int totalSilent = 0;
    final uniqueDeviceIds = <String>{};

    for (final s in daySessions) {
      totalConnected += s.connectedDurationSeconds;
      totalListening += s.activeListeningDurationSeconds;
      totalSilent += s.silentDurationSeconds;
      uniqueDeviceIds.add(s.deviceId);
    }

    int longestContinuous = 0;
    for (final cs in dayContinuous) {
      if (cs.activeListeningDurationSeconds > longestContinuous) {
        longestContinuous = cs.activeListeningDurationSeconds;
      }
    }

    return DailyStats(
      date: day,
      totalConnectedSeconds: totalConnected,
      totalActiveListeningSeconds: totalListening,
      totalSilentSeconds: totalSilent,
      deviceSessionCount: daySessions.length,
      continuousSessionCount: dayContinuous.length,
      devicesUsedCount: uniqueDeviceIds.length,
      longestContinuousSessionSeconds: longestContinuous,
    );
  }

  @override
  Future<List<ListeningSession>> getDeviceSessionsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final list = deviceSessions.where((s) {
      final t = s.connectedAt.millisecondsSinceEpoch;
      return t >= startMs && t <= endMs;
    }).toList();
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list;
  }

  @override
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final list = continuousSessions.where((s) {
      final t = s.startedAt.millisecondsSinceEpoch;
      return t >= startMs && t <= endMs;
    }).toList();
    list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  @override
  Future<List<ConnectionRecord>> getConnectionRecordsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final list = connectionRecords.where((r) {
      final t = r.connectedAt.millisecondsSinceEpoch;
      return t >= startMs && t <= endMs;
    }).toList();
    list.sort((a, b) => b.connectedAt.compareTo(a.connectedAt));
    return list;
  }

  @override
  Future<PeriodStats> getPeriodStats(DateTime start, DateTime end) async {
    final sessions = await getDeviceSessionsForDateRange(start, end);
    final continuous = await getContinuousSessionsForDateRange(start, end);
    final connections = await getConnectionRecordsForDateRange(start, end);

    if (sessions.isEmpty && continuous.isEmpty && connections.isEmpty) {
      return PeriodStats.empty(start, end);
    }

    int totalListening = 0;
    int totalSilent = 0;
    int longestSession = 0;
    final uniqueDeviceIds = <String>{};

    for (final s in sessions) {
      totalListening += s.activeListeningDurationSeconds;
      totalSilent += s.silentDurationSeconds;
      if (s.activeListeningDurationSeconds > longestSession) {
        longestSession = s.activeListeningDurationSeconds;
      }
      uniqueDeviceIds.add(s.deviceId);
    }

    int totalConnected = 0;
    for (final r in connections) {
      totalConnected += r.durationSeconds;
    }

    return PeriodStats(
      startDate: start,
      endDate: end,
      totalListeningSeconds: totalListening,
      totalConnectedSeconds: totalConnected,
      totalSilentSeconds: totalSilent,
      sessionCount: sessions.length,
      continuousSessionCount: continuous.length,
      devicesUsedCount: uniqueDeviceIds.length,
      longestSessionSeconds: longestSession,
    );
  }

  @override
  Future<List<DeviceUsageStats>> getDeviceUsageStats(
    DateTime start,
    DateTime end,
  ) async {
    final sessions = await getDeviceSessionsForDateRange(start, end);
    final connections = await getConnectionRecordsForDateRange(start, end);

    final map = <String, _MutableDeviceStats>{};

    for (final s in sessions) {
      final entry = map.putIfAbsent(
        s.deviceId,
        () => _MutableDeviceStats(
          deviceId: s.deviceId,
          deviceName: s.deviceName,
        ),
      );
      entry.totalListeningSeconds += s.activeListeningDurationSeconds;
      entry.sessionCount += 1;
      if (s.activeListeningDurationSeconds > entry.longestSessionSeconds) {
        entry.longestSessionSeconds = s.activeListeningDurationSeconds;
      }
      if (entry.deviceName.isEmpty && s.deviceName.isNotEmpty) {
        entry.deviceName = s.deviceName;
      }
    }

    for (final r in connections) {
      final entry = map.putIfAbsent(
        r.deviceId,
        () => _MutableDeviceStats(
          deviceId: r.deviceId,
          deviceName: r.deviceName,
        ),
      );
      entry.totalConnectedSeconds += r.durationSeconds;
      if (entry.deviceName.isEmpty && r.deviceName.isNotEmpty) {
        entry.deviceName = r.deviceName;
      }
    }

    final result = map.values.map((e) => e.toStats()).toList();
    result.sort((a, b) {
      final cmp = b.totalListeningSeconds.compareTo(a.totalListeningSeconds);
      if (cmp != 0) return cmp;
      return b.totalConnectedSeconds.compareTo(a.totalConnectedSeconds);
    });
    return result;
  }

  @override
  Future<List<DateTime>> getDatesWithActivity() async {
    final dates = <DateTime>{};
    for (final s in deviceSessions) {
      final dt = s.connectedAt;
      dates.add(DateTime(dt.year, dt.month, dt.day));
    }
    for (final r in connectionRecords) {
      final dt = r.connectedAt;
      dates.add(DateTime(dt.year, dt.month, dt.day));
    }
    final list = dates.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  // =========================================================================
  // Diagnostic Events (Phase 5)
  // =========================================================================

  @override
  Future<void> saveDiagnosticEvent(DiagnosticEvent event) async {
    diagnosticEvents.removeWhere((e) => e.id == event.id);
    diagnosticEvents.add(event);
  }

  @override
  Future<void> saveDiagnosticEvents(List<DiagnosticEvent> events) async {
    for (final e in events) {
      await saveDiagnosticEvent(e);
    }
  }

  @override
  Future<List<DiagnosticEvent>> getDiagnosticEvents({
    int limit = 100,
    int offset = 0,
    String? eventType,
    int? startTimeMs,
    int? endTimeMs,
  }) async {
    var filtered = diagnosticEvents.where((e) {
      if (eventType != null && e.eventType != eventType) return false;
      if (startTimeMs != null && e.timestamp < startTimeMs) return false;
      if (endTimeMs != null && e.timestamp > endTimeMs) return false;
      return true;
    }).toList();
    filtered.sort((a, b) {
      final cmp = b.timestamp.compareTo(a.timestamp);
      if (cmp != 0) return cmp;
      return b.id.compareTo(a.id);
    });
    if (offset >= filtered.length) return [];
    return filtered.skip(offset).take(limit).toList();
  }

  @override
  Future<int> getDiagnosticEventCount({
    String? eventType,
    int? startTimeMs,
    int? endTimeMs,
  }) async {
    return diagnosticEvents.where((e) {
      if (eventType != null && e.eventType != eventType) return false;
      if (startTimeMs != null && e.timestamp < startTimeMs) return false;
      if (endTimeMs != null && e.timestamp > endTimeMs) return false;
      return true;
    }).length;
  }

  @override
  Future<int> pruneDiagnosticEvents({int keepLatest = 10000}) async {
    if (diagnosticEvents.length <= keepLatest) return 0;
    diagnosticEvents.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final removed = diagnosticEvents.length - keepLatest;
    diagnosticEvents.removeRange(keepLatest, diagnosticEvents.length);
    return removed;
  }

  @override
  Future<void> clearDiagnosticEvents() async {
    diagnosticEvents.clear();
  }
}

class _MutableDeviceStats {
  final String deviceId;
  String deviceName;
  int totalListeningSeconds = 0;
  int totalConnectedSeconds = 0;
  int sessionCount = 0;
  int longestSessionSeconds = 0;

  _MutableDeviceStats({
    required this.deviceId,
    required this.deviceName,
  });

  DeviceUsageStats toStats() {
    return DeviceUsageStats(
      deviceId: deviceId,
      deviceName: deviceName,
      totalListeningSeconds: totalListeningSeconds,
      totalConnectedSeconds: totalConnectedSeconds,
      sessionCount: sessionCount,
      longestSessionSeconds: longestSessionSeconds,
    );
  }
}
