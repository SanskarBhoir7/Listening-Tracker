import 'dart:convert';

/// Represents a persistent diagnostic event stored in SQLite for debugging and telemetry.
///
/// Captures:
/// - Exact millisecond timestamp & ISO-8601 representation
/// - Event type and origin source (`native`, `flutter`, `session_engine`, `system`)
/// - Device identification
/// - State machine states (`connectionState`, `audioState`, `sessionState`)
/// - Fine-grained native PlaybackStateResolver signals
/// - Stop confirmation lifecycle (`scheduled`, `cancelled`, `confirmed`)
/// - Duration, error details, and custom metadata
class DiagnosticEvent {
  final String id;
  final int timestamp;
  final String timestampIso;
  final String eventType;
  final String source;
  final String? deviceId;
  final String? deviceName;
  final String? deviceType;
  final String? connectionType;
  final String? connectionState;
  final String? audioState;
  final String? sessionState;
  final String? reason;
  final String? details;
  final int? playbackConfigsCount;
  final int? activeMediaCount;
  final String? playbackStates;
  final bool? isMusicActive;
  final bool? isA2dpStreaming;
  final bool? prevPlaying;
  final bool? resolvedPlaying;
  final String? resolverReason;
  final String? stopConfirmationStatus;
  final int? durationSeconds;
  final String? errorDetails;
  final Map<String, dynamic>? metadata;

  const DiagnosticEvent({
    required this.id,
    required this.timestamp,
    required this.timestampIso,
    required this.eventType,
    required this.source,
    this.deviceId,
    this.deviceName,
    this.deviceType,
    this.connectionType,
    this.connectionState,
    this.audioState,
    this.sessionState,
    this.reason,
    this.details,
    this.playbackConfigsCount,
    this.activeMediaCount,
    this.playbackStates,
    this.isMusicActive,
    this.isA2dpStreaming,
    this.prevPlaying,
    this.resolvedPlaying,
    this.resolverReason,
    this.stopConfirmationStatus,
    this.durationSeconds,
    this.errorDetails,
    this.metadata,
  });

  /// Creates a [DiagnosticEvent] from SQLite map.
  factory DiagnosticEvent.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? parsedMetadata;
    final metaStr = map['metadata_json'] as String?;
    if (metaStr != null && metaStr.isNotEmpty) {
      try {
        parsedMetadata = Map<String, dynamic>.from(jsonDecode(metaStr) as Map);
      } catch (_) {}
    }

