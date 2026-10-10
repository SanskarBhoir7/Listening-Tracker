import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side bridge to the native Android audio monitoring engine.
///
/// Uses:
/// - MethodChannel for one-shot commands (start, stop, getState, permissions)
/// - EventChannel for streaming real-time audio events
///
/// This class is the single point of contact between Flutter and native Android.
class AudioMonitorService {
  static const _methodChannel = MethodChannel(
    'com.listeningtracker/audio_monitor',
  );
  static const _eventChannel = EventChannel(
    'com.listeningtracker/audio_events',
  );

  /// Stream of audio events from the native layer.
  /// Each event is a Map with keys like: type, timestamp, deviceName, etc.
  Stream<Map<String, dynamic>>? _eventStream;

  Stream<Map<String, dynamic>> get audioEvents {
    _eventStream ??= _eventChannel.receiveBroadcastStream().map(
      (event) => Map<String, dynamic>.from(event as Map),
    );
    return _eventStream!;
  }

  /// Start native audio monitoring (also starts the foreground service).
  Future<bool> startMonitoring() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('startMonitoring');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to start monitoring: ${e.message}');
      return false;
    }
  }

  /// Returns native breadcrumbs captured before Flutter was ready, including prior processes.
  Future<List<Map<String, dynamic>>> drainNativeLifecycleEvents() async {
    try {
      final result = await _methodChannel.invokeMethod<List>(
        'drainNativeLifecycleEvents',
      );
      return (result ?? const [])
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
    } on PlatformException catch (e) {
      debugPrint('Failed to drain native lifecycle events: ${e.message}');
      return const [];
    }
  }

  Future<void> acknowledgeNativeLifecycleEvents(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      await _methodChannel.invokeMethod<bool>('ackNativeLifecycleEvents', {
        'ids': ids,
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to acknowledge native lifecycle events: ${e.message}');
    }
  }

  /// Stop native audio monitoring and the foreground service.
  Future<bool> stopMonitoring() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('stopMonitoring');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to stop monitoring: ${e.message}');
      return false;
    }
  }

  /// Get the current audio state snapshot.
  Future<Map<String, dynamic>> getCurrentState() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getCurrentState');
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      debugPrint('Failed to get state: ${e.message}');
      return {'error': e.message};
    }
  }

  /// Request runtime permissions (Bluetooth, notifications).
  Future<void> requestPermissions() async {
    try {
      await _methodChannel.invokeMethod('requestPermissions');
    } on PlatformException catch (e) {
      debugPrint('Failed to request permissions: ${e.message}');
    }
  }

  /// Check current permission status.
  Future<Map<String, bool>> checkPermissions() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('checkPermissions');
      return Map<String, bool>.from(result ?? {});
    } on PlatformException catch (e) {
      debugPrint('Failed to check permissions: ${e.message}');
      return {};
    }
  }

  /// Check whether app is ignoring battery optimizations (exempt from doze & FGS background restrictions).
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to check battery optimizations: ${e.message}');
      return false;
    }
  }

  /// Request user to exempt app from battery optimizations.
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _methodChannel.invokeMethod('requestIgnoreBatteryOptimizations');
    } on PlatformException catch (e) {
      debugPrint(
        'Failed to request ignore battery optimizations: ${e.message}',
      );
    }
  }

  /// Check if a companion device association is registered via CompanionDeviceManager.
  Future<bool> isCompanionAssociated() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'isCompanionAssociated',
      );
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to check companion association: ${e.message}');
      return false;
    }
  }

  /// Initiate CompanionDeviceManager association flow for earbuds.
  Future<bool> associateCompanionDevice({String namePattern = '.*'}) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'associateCompanionDevice',
        {'namePattern': namePattern},
      );
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to associate companion device: ${e.message}');
      return false;
    }
  }

  /// Share log content via native Android share sheet using FileProvider.
  Future<bool> shareLogFile(String content, String fileName) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('shareLogFile', {
        'content': content,
        'fileName': fileName,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Failed to share log file: ${e.message}');
      return false;
    }
  }
}
