import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/audio_device.dart';
import '../models/connection_record.dart';
import '../models/continuous_session.dart';
import '../models/daily_stats.dart';
import '../models/device_usage_stats.dart';
import '../models/listening_session.dart';
import '../models/period_stats.dart';
import 'database_adapter.dart';

/// Database helper managing local SQLite persistence for:
/// - Audio Devices registry
/// - Device Listening Sessions
/// - Continuous Listening Sessions
/// - Bluetooth Connection Records (Phase 3 v2)
class DatabaseHelper implements DatabaseAdapter {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('listening_tracker.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: _onUpgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        device_type TEXT NOT NULL,
        connection_type TEXT NOT NULL,
        address TEXT,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE device_sessions (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        device_name TEXT NOT NULL,
        device_type TEXT NOT NULL,
        connected_at INTEGER NOT NULL,
        disconnected_at INTEGER,
        listening_started_at INTEGER,
        listening_ended_at INTEGER,
        connected_duration_seconds INTEGER NOT NULL DEFAULT 0,
        active_listening_duration_seconds INTEGER NOT NULL DEFAULT 0,
        silent_duration_seconds INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'completed',
        FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE continuous_sessions (
        id TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        active_duration_seconds INTEGER NOT NULL DEFAULT 0,
        paused_duration_seconds INTEGER NOT NULL DEFAULT 0,
        device_ids_json TEXT NOT NULL DEFAULT '[]',
        device_names_json TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'completed'
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_device_sessions_connected_at ON device_sessions(connected_at)
    ''');

    await db.execute('''
      CREATE INDEX idx_continuous_sessions_started_at ON continuous_sessions(started_at)
    ''');

    // Phase 3 tables
    await _createConnectionRecordsTable(db);
  }

  Future<void> _onUpgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migrate v1 -> v2: Add connection_records table and indexes without altering existing tables
      await _createConnectionRecordsTable(db);
    }
  }

  Future<void> _createConnectionRecordsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS connection_records (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        device_name TEXT NOT NULL,
        device_type TEXT NOT NULL,
        connected_at INTEGER NOT NULL,
        disconnected_at INTEGER,
        duration_seconds INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'active',
        FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_connection_records_connected_at 
      ON connection_records(connected_at)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_connection_records_device_id 
      ON connection_records(device_id)
    ''');
  }

  // =========================================================================
  // Devices CRUD
  // =========================================================================

  @override
  Future<void> upsertDevice(AudioDevice device) async {
    final db = await database;
    await db.insert(
      'devices',
      device.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<AudioDevice?> getDevice(String id) async {
    final db = await database;
    final maps = await db.query(
      'devices',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return AudioDevice.fromMap(maps.first);
    }
    return null;
  }

  @override
  Future<List<AudioDevice>> getAllDevices() async {
    final db = await database;
    final maps = await db.query('devices', orderBy: 'last_seen DESC');
    return maps.map((m) => AudioDevice.fromMap(m)).toList();
  }

  // =========================================================================
  // Device Sessions CRUD
  // =========================================================================

  @override
  Future<void> saveDeviceSession(ListeningSession session) async {
    final db = await database;
    await db.insert(
      'device_sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<ListeningSession>> getRecentDeviceSessions({int limit = 50}) async {
    final db = await database;
    final maps = await db.query(
      'device_sessions',
      orderBy: 'connected_at DESC',
      limit: limit,
    );
    return maps.map((m) => ListeningSession.fromMap(m)).toList();
  }

  @override
  Future<List<ListeningSession>> getDeviceSessionsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;

    final db = await database;
    final maps = await db.query(
      'device_sessions',
      where: 'connected_at >= ? AND connected_at <= ?',
      whereArgs: [startOfDay, endOfDay],
      orderBy: 'connected_at DESC',
    );
    return maps.map((m) => ListeningSession.fromMap(m)).toList();
  }

  // =========================================================================
  // Continuous Sessions CRUD
  // =========================================================================

  @override
  Future<void> saveContinuousSession(ContinuousListeningSession session) async {
    final db = await database;
    await db.insert(
      'continuous_sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<ContinuousListeningSession>> getRecentContinuousSessions({int limit = 50}) async {
    final db = await database;
    final maps = await db.query(
      'continuous_sessions',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return maps.map((m) => ContinuousListeningSession.fromMap(m)).toList();
  }

  @override
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;

    final db = await database;
    final maps = await db.query(
      'continuous_sessions',
      where: 'started_at >= ? AND started_at <= ?',
      whereArgs: [startOfDay, endOfDay],
      orderBy: 'started_at DESC',
    );
    return maps.map((m) => ContinuousListeningSession.fromMap(m)).toList();
  }

  // =========================================================================
  // Connection Records CRUD (Phase 3)
  // =========================================================================

  @override
  Future<void> saveConnectionRecord(ConnectionRecord record) async {
    final db = await database;
    await db.insert(
      'connection_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<ConnectionRecord?> getConnectionRecord(String id) async {
    final db = await database;
    final maps = await db.query(
      'connection_records',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return ConnectionRecord.fromMap(maps.first);
    }
    return null;
  }

  @override
  Future<ConnectionRecord?> getActiveConnectionRecord({String? deviceId}) async {
    final db = await database;
    final where = deviceId != null ? "status = 'active' AND device_id = ?" : "status = 'active'";
    final whereArgs = deviceId != null ? [deviceId] : null;
    final maps = await db.query(
      'connection_records',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'connected_at DESC',
      limit: 1,
    );
    if (maps.isNotEmpty) {
      return ConnectionRecord.fromMap(maps.first);
    }
    return null;
  }

  @override
  Future<List<ConnectionRecord>> getRecentConnectionRecords({int limit = 50}) async {
    final db = await database;
    final maps = await db.query(
      'connection_records',
      orderBy: 'connected_at DESC',
      limit: limit,
    );
    return maps.map((m) => ConnectionRecord.fromMap(m)).toList();
  }

  @override
  Future<List<ConnectionRecord>> getConnectionRecordsForDay(DateTime day) async {
    final startOfDay = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final endOfDay = DateTime(day.year, day.month, day.day, 23, 59, 59, 999).millisecondsSinceEpoch;

    final db = await database;
    final maps = await db.query(
      'connection_records',
      where: 'connected_at >= ? AND connected_at <= ?',
      whereArgs: [startOfDay, endOfDay],
      orderBy: 'connected_at DESC',
    );
    return maps.map((m) => ConnectionRecord.fromMap(m)).toList();
  }

  // =========================================================================
  // Daily Aggregation
  // =========================================================================

  @override
  Future<DailyStats> getDailyStats(DateTime day) async {
    final deviceSessions = await getDeviceSessionsForDay(day);
    final continuousSessions = await getContinuousSessionsForDay(day);

    if (deviceSessions.isEmpty && continuousSessions.isEmpty) {
      return DailyStats.empty(day);
    }

    int totalConnected = 0;
    int totalListening = 0;
    int totalSilent = 0;
    final uniqueDeviceIds = <String>{};

    for (final s in deviceSessions) {
      totalConnected += s.connectedDurationSeconds;
      totalListening += s.activeListeningDurationSeconds;
      totalSilent += s.silentDurationSeconds;
      uniqueDeviceIds.add(s.deviceId);
    }

    int longestContinuous = 0;
    for (final cs in continuousSessions) {
      if (cs.activeListeningDurationSeconds > longestContinuous) {
        longestContinuous = cs.activeListeningDurationSeconds;
      }
    }

    return DailyStats(
      date: day,
      totalConnectedSeconds: totalConnected,
      totalActiveListeningSeconds: totalListening,
      totalSilentSeconds: totalSilent,
      deviceSessionCount: deviceSessions.length,
      continuousSessionCount: continuousSessions.length,
      devicesUsedCount: uniqueDeviceIds.length,
      longestContinuousSessionSeconds: longestContinuous,
    );
  }

  // =========================================================================
  // Analytics & Date-Range Queries (Phase 4)
  // =========================================================================

  @override
  Future<List<ListeningSession>> getDeviceSessionsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final maps = await db.query(
      'device_sessions',
      where: 'connected_at >= ? AND connected_at <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'connected_at DESC',
    );
    return maps.map((m) => ListeningSession.fromMap(m)).toList();
  }

  @override
  Future<List<ContinuousListeningSession>> getContinuousSessionsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final maps = await db.query(
      'continuous_sessions',
      where: 'started_at >= ? AND started_at <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'started_at DESC',
    );
    return maps.map((m) => ContinuousListeningSession.fromMap(m)).toList();
  }

  @override
  Future<List<ConnectionRecord>> getConnectionRecordsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final maps = await db.query(
      'connection_records',
      where: 'connected_at >= ? AND connected_at <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'connected_at DESC',
    );
    return maps.map((m) => ConnectionRecord.fromMap(m)).toList();
  }

  @override
  Future<PeriodStats> getPeriodStats(DateTime start, DateTime end) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final db = await database;

    // 1. Aggregate device sessions (listening & silence metrics)
    final sessionRows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) as session_count,
        COALESCE(SUM(active_listening_duration_seconds), 0) as total_listening,
        COALESCE(SUM(silent_duration_seconds), 0) as total_silent,
        COALESCE(MAX(active_listening_duration_seconds), 0) as longest_session,
        COUNT(DISTINCT device_id) as devices_used
      FROM device_sessions
      WHERE connected_at >= ? AND connected_at <= ?
      ''',
      [startMs, endMs],
    );

    // 2. Aggregate connection records (Bluetooth connection duration)
    final connectionRows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(duration_seconds), 0) as total_connected
      FROM connection_records
      WHERE connected_at >= ? AND connected_at <= ?
      ''',
      [startMs, endMs],
    );

