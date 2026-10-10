import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/database_adapter.dart';
import '../models/diagnostic_event.dart';
import '../models/tracking_event.dart';

/// Central diagnostic logging coordinator for Listening Tracker.
///
/// Ensures all system, native, session, and monitoring events are:
/// 1. Persisted reliably to SQLite in a dedicated table.
/// 2. Tagged with exact timestamps and full PlaybackResolver signal snapshots.
/// 3. Broadcast to the live UI for instant debugging.
/// 4. Protected against recursive logging loops and database write crashes.
class DiagnosticLogger {
  static final DiagnosticLogger instance = DiagnosticLogger._internal();

  DatabaseAdapter? _database;
  bool _isLogging = false;
  int _eventCounter = 0;

  final StreamController<DiagnosticEvent> _streamController =
      StreamController<DiagnosticEvent>.broadcast();

  DiagnosticLogger._internal();

  /// Default constructor for testing or dependency injection
  DiagnosticLogger([DatabaseAdapter? database]) : _database = database;

  /// Creates a testable instance with a specific [DatabaseAdapter].
  DiagnosticLogger.withDatabase(DatabaseAdapter database)
    : _database = database;

  /// Stream of real-time diagnostic events for UI observers.
  Stream<DiagnosticEvent> get onDiagnosticEvent => _streamController.stream;
  Stream<DiagnosticEvent> get eventStream => _streamController.stream;

  /// Initializes or updates the active database adapter.
  void setDatabase(DatabaseAdapter database) {
    _database = database;
  }

  /// Alias for [log]
  Future<DiagnosticEvent?> logEvent({
    required String eventType,
    required String source,
    String? eventId,
    DateTime? timestamp,
    int? timestampMs,
    String? deviceId,
    String? deviceName,
    String? deviceType,
    String? connectionType,
    String? connectionState,
    String? audioState,
    String? sessionState,
    String? reason,
    String? details,
    int? playbackConfigsCount,
    int? activeMediaCount,
    String? playbackStates,
    bool? isMusicActive,
    bool? isA2dpStreaming,
    bool? prevPlaying,
    bool? resolvedPlaying,
    String? resolverReason,
    String? stopConfirmationStatus,
    int? durationSeconds,
    String? errorDetails,
    Map<String, dynamic>? rawPayload,
    Map<String, dynamic>? metadata,
  }) {
    return log(
      eventId: eventId,
      eventType: eventType,
      source: source,
      timestampMs: timestampMs ?? timestamp?.millisecondsSinceEpoch,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      connectionType: connectionType,
      connectionState: connectionState,
      audioState: audioState,
      sessionState: sessionState,
      reason: reason,
      details: details,
      playbackConfigsCount: playbackConfigsCount,
      activeMediaCount: activeMediaCount,
      playbackStates: playbackStates,
      isMusicActive: isMusicActive,
      isA2dpStreaming: isA2dpStreaming,
      prevPlaying: prevPlaying,
      resolvedPlaying: resolvedPlaying,
      resolverReason: resolverReason,
      stopConfirmationStatus: stopConfirmationStatus,
      durationSeconds: durationSeconds,
      errorDetails: errorDetails,
      metadata: rawPayload ?? metadata,
    );
  }

