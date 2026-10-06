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
  static const _methodChannel =
      MethodChannel('com.listeningtracker/audio_monitor');
  static const _eventChannel =
      EventChannel('com.listeningtracker/audio_events');

  /// Stream of audio events from the native layer.
  /// Each event is a Map with keys like: type, timestamp, deviceName, etc.
  Stream<Map<String, dynamic>>? _eventStream;

  Stream<Map<String, dynamic>> get audioEvents {
    _eventStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => Map<String, dynamic>.from(event as Map));
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
      final result =
          await _methodChannel.invokeMethod<Map>('getCurrentState');
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
      final result =
          await _methodChannel.invokeMethod<Map>('checkPermissions');
      return Map<String, bool>.from(result ?? {});
    } on PlatformException catch (e) {
      debugPrint('Failed to check permissions: ${e.message}');
      return {};
    }
  }
}

