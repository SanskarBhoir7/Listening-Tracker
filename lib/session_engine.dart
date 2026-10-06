import 'dart:async';
import 'package:flutter/foundation.dart';
import 'database/database_helper.dart';
import 'models/audio_device.dart';
import 'models/continuous_session.dart';
import 'models/daily_stats.dart';
import 'models/listening_session.dart';

/// Central session engine coordinating:
/// 1. Audio device registry and connection tracking
/// 2. Device-specific listening sessions (Connected Time, Active Listening, Silent/Paused)
/// 3. Continuous listening sessions across devices with experimental grace period
/// 4. Local SQLite persistence and daily metrics aggregation
class SessionEngine {
  static const Duration defaultGracePeriod = Duration(minutes: 3);

  final DatabaseHelper _db = DatabaseHelper.instance;

  Duration gracePeriod;

  SessionEngine({this.gracePeriod = defaultGracePeriod});

  // State
  bool _isMonitoring = false;
  bool _isAudioPlaying = false;
  AudioDevice? _activeOutputDevice;
  final Map<String, AudioDevice> _connectedDevices = {};

  // Active sessions in progress
  ListeningSession? _currentDeviceSession;
  ContinuousListeningSession? _currentContinuousSession;

  // Timers
  Timer? _tickerTimer;
  Timer? _gracePeriodTimer;
  DateTime? _gracePeriodStartedAt;

  // Cached history for UI
  List<ListeningSession> _recentDeviceSessions = [];
  DailyStats _todayStats = DailyStats.empty(DateTime.now());

  // Callbacks
  VoidCallback? onStateChanged;
  void Function(String message)? onLog;

  // Getters
  bool get isMonitoring => _isMonitoring;
  bool get isAudioPlaying => _isAudioPlaying;
  AudioDevice? get activeOutputDevice => _activeOutputDevice;
  List<AudioDevice> get connectedDevicesList => _connectedDevices.values.toList();
  ListeningSession? get currentDeviceSession => _currentDeviceSession;
  ContinuousListeningSession? get currentContinuousSession => _currentContinuousSession;
  bool get isInGracePeriod => _gracePeriodTimer != null && _gracePeriodTimer!.isActive;
  Duration? get gracePeriodRemaining {
    if (!isInGracePeriod || _gracePeriodStartedAt == null) return null;
    final elapsed = DateTime.now().difference(_gracePeriodStartedAt!);
    final remaining = gracePeriod - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }
  List<ListeningSession> get recentDeviceSessions => _recentDeviceSessions;
  DailyStats get todayStats => _todayStats;

  /// Live formatted session durations
  String get liveActiveListeningFormatted {
    if (_currentDeviceSession != null) {
      return ListeningSession.formatClock(_currentDeviceSession!.activeListeningDurationSeconds);
    }
    return '00:00:00';
  }

  String get liveConnectedFormatted {
    if (_currentDeviceSession != null) {
      return ListeningSession.formatClock(_currentDeviceSession!.connectedDurationSeconds);
    }
    return '00:00:00';
  }

  String get liveSilentFormatted {
    if (_currentDeviceSession != null) {
      return ListeningSession.formatClock(_currentDeviceSession!.silentDurationSeconds);
    }
    return '00:00:00';
  }

  String get liveContinuousFormatted {
    if (_currentContinuousSession != null) {
      return ListeningSession.formatClock(
          _currentContinuousSession!.activeListeningDurationSeconds);
    }
    return '00:00:00';
  }

  /// Initialize and load stored history
  Future<void> initialize() async {
    await refreshHistory();
  }

  Future<void> refreshHistory() async {
    final now = DateTime.now();
    _recentDeviceSessions = await _db.getDeviceSessionsForDay(now);
    _todayStats = await _db.getDailyStats(now);
    onStateChanged?.call();
  }

  void startMonitoring() {
    _isMonitoring = true;
    _startTicker();
    onStateChanged?.call();
  }