  /// Logs a raw event received from the native Android AudioMonitorEngine / Service.
  Future<DiagnosticEvent?> logNativeAudioEvent(
    Map<String, dynamic> event,
  ) async {
    final type = event['type'] as String? ?? 'UNKNOWN_NATIVE_EVENT';
    final timestampMs =
        event['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;
    final deviceId = event['deviceId']?.toString();
    final deviceName = event['deviceName'] as String?;
    final deviceType = event['deviceType'] as String?;
    final connectionType = event['connectionType'] as String?;
    final diagnostics = event['diagnostics'] as String?;
    final stopConfirmationStatus = event['stopConfirmationStatus'] as String?;

    // Parse structured signals (either from direct map keys or fallback diagnostics string)
    final signals = _parseSignals(event, diagnostics);

    return log(
      eventType: type,
      source: 'native',
      timestampMs: timestampMs,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      connectionType: connectionType,
      details: diagnostics,
      playbackConfigsCount: signals.configs,
      activeMediaCount: signals.activeMedia,
      playbackStates: signals.states,
      isMusicActive: signals.isMusicActive,
      isA2dpStreaming: signals.isA2dp,
      prevPlaying: signals.prev,
      resolvedPlaying: signals.resolved ?? (event['isAudioPlaying'] as bool?),
      resolverReason: signals.reason,
      stopConfirmationStatus: stopConfirmationStatus ?? signals.stopStatus,
      metadata: event,
    );
  }

  /// Logs a state transition emitted by Flutter's SessionEngine.
  Future<DiagnosticEvent?> logTrackingEvent(TrackingEvent trackingEvent) async {
    return log(
      eventType: trackingEvent.eventType,
      source: 'session_engine',
      timestampMs: trackingEvent.timestamp.millisecondsSinceEpoch,
      deviceId: trackingEvent.deviceId,
      deviceName: trackingEvent.deviceName,
      deviceType: trackingEvent.deviceType,
      connectionState: trackingEvent.connectionState?.name,
      audioState: trackingEvent.audioState?.name,
      sessionState: trackingEvent.sessionState?.name,
      reason: trackingEvent.reason,
      durationSeconds: trackingEvent.durationSeconds,
      metadata: trackingEvent.metadata,
    );
  }

  /// Logs a general system or app lifecycle event.
  Future<DiagnosticEvent?> logLifecycle(
    String eventType, {
    String? details,
    String? reason,
    String source = 'app',
    Map<String, dynamic>? metadata,
  }) async {
    return log(
      eventType: eventType,
      source: source,
      details: details,
      reason: reason,
      metadata: metadata,
    );
  }

  /// Logs an error or exception safely without crashing monitoring.
  Future<DiagnosticEvent?> logError(
    String eventType,
    Object error, [
    StackTrace? stackTrace,
    String source = 'system',
    Map<String, dynamic>? metadata,
  ]) async {
    final errStr = error.toString();
    final stackStr = stackTrace != null
        ? '\n${stackTrace.toString().split('\n').take(3).join('\n')}'
        : '';

    return log(
      eventType: eventType,
      source: source,
      errorDetails: '$errStr$stackStr',
      metadata: metadata,
    );
  }

  /// Core logging method that creates, persists, and broadcasts a [DiagnosticEvent].
  Future<DiagnosticEvent?> log({
    required String eventType,
    required String source,
    String? eventId,
    int? timestampMs,
    String? deviceId,
    String? deviceName,
    String? deviceType,
    String? connectionType,
    String? connectionState,
    String? audioState,
    String? sessionState,
    String? reason,
    String? details,
    int? playbackConfigsCount,
    int? activeMediaCount,
    String? playbackStates,
    bool? isMusicActive,
    bool? isA2dpStreaming,
    bool? prevPlaying,
    bool? resolvedPlaying,
    String? resolverReason,
    String? stopConfirmationStatus,
    int? durationSeconds,
    String? errorDetails,
    Map<String, dynamic>? metadata,
  }) async {
    // Re-entrancy guard to avoid recursive logging loops if database operations fail.
    if (_isLogging) {
      debugPrint(
        'DiagnosticLogger: Recursive logging prevented for $eventType',
      );
      return null;
    }

    _isLogging = true;
    try {
      final nowMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
      final dt = DateTime.fromMillisecondsSinceEpoch(nowMs);
      final paddedCounter = (++_eventCounter).toString().padLeft(6, '0');
      final id = eventId ?? 'diag_${nowMs}_$paddedCounter';

      final event = DiagnosticEvent(
        id: id,
        timestamp: nowMs,
        timestampIso: dt.toIso8601String(),
        eventType: eventType,
        source: source,
        deviceId: deviceId,
        deviceName: deviceName,
        deviceType: deviceType,
        connectionType: connectionType,
        connectionState: connectionState,
        audioState: audioState,
        sessionState: sessionState,
        reason: reason,
        details: details,
        playbackConfigsCount: playbackConfigsCount,
        activeMediaCount: activeMediaCount,
        playbackStates: playbackStates,
        isMusicActive: isMusicActive,
        isA2dpStreaming: isA2dpStreaming,
        prevPlaying: prevPlaying,
        resolvedPlaying: resolvedPlaying,
        resolverReason: resolverReason,
        stopConfirmationStatus: stopConfirmationStatus,
        durationSeconds: durationSeconds,
        errorDetails: errorDetails,
        metadata: metadata,
      );

      // 1. Broadcast to UI observers
      if (!_streamController.isClosed) {
        _streamController.add(event);
      }

      // 2. Persist to SQLite
      if (_database != null) {
        await _database!.saveDiagnosticEvent(event);
      }

      return event;
    } catch (e) {
      debugPrint('DiagnosticLogger: Failed to persist event $eventType: $e');
      return null;
    } finally {
      _isLogging = false;
    }
  }

  /// Exports diagnostic events matching optional filters as structured JSON string.
  Future<String> exportEventsAsJson({
    String? eventType,
    int? startTimeMs,
    int? endTimeMs,
    int limit = 10000,
  }) async {
    if (_database == null) {
      return jsonEncode({
        'exported_at': DateTime.now().toIso8601String(),
        'error': 'Database not connected',
        'events': [],
      });
    }

    final events = await _database!.getDiagnosticEvents(
      eventType: eventType,
      startTimeMs: startTimeMs,
      endTimeMs: endTimeMs,
      limit: limit,
    );

    final exportMap = {
      'exported_at': DateTime.now().toIso8601String(),
      'app': 'Listening Tracker',
      'event_count': events.length,
      'events': events.map((e) => e.toJsonMap()).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(exportMap);
  }

  /// Parses signals from structured map keys or legacy diagnostics string.
  _ParsedSignals _parseSignals(Map<String, dynamic> raw, String? diagStr) {
    int? configs = raw['playbackConfigsCount'] as int?;
    int? activeMedia = raw['activeMediaCount'] as int?;
    String? states = raw['playbackStates'] as String?;
    bool? isMusic = raw['isMusicActive'] as bool?;
    bool? isA2dp = raw['isA2dpStreaming'] as bool?;
    bool? prev = raw['prevPlaying'] as bool?;
    bool? resolved = raw['resolvedPlaying'] as bool?;
    String? reason = raw['resolverReason'] as String?;
    String? stopStatus = raw['stopConfirmationStatus'] as String?;

    if (diagStr != null && diagStr.isNotEmpty) {
      if (configs == null) {
        final m = RegExp(r'configs=(\d+)').firstMatch(diagStr);
        if (m != null) configs = int.tryParse(m.group(1)!);
      }
      if (activeMedia == null) {
        final m = RegExp(r'activeMedia=(\d+)').firstMatch(diagStr);
        if (m != null) activeMedia = int.tryParse(m.group(1)!);
      }
      if (states == null) {
        final m = RegExp(r'states=\[([^\]]*)\]').firstMatch(diagStr);
        if (m != null) states = m.group(1);
      }
      if (isMusic == null) {
        final m = RegExp(r'isMusicActive=(true|false)').firstMatch(diagStr);
        if (m != null) isMusic = m.group(1) == 'true';
      }
      if (isA2dp == null) {
        final m = RegExp(r'isA2dp=(true|false)').firstMatch(diagStr);
        if (m != null) isA2dp = m.group(1) == 'true';
      }
      if (prev == null) {
        final m = RegExp(r'prev=(true|false)').firstMatch(diagStr);
        if (m != null) prev = m.group(1) == 'true';
      }
      if (resolved == null) {
        final m = RegExp(r'resolved=(true|false)').firstMatch(diagStr);
        if (m != null) resolved = m.group(1) == 'true';
      }
      if (reason == null) {
        final m = RegExp(r'reason=([a-zA-Z0-9_]+)').firstMatch(diagStr);
        if (m != null) reason = m.group(1);
      }
      if (stopStatus == null) {
        if (diagStr.contains('pending_stop=true') ||
            diagStr.contains('scheduling 2s')) {
          stopStatus = 'scheduled';
        } else if (diagStr.contains('confirmed_after')) {
          stopStatus = 'confirmed';
        }
      }
    }

    return _ParsedSignals(
      configs: configs,
      activeMedia: activeMedia,
      states: states,
      isMusicActive: isMusic,
      isA2dp: isA2dp,
      prev: prev,
      resolved: resolved,
      reason: reason,
      stopStatus: stopStatus,
    );
  }
}

class _ParsedSignals {
  final int? configs;
  final int? activeMedia;
  final String? states;
  final bool? isMusicActive;
  final bool? isA2dp;
  final bool? prev;
  final bool? resolved;
  final String? reason;
  final String? stopStatus;

  const _ParsedSignals({
    this.configs,
    this.activeMedia,
    this.states,
    this.isMusicActive,
    this.isA2dp,
    this.prev,
    this.resolved,
    this.reason,
    this.stopStatus,
  });
}