    return DiagnosticEvent(
      id: map['id'] as String,
      timestamp: map['timestamp'] as int,
      timestampIso: map['timestamp_iso'] as String? ??
          DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int).toIso8601String(),
      eventType: map['event_type'] as String,
      source: map['source'] as String? ?? 'unknown',
      deviceId: map['device_id'] as String?,
      deviceName: map['device_name'] as String?,
      deviceType: map['device_type'] as String?,
      connectionType: map['connection_type'] as String?,
      connectionState: map['connection_state'] as String?,
      audioState: map['audio_state'] as String?,
      sessionState: map['session_state'] as String?,
      reason: map['reason'] as String?,
      details: map['details'] as String?,
      playbackConfigsCount: map['playback_configs_count'] as int?,
      activeMediaCount: map['active_media_count'] as int?,
      playbackStates: map['playback_states'] as String?,
      isMusicActive: map['is_music_active'] != null ? (map['is_music_active'] as int) == 1 : null,
      isA2dpStreaming: map['is_a2dp_streaming'] != null ? (map['is_a2dp_streaming'] as int) == 1 : null,
      prevPlaying: map['prev_playing'] != null ? (map['prev_playing'] as int) == 1 : null,
      resolvedPlaying: map['resolved_playing'] != null ? (map['resolved_playing'] as int) == 1 : null,
      resolverReason: map['resolver_reason'] as String?,
      stopConfirmationStatus: map['stop_confirmation_status'] as String?,
      durationSeconds: map['duration_seconds'] as int?,
      errorDetails: map['error_details'] as String?,
      metadata: parsedMetadata,
    );
  }

  /// Converts to map for SQLite insertion.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp,
      'timestamp_iso': timestampIso,
      'event_type': eventType,
      'source': source,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': deviceType,
      'connection_type': connectionType,
      'connection_state': connectionState,
      'audio_state': audioState,
      'session_state': sessionState,
      'reason': reason,
      'details': details,
      'playback_configs_count': playbackConfigsCount,
      'active_media_count': activeMediaCount,
      'playback_states': playbackStates,
      'is_music_active': isMusicActive == null ? null : (isMusicActive! ? 1 : 0),
      'is_a2dp_streaming': isA2dpStreaming == null ? null : (isA2dpStreaming! ? 1 : 0),
      'prev_playing': prevPlaying == null ? null : (prevPlaying! ? 1 : 0),
      'resolved_playing': resolvedPlaying == null ? null : (resolvedPlaying! ? 1 : 0),
      'resolver_reason': resolverReason,
      'stop_confirmation_status': stopConfirmationStatus,
      'duration_seconds': durationSeconds,
      'error_details': errorDetails,
      'metadata_json': metadata != null ? jsonEncode(metadata) : null,
    };
  }

  /// Converts to clean JSON format for export.
  Map<String, dynamic> toJsonMap() {
    return {
      'id': id,
      'timestamp': timestamp,
      'timestamp_iso': timestampIso,
      'event_type': eventType,
      'source': source,
      if (deviceId != null) 'device_id': deviceId,
      if (deviceName != null) 'device_name': deviceName,
      if (deviceType != null) 'device_type': deviceType,
      if (connectionType != null) 'connection_type': connectionType,
      if (connectionState != null) 'connection_state': connectionState,
      if (audioState != null) 'audio_state': audioState,
      if (sessionState != null) 'session_state': sessionState,
      if (reason != null) 'reason': reason,
      if (details != null) 'details': details,
      if (playbackConfigsCount != null) 'playback_configs_count': playbackConfigsCount,
      if (activeMediaCount != null) 'active_media_count': activeMediaCount,
      if (playbackStates != null) 'playback_states': playbackStates,
      if (isMusicActive != null) 'is_music_active': isMusicActive,
      if (isA2dpStreaming != null) 'is_a2dp_streaming': isA2dpStreaming,
      if (prevPlaying != null) 'prev_playing': prevPlaying,
      if (resolvedPlaying != null) 'resolved_playing': resolvedPlaying,
      if (resolverReason != null) 'resolver_reason': resolverReason,
      if (stopConfirmationStatus != null) 'stop_confirmation_status': stopConfirmationStatus,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (errorDetails != null) 'error_details': errorDetails,
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Summary of playback resolver signals.
  String? get signalSummary {
    if (playbackConfigsCount == null && isMusicActive == null && isA2dpStreaming == null) {
      return null;
    }
    final parts = <String>[];
    if (playbackConfigsCount != null) parts.add('configs=$playbackConfigsCount');
    if (activeMediaCount != null) parts.add('media=$activeMediaCount');
    if (playbackStates != null && playbackStates!.isNotEmpty && playbackStates != '[]') {
      parts.add('states=$playbackStates');
    }
    if (isMusicActive != null) parts.add('music=$isMusicActive');
    if (isA2dpStreaming != null) parts.add('a2dp=$isA2dpStreaming');
    if (prevPlaying != null) parts.add('prev=$prevPlaying');
    if (resolvedPlaying != null) parts.add('resolved=$resolvedPlaying');
    if (resolverReason != null) parts.add('reason=$resolverReason');
    if (stopConfirmationStatus != null) parts.add('stopStatus=$stopConfirmationStatus');
    return parts.join(', ');
  }

  /// Whether this event contains playback resolver diagnostics
  bool get hasPlaybackDiagnostics =>
      playbackConfigsCount != null ||
      activeMediaCount != null ||
      isMusicActive != null ||
      isA2dpStreaming != null ||
      prevPlaying != null ||
      resolvedPlaying != null ||
      resolverReason != null;

  /// Compact string representing playback resolver signals
  String get playbackSignalsSummary => signalSummary ?? '';

  /// Formatted HH:mm:ss representation of timestamp
  String get timeClock {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// One-line description for log list item.
  String get displayLine {
    final dev = deviceName != null && deviceName!.isNotEmpty ? ' | $deviceName' : '';
    final rsn = reason != null && reason!.isNotEmpty ? ' ($reason)' : '';
    final sig = signalSummary != null ? ' [$signalSummary]' : '';
    final err = errorDetails != null && errorDetails!.isNotEmpty ? ' ERROR: $errorDetails' : '';
    return '$eventType$dev$rsn$sig$err';
  }

  @override
  String toString() => '[$timestampIso][$source] $displayLine';
}