    // 3. Count continuous sessions
    final continuousRows = await db.rawQuery(
      '''
      SELECT COUNT(*) as continuous_count
      FROM continuous_sessions
      WHERE started_at >= ? AND started_at <= ?
      ''',
      [startMs, endMs],
    );

    final sRow = sessionRows.isNotEmpty ? sessionRows.first : <String, dynamic>{};
    final cRow = connectionRows.isNotEmpty ? connectionRows.first : <String, dynamic>{};
    final csRow = continuousRows.isNotEmpty ? continuousRows.first : <String, dynamic>{};

    final sessionCount = (sRow['session_count'] as int?) ?? 0;
    final totalListening = (sRow['total_listening'] as int?) ?? 0;
    final totalSilent = (sRow['total_silent'] as int?) ?? 0;
    final longestSession = (sRow['longest_session'] as int?) ?? 0;
    final devicesUsed = (sRow['devices_used'] as int?) ?? 0;
    final totalConnected = (cRow['total_connected'] as int?) ?? 0;
    final continuousCount = (csRow['continuous_count'] as int?) ?? 0;

    return PeriodStats(
      startDate: start,
      endDate: end,
      totalListeningSeconds: totalListening,
      totalConnectedSeconds: totalConnected,
      totalSilentSeconds: totalSilent,
      sessionCount: sessionCount,
      continuousSessionCount: continuousCount,
      devicesUsedCount: devicesUsed,
      longestSessionSeconds: longestSession,
    );
  }

  @override
  Future<List<DeviceUsageStats>> getDeviceUsageStats(
    DateTime start,
    DateTime end,
  ) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final db = await database;

    final sessionRows = await db.rawQuery(
      '''
      SELECT
        device_id,
        MAX(device_name) as device_name,
        COUNT(*) as session_count,
        COALESCE(SUM(active_listening_duration_seconds), 0) as total_listening,
        COALESCE(MAX(active_listening_duration_seconds), 0) as longest_session
      FROM device_sessions
      WHERE connected_at >= ? AND connected_at <= ?
      GROUP BY device_id
      ''',
      [startMs, endMs],
    );

    final connectionRows = await db.rawQuery(
      '''
      SELECT
        device_id,
        MAX(device_name) as device_name,
        COALESCE(SUM(duration_seconds), 0) as total_connected
      FROM connection_records
      WHERE connected_at >= ? AND connected_at <= ?
      GROUP BY device_id
      ''',
      [startMs, endMs],
    );

    final map = <String, _DeviceUsageAccumulator>{};

    for (final row in sessionRows) {
      final deviceId = row['device_id'] as String;
      final deviceName = (row['device_name'] as String?) ?? 'Unknown';
      final entry = map.putIfAbsent(
        deviceId,
        () => _DeviceUsageAccumulator(deviceId: deviceId, deviceName: deviceName),
      );
      entry.totalListeningSeconds = (row['total_listening'] as int?) ?? 0;
      entry.sessionCount = (row['session_count'] as int?) ?? 0;
      entry.longestSessionSeconds = (row['longest_session'] as int?) ?? 0;
    }

    for (final row in connectionRows) {
      final deviceId = row['device_id'] as String;
      final deviceName = (row['device_name'] as String?) ?? 'Unknown';
      final entry = map.putIfAbsent(
        deviceId,
        () => _DeviceUsageAccumulator(deviceId: deviceId, deviceName: deviceName),
      );
      entry.totalConnectedSeconds = (row['total_connected'] as int?) ?? 0;
      if (entry.deviceName.isEmpty || entry.deviceName == 'Unknown') {
        entry.deviceName = deviceName;
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
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT connected_at FROM device_sessions
      UNION
      SELECT connected_at FROM connection_records
      ''',
    );

    final dates = <DateTime>{};
    for (final row in rows) {
      final ms = row['connected_at'] as int?;
      if (ms != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ms);
        dates.add(DateTime(dt.year, dt.month, dt.day));
      }
    }
    final list = dates.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }
}

class _DeviceUsageAccumulator {
  final String deviceId;
  String deviceName;
  int totalListeningSeconds = 0;
  int totalConnectedSeconds = 0;
  int sessionCount = 0;
  int longestSessionSeconds = 0;

  _DeviceUsageAccumulator({
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