  Future<void> stopMonitoring() async {
    _isMonitoring = false;
    _stopTicker();
    _cancelGracePeriod();

    // Finalize any active sessions and save
    if (_currentDeviceSession != null) {
      await _closeDeviceSession(_currentDeviceSession!);
      _currentDeviceSession = null;
    }
    if (_currentContinuousSession != null) {
      await _closeContinuousSession(_currentContinuousSession!);
      _currentContinuousSession = null;
    }

    _connectedDevices.clear();
    _activeOutputDevice = null;
    _isAudioPlaying = false;

    await refreshHistory();
    onStateChanged?.call();
  }

  /// Process native state snapshot on refresh or startup
  Future<void> processStateSnapshot(Map<String, dynamic> state) async {
    _isAudioPlaying = state['isAudioPlaying'] as bool? ?? false;

    final connectedList = state['connectedDevices'] as List? ?? [];
    final now = DateTime.now();

    final currentIds = <String>{};
    for (final raw in connectedList) {
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        final name = map['name'] as String? ?? 'Headphones';
        final connType = map['connectionType'] as String? ?? 'unknown';
        final address = map['address'] as String?;
        final typeName = map['typeName'] as String? ?? 'Headphones';

        final id = AudioDevice.generateStableId(
          name: name,
          connectionType: connType,
          address: address,
        );
        currentIds.add(id);

        final device = AudioDevice(
          id: id,
          name: name,
          deviceType: typeName,
          connectionType: connType,
          address: address,
          firstSeen: now,
          lastSeen: now,
        );

        _connectedDevices[id] = device;
        await _db.upsertDevice(device);
      }
    }

    // Remove any no longer connected
    _connectedDevices.removeWhere((id, _) => !currentIds.contains(id));

    // Determine active output device
    final outName = state['outputDeviceName'] as String?;
    final outType = state['outputDeviceType'] as String?;
    final outConn = state['outputConnectionType'] as String?;
    final outAddr = state['outputDeviceAddress'] as String?;

    if (outName != null && outConn != null && outConn != 'internal') {
      final stableId = AudioDevice.generateStableId(
        name: outName,
        connectionType: outConn,
        address: outAddr,
      );
      _activeOutputDevice = _connectedDevices[stableId] ??
          AudioDevice(
            id: stableId,
            name: outName,
            deviceType: outType ?? 'Headphones',
            connectionType: outConn,
            address: outAddr,
            firstSeen: now,
            lastSeen: now,
          );
      _syncDeviceSession();
    } else {
      _activeOutputDevice = null;
      if (_currentDeviceSession != null) {
        await _closeDeviceSession(_currentDeviceSession!);
        _currentDeviceSession = null;
      }
    }

