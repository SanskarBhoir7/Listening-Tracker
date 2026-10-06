import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/audio_device.dart';
import '../models/connection_record.dart';
import '../models/continuous_session.dart';
import '../models/daily_stats.dart';
import '../models/listening_session.dart';
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
}
