import 'dart:convert';

/// Persistent model for a continuous listening session across multiple audio devices.
///
/// If a user switches from Device A to Device B while audio continues (or within
/// the experimental grace period), the continuous session remains uninterrupted.
class ContinuousListeningSession {
  final String id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int activeListeningDurationSeconds;
  final int pausedDurationSeconds;
  final List<String> deviceIds;
  final List<String> deviceNames;
  final String status; // 'active' or 'completed'

  const ContinuousListeningSession({
    required this.id,
    required this.startedAt,
    this.endedAt,
    required this.activeListeningDurationSeconds,
    required this.pausedDurationSeconds,
    required this.deviceIds,
    required this.deviceNames,
    this.status = 'active',
  });

  Duration get activeListeningDuration =>
      Duration(seconds: activeListeningDurationSeconds);
  Duration get pausedDuration => Duration(seconds: pausedDurationSeconds);

  static String formatSeconds(int totalSeconds) {
    final d = Duration(seconds: totalSeconds);
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  String get activeListeningDurationFormatted =>
      formatSeconds(activeListeningDurationSeconds);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'started_at': startedAt.millisecondsSinceEpoch,
      'ended_at': endedAt?.millisecondsSinceEpoch,
      'active_duration_seconds': activeListeningDurationSeconds,
      'paused_duration_seconds': pausedDurationSeconds,
      'device_ids_json': jsonEncode(deviceIds),
      'device_names_json': jsonEncode(deviceNames),
      'status': status,
    };
  }

  factory ContinuousListeningSession.fromMap(Map<String, dynamic> map) {
    List<String> parseList(dynamic val) {
      if (val == null) return [];
      try {
        final decoded = jsonDecode(val.toString());
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
      return [];
    }

    return ContinuousListeningSession(
      id: map['id'] as String,
      startedAt: DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int),
      endedAt: map['ended_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['ended_at'] as int)
          : null,
      activeListeningDurationSeconds: map['active_duration_seconds'] as int,
      pausedDurationSeconds: map['paused_duration_seconds'] as int,
      deviceIds: parseList(map['device_ids_json']),
      deviceNames: parseList(map['device_names_json']),
      status: map['status'] as String? ?? 'completed',
    );
  }

  ContinuousListeningSession copyWith({
    DateTime? endedAt,
    int? activeListeningDurationSeconds,
    int? pausedDurationSeconds,
    List<String>? deviceIds,
    List<String>? deviceNames,
    String? status,
  }) {
    return ContinuousListeningSession(
      id: id,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      activeListeningDurationSeconds:
          activeListeningDurationSeconds ?? this.activeListeningDurationSeconds,
      pausedDurationSeconds:
          pausedDurationSeconds ?? this.pausedDurationSeconds,
      deviceIds: deviceIds ?? this.deviceIds,
      deviceNames: deviceNames ?? this.deviceNames,
      status: status ?? this.status,
    );
  }
}