    onStateChanged?.call();
  }

  /// Handle incoming event from native Android layer
  Future<void> handleNativeEvent(Map<String, dynamic> event) async {
    final type = event['type'] as String? ?? 'UNKNOWN';
    final deviceName = event['deviceName'] as String?;
    final deviceType = event['deviceType'] as String?;
    final connectionType = event['connectionType'] as String?;
    final deviceAddress = event['deviceAddress'] as String?;
    final isPlaying = event['isAudioPlaying'] as bool?;

    final now = DateTime.now();

    switch (type) {
      case 'DEVICE_CONNECTED':
        if (deviceName != null && connectionType != null) {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );

          final existing = await _db.getDevice(stableId);
          final device = AudioDevice(
            id: stableId,
            name: deviceName,
            deviceType: deviceType ?? 'Audio Device',
            connectionType: connectionType,
            address: deviceAddress,
            firstSeen: existing?.firstSeen ?? now,
            lastSeen: now,
          );

          _connectedDevices[stableId] = device;
          await _db.upsertDevice(device);

          // If this is our primary or first trackable device, make it active output
          if (_activeOutputDevice == null || connectionType == 'bluetooth') {
            _activeOutputDevice = device;
            _syncDeviceSession();
          }
        }
        break;

      case 'DEVICE_DISCONNECTED':
        if (deviceName != null && connectionType != null) {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );

          _connectedDevices.remove(stableId);

          // If the disconnected device had an active session, close and save it!
          if (_currentDeviceSession != null &&
              _currentDeviceSession!.deviceId == stableId) {
            await _closeDeviceSession(_currentDeviceSession!);
            _currentDeviceSession = null;
            onLog?.call('PERSISTED_SESSION | $deviceName');
          }

          // Check if another device is still connected
          if (_connectedDevices.isNotEmpty) {
            _activeOutputDevice = _connectedDevices.values.first;
            _syncDeviceSession();
          } else {
            _activeOutputDevice = null;
          }

          // Disconnect triggers grace period for continuous session
          if (_currentContinuousSession != null) {
            _startGracePeriod();
          }
        }
        break;

      case 'AUDIO_STARTED':
        _isAudioPlaying = true;
        _cancelGracePeriod();

        if (deviceName != null && connectionType != null && connectionType != 'internal') {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );
          _activeOutputDevice = _connectedDevices[stableId] ??
              AudioDevice(
                id: stableId,
                name: deviceName,
                deviceType: deviceType ?? 'Audio Device',
                connectionType: connectionType,
                address: deviceAddress,
                firstSeen: now,
                lastSeen: now,
              );
          _syncDeviceSession();
        }

        // Handle Continuous Listening Session
        if (_currentContinuousSession == null) {
          _currentContinuousSession = ContinuousListeningSession(
            id: 'cs_${now.millisecondsSinceEpoch}',
            startedAt: now,
            activeListeningDurationSeconds: 0,
            pausedDurationSeconds: 0,
            deviceIds: _activeOutputDevice != null ? [_activeOutputDevice!.id] : [],
            deviceNames: _activeOutputDevice != null ? [_activeOutputDevice!.name] : [],
            status: 'active',
          );
        } else {
          // Add device name if not already listed
          if (_activeOutputDevice != null &&
              !_currentContinuousSession!.deviceIds.contains(_activeOutputDevice!.id)) {
            final updatedIds = List<String>.from(_currentContinuousSession!.deviceIds)
              ..add(_activeOutputDevice!.id);
            final updatedNames = List<String>.from(_currentContinuousSession!.deviceNames)
              ..add(_activeOutputDevice!.name);
            _currentContinuousSession = _currentContinuousSession!.copyWith(
              deviceIds: updatedIds,
              deviceNames: updatedNames,
            );
          }
        }
        break;

      case 'AUDIO_STOPPED':
        _isAudioPlaying = false;
        // Start experimental grace period for continuous listening session
        if (_currentContinuousSession != null) {
          _startGracePeriod();
        }
        break;

      case 'AUDIO_OUTPUT_CHANGED':
        if (connectionType == 'internal' || deviceName == 'Phone Speaker') {
          // Switched to built-in speaker
          if (_currentDeviceSession != null) {
            await _closeDeviceSession(_currentDeviceSession!);
            _currentDeviceSession = null;
          }
          _activeOutputDevice = null;
          if (_currentContinuousSession != null) {
            _startGracePeriod();
          }
        } else if (deviceName != null && connectionType != null) {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );

          // If switching from Device A to Device B:
          if (_activeOutputDevice != null && _activeOutputDevice!.id != stableId) {
            // Close Device A's session
            if (_currentDeviceSession != null) {
              await _closeDeviceSession(_currentDeviceSession!);
              _currentDeviceSession = null;
            }
          }

          _activeOutputDevice = _connectedDevices[stableId] ??
              AudioDevice(
                id: stableId,
                name: deviceName,
                deviceType: deviceType ?? 'Audio Device',
                connectionType: connectionType,
                address: deviceAddress,
                firstSeen: now,
                lastSeen: now,
              );

          _syncDeviceSession();

          // Continuous session seamlessly continues with Device B!
          if (_currentContinuousSession != null &&
              !_currentContinuousSession!.deviceIds.contains(stableId)) {
            final updatedIds = List<String>.from(_currentContinuousSession!.deviceIds)
              ..add(stableId);
            final updatedNames = List<String>.from(_currentContinuousSession!.deviceNames)
              ..add(deviceName);
            _currentContinuousSession = _currentContinuousSession!.copyWith(
              deviceIds: updatedIds,
              deviceNames: updatedNames,
            );
          }
        }
        break;
    }

    if (isPlaying != null) {
      _isAudioPlaying = isPlaying;
    }

    await refreshHistory();
    onStateChanged?.call();
  }

  void _syncDeviceSession() {
    if (_activeOutputDevice == null) return;

    final now = DateTime.now();
    if (_currentDeviceSession == null ||
        _currentDeviceSession!.deviceId != _activeOutputDevice!.id) {
      _currentDeviceSession = ListeningSession(
        id: 'ds_${now.millisecondsSinceEpoch}',
        deviceId: _activeOutputDevice!.id,
        deviceName: _activeOutputDevice!.name,
        deviceType: _activeOutputDevice!.deviceType,
        connectedAt: now,
        listeningStartedAt: _isAudioPlaying ? now : null,
        connectedDurationSeconds: 0,
        activeListeningDurationSeconds: 0,
        silentDurationSeconds: 0,
        status: 'active',
      );
    }
  }

  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _onTick();
    });
  }

  void _stopTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = null;
  }

  void _onTick() {
    bool stateChanged = false;

    // Tick active device session
    if (_currentDeviceSession != null && _activeOutputDevice != null) {
      final newConnected = _currentDeviceSession!.connectedDurationSeconds + 1;
      int newActive = _currentDeviceSession!.activeListeningDurationSeconds;
      int newSilent = _currentDeviceSession!.silentDurationSeconds;

      if (_isAudioPlaying) {
        newActive++;
      } else {
        newSilent++;
      }

      _currentDeviceSession = _currentDeviceSession!.copyWith(
        connectedDurationSeconds: newConnected,
        activeListeningDurationSeconds: newActive,
        silentDurationSeconds: newSilent,
      );
      stateChanged = true;
    }

    // Tick continuous session
    if (_currentContinuousSession != null) {
      if (_isAudioPlaying) {
        final newActive =
            _currentContinuousSession!.activeListeningDurationSeconds + 1;
        _currentContinuousSession = _currentContinuousSession!.copyWith(
          activeListeningDurationSeconds: newActive,
        );
        stateChanged = true;
      } else if (isInGracePeriod) {
        final newPaused =
            _currentContinuousSession!.pausedDurationSeconds + 1;
        _currentContinuousSession = _currentContinuousSession!.copyWith(
          pausedDurationSeconds: newPaused,
        );
        stateChanged = true;
      }
    }

    if (stateChanged) {
      onStateChanged?.call();
    }
  }

  void _startGracePeriod() {
    _cancelGracePeriod();
    _gracePeriodStartedAt = DateTime.now();
    _gracePeriodTimer = Timer(gracePeriod, () async {
      _gracePeriodTimer = null;
      _gracePeriodStartedAt = null;

      // Grace period expired without audio resuming: end continuous session!
      if (_currentContinuousSession != null) {
        await _closeContinuousSession(_currentContinuousSession!);
        _currentContinuousSession = null;
        onLog?.call('CONTINUOUS_SESSION_ENDED (Grace period expired)');
        await refreshHistory();
        onStateChanged?.call();
      }
    });
  }

  void _cancelGracePeriod() {
    _gracePeriodTimer?.cancel();
    _gracePeriodTimer = null;
    _gracePeriodStartedAt = null;
  }

  Future<void> _closeDeviceSession(ListeningSession session) async {
    final now = DateTime.now();
    final totalConnected = now.difference(session.connectedAt).inSeconds;
    final active = session.activeListeningDurationSeconds;
    // Mathematical invariant: connected ≈ active + silent
    final silent = (totalConnected > active) ? (totalConnected - active) : 0;

    final completed = session.copyWith(
      disconnectedAt: now,
      listeningEndedAt: session.listeningStartedAt != null ? now : null,
      connectedDurationSeconds: totalConnected,
      activeListeningDurationSeconds: active,
      silentDurationSeconds: silent,
      status: 'completed',
    );

    await _db.saveDeviceSession(completed);
  }

  Future<void> _closeContinuousSession(ContinuousListeningSession session) async {
    final now = DateTime.now();
    final completed = session.copyWith(
      endedAt: now,
      status: 'completed',
    );
    await _db.saveContinuousSession(completed);
  }

  void dispose() {
    _stopTicker();
    _cancelGracePeriod();
  }
}
