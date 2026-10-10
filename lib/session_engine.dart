import 'dart:async';

import 'package:flutter/foundation.dart';

import 'database/database_adapter.dart';
import 'database/database_helper.dart';
import 'models/audio_device.dart';
import 'models/connection_record.dart';
import 'models/continuous_session.dart';
import 'models/daily_stats.dart';
import 'models/listening_session.dart';
import 'models/tracking_event.dart';
import 'services/diagnostic_logger.dart';
import 'tracking_state.dart';

/// Central session engine coordinating:
/// 1. Bluetooth & external audio device connection tracking (ConnectionRecord)
/// 2. Audio playback state monitoring (AudioPlaybackState)
/// 3. Device-specific & continuous listening session lifecycles (ListeningSessionState)
/// 4. Grace period handling strictly for audio stopping while connected
/// 5. Database persistence via injectable DatabaseAdapter
class SessionEngine {
  static const Duration defaultGracePeriod = Duration(minutes: 3);

  final DatabaseAdapter _db;
  Duration gracePeriod;

  SessionEngine({
    DatabaseAdapter? database,
    this.gracePeriod = defaultGracePeriod,
  }) : _db = database ?? DatabaseHelper.instance;

  // Explicit Phase 3 State Machine Enums
  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  AudioPlaybackState _audioState = AudioPlaybackState.notPlaying;
  ListeningSessionState _sessionState = ListeningSessionState.idle;

  // Engine control
  bool _isMonitoring = false;

  // Active Device & Connections
  AudioDevice? _activeOutputDevice;
  final Map<String, AudioDevice> _connectedDevices = {};
  ConnectionRecord? _activeConnectionRecord;

  // Active Sessions in progress
  ListeningSession? _currentDeviceSession;
  ContinuousListeningSession? _currentContinuousSession;

  // Timers & Token Protection
  Timer? _tickerTimer;
  DateTime? _lastTickAt;
  Timer? _gracePeriodTimer;
  DateTime? _gracePeriodStartedAt;
  int _graceTimerToken = 0;

  // Cached history for UI
  List<ListeningSession> _recentDeviceSessions = [];
  DailyStats _todayStats = DailyStats.empty(DateTime.now());

  // Callbacks
  VoidCallback? onStateChanged;
  void Function(String message)? onLog;
  void Function(TrackingEvent event)? onTrackingEvent;

  // Getters - State Machine
  BluetoothConnectionState get connectionState => _connectionState;
  AudioPlaybackState get audioState => _audioState;
  ListeningSessionState get sessionState => _sessionState;

  // Getters - Phase 2 API Compatibility
  bool get isMonitoring => _isMonitoring;
  bool get isAudioPlaying => _audioState == AudioPlaybackState.playing;
  AudioDevice? get activeOutputDevice => _activeOutputDevice;
  List<AudioDevice> get connectedDevicesList =>
      _connectedDevices.values.toList();
  ConnectionRecord? get activeConnectionRecord => _activeConnectionRecord;
  ListeningSession? get currentDeviceSession => _currentDeviceSession;
  ContinuousListeningSession? get currentContinuousSession =>
      _currentContinuousSession;

  bool get isInGracePeriod =>
      _sessionState == ListeningSessionState.gracePeriod;

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
      return ListeningSession.formatClock(
        _currentDeviceSession!.activeListeningDurationSeconds,
      );
    }
    return '00:00:00';
  }

  String get liveConnectedFormatted {
    if (_activeConnectionRecord != null) {
      return ConnectionRecord.formatClock(
        _activeConnectionRecord!.durationSeconds,
      );
    } else if (_currentDeviceSession != null) {
      return ListeningSession.formatClock(
        _currentDeviceSession!.connectedDurationSeconds,
      );
    }
    return '00:00:00';
  }

  String get liveSilentFormatted {
    if (_currentDeviceSession != null) {
      return ListeningSession.formatClock(
        _currentDeviceSession!.silentDurationSeconds,
      );
    }
    return '00:00:00';
  }

  String get liveContinuousFormatted {
    if (_currentContinuousSession != null) {
      return ListeningSession.formatClock(
        _currentContinuousSession!.activeListeningDurationSeconds,
      );
    }
    return '00:00:00';
  }

  // =========================================================================
  // Initialization & Engine Lifecycle
  // =========================================================================

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

    final now = DateTime.now();

    // Finalize connection record if active
    final connToClose = _activeConnectionRecord;
    _activeConnectionRecord = null;
    if (connToClose != null) {
      await _closeConnectionRecord(connToClose, now);
    }

    // Finalize listening session if active
    final sessionToClose = _currentDeviceSession;
    _currentDeviceSession = null;
    if (sessionToClose != null) {
      await _closeDeviceSession(sessionToClose, now);
    }

    // Finalize continuous session if active
    final continuousToClose = _currentContinuousSession;
    _currentContinuousSession = null;
    if (continuousToClose != null) {
      await _closeContinuousSession(continuousToClose, now);
    }

    _connectedDevices.clear();
    _activeOutputDevice = null;
    _connectionState = BluetoothConnectionState.disconnected;
    _audioState = AudioPlaybackState.notPlaying;
    _sessionState = ListeningSessionState.idle;

    await refreshHistory();
    onStateChanged?.call();
  }

  // =========================================================================
  // Native State Snapshot Reconciliation
  // =========================================================================

  Future<void> processStateSnapshot(Map<String, dynamic> state) async {
    final isPlaying = state['isAudioPlaying'] as bool? ?? false;
    _audioState = isPlaying
        ? AudioPlaybackState.playing
        : AudioPlaybackState.notPlaying;

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

    // Remove devices no longer reported
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

      final device =
          _connectedDevices[stableId] ??
          AudioDevice(
            id: stableId,
            name: outName,
            deviceType: outType ?? 'Headphones',
            connectionType: outConn,
            address: outAddr,
            firstSeen: now,
            lastSeen: now,
          );

      _activeOutputDevice = device;
      _connectionState = BluetoothConnectionState.connected;

      // Ensure connection record exists
      if (_activeConnectionRecord == null ||
          _activeConnectionRecord!.deviceId != stableId) {
        final prevConn = _activeConnectionRecord;
        _activeConnectionRecord = null;
        if (prevConn != null) {
          await _closeConnectionRecord(prevConn, now);
        }
        await _startConnectionRecord(device, now);
      }

      // Reconcile listening session:
      // Start listening ONLY if audio is actually playing
      if (isPlaying) {
        if (_sessionState != ListeningSessionState.active ||
            _currentDeviceSession == null ||
            _currentDeviceSession!.deviceId != stableId) {
          final prevSession = _currentDeviceSession;
          _currentDeviceSession = null;
          if (prevSession != null) {
            await _closeDeviceSession(prevSession, now);
          }
          await _startListeningSession(device, now);
        }
      } else {
        // Not playing: if we were not already in a valid grace period for this device, stay idle
        if (_sessionState == ListeningSessionState.active) {
          _sessionState = ListeningSessionState.gracePeriod;
          _startGracePeriod();
        }
      }
    } else {
      // Switched to internal speaker or disconnected
      if (_activeOutputDevice != null) {
        // Only finalize if we actually had an active output before
        final connToClose = _activeConnectionRecord;
        _activeConnectionRecord = null;
        if (connToClose != null) {
          await _closeConnectionRecord(connToClose, now);
        }

        final sessionToClose = _currentDeviceSession;
        _currentDeviceSession = null;
        if (sessionToClose != null) {
          await _closeDeviceSession(sessionToClose, now);
        }

        final continuousToClose = _currentContinuousSession;
        _currentContinuousSession = null;
        if (continuousToClose != null) {
          await _closeContinuousSession(continuousToClose, now);
        }

        _cancelGracePeriod();
      }
      _activeOutputDevice = null;
      _connectionState = _connectedDevices.isNotEmpty
          ? BluetoothConnectionState.connected
          : BluetoothConnectionState.disconnected;
      _sessionState = ListeningSessionState.idle;
    }

    onStateChanged?.call();
  }

  // =========================================================================
  // Native Event Handler (State Machine Transitions)
  // =========================================================================

  Future<void> handleNativeEvent(Map<String, dynamic> event) async {
    final type = event['type'] as String? ?? 'UNKNOWN';
    final deviceName = event['deviceName'] as String?;
    final deviceType = event['deviceType'] as String?;
    final connectionType = event['connectionType'] as String?;
    final deviceAddress = event['deviceAddress'] as String?;

    final now = DateTime.now();

    switch (type) {
      case 'DEVICE_CONNECTED':
        if (deviceName != null &&
            connectionType != null &&
            connectionType != 'internal') {
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

          _connectionState = BluetoothConnectionState.connected;
          _emitTrackingEvent(
            eventType: 'BT_CONNECTED',
            deviceId: stableId,
            deviceName: deviceName,
            deviceType: device.deviceType,
          );

          // Make active output if primary or bluetooth
          if (_activeOutputDevice == null || connectionType == 'bluetooth') {
            final isDeviceSwitch =
                _activeOutputDevice != null &&
                _activeOutputDevice!.id != stableId;
            if (isDeviceSwitch) {
              final prevConn = _activeConnectionRecord;
              _activeConnectionRecord = null;
              if (prevConn != null) {
                await _closeConnectionRecord(prevConn, now);
              }
            }

            _activeOutputDevice = device;

            // Invariant 10: Do NOT create duplicate connection record for duplicate event
            if (_activeConnectionRecord == null ||
                _activeConnectionRecord!.deviceId != stableId) {
              await _startConnectionRecord(device, now);
            }

            // Invariant 1 & 2: Bluetooth connected does NOT start listening unless audio is playing!
            if (_audioState == AudioPlaybackState.playing) {
              if (_currentDeviceSession == null ||
                  _currentDeviceSession!.deviceId != stableId) {
                final prevSession = _currentDeviceSession;
                _currentDeviceSession = null;
                if (prevSession != null) {
                  await _closeDeviceSession(prevSession, now);
                }
                await _startListeningSession(device, now);
              }
            } else {
              // Audio is NOT playing -> remain IDLE!
              _sessionState = ListeningSessionState.idle;
            }
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

          _emitTrackingEvent(
            eventType: 'BT_DISCONNECTED',
            deviceId: stableId,
            deviceName: deviceName,
            deviceType: deviceType,
          );

          // If the disconnected device was our active connection:
          if (_activeOutputDevice != null &&
              _activeOutputDevice!.id == stableId) {
            // Invariant 5 & 8: End ConnectionRecord immediately!
            final connToClose = _activeConnectionRecord;
            _activeConnectionRecord = null;
            if (connToClose != null) {
              await _closeConnectionRecord(connToClose, now);
            }

            // Invariant 5: End listening immediately! DO NOT start/use 3-minute grace timer.
            _cancelGracePeriod();

            final sessionToClose = _currentDeviceSession;
            _currentDeviceSession = null;
            if (sessionToClose != null) {
              await _closeDeviceSession(sessionToClose, now);
            }

            final continuousToClose = _currentContinuousSession;
            _currentContinuousSession = null;
            if (continuousToClose != null) {
              await _closeContinuousSession(continuousToClose, now);
            }

            _sessionState = ListeningSessionState.idle;

            // Check if another trackable device remains connected
            if (_connectedDevices.isNotEmpty) {
              _activeOutputDevice = _connectedDevices.values.first;
              _connectionState = BluetoothConnectionState.connected;
              await _startConnectionRecord(_activeOutputDevice!, now);

              // Reconcile listening with remaining device
              if (_audioState == AudioPlaybackState.playing) {
                await _startListeningSession(_activeOutputDevice!, now);
              }
            } else {
              _activeOutputDevice = null;
              _connectionState = BluetoothConnectionState.disconnected;
            }
          }
        }
        break;

      case 'AUDIO_STARTED':
        _audioState = AudioPlaybackState.playing;
        _emitTrackingEvent(eventType: 'AUDIO_STARTED');

        // Resolve active device if provided in event payload
        if (deviceName != null &&
            connectionType != null &&
            connectionType != 'internal') {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );
          _activeOutputDevice =
              _connectedDevices[stableId] ??
              AudioDevice(
                id: stableId,
                name: deviceName,
                deviceType: deviceType ?? 'Audio Device',
                connectionType: connectionType,
                address: deviceAddress,
                firstSeen: now,
                lastSeen: now,
              );
          _connectionState = BluetoothConnectionState.connected;

          if (_activeConnectionRecord == null ||
              _activeConnectionRecord!.deviceId != stableId) {
            await _startConnectionRecord(_activeOutputDevice!, now);
          }
        }

        // Only start listening if a trackable external device is connected
        if (_connectionState == BluetoothConnectionState.connected &&
            _activeOutputDevice != null) {
          if (_sessionState == ListeningSessionState.idle) {
            // IDLE -> ACTIVE: Start new session
            await _startListeningSession(_activeOutputDevice!, now);
          } else if (_sessionState == ListeningSessionState.gracePeriod) {
            // GRACE_PERIOD -> ACTIVE: Resume the SAME session!
            _cancelGracePeriod();
            _sessionState = ListeningSessionState.active;
            _emitTrackingEvent(
              eventType: 'LISTENING_RESUMED',
              reason: 'Audio resumed within grace period',
            );
          } else if (_sessionState == ListeningSessionState.active) {
            // Invariant 11: Ignore duplicate AUDIO_STARTED when already active
            _cancelGracePeriod();
          }
        }
        break;

      case 'AUDIO_STOPPED':
        _audioState = AudioPlaybackState.notPlaying;
        _emitTrackingEvent(eventType: 'AUDIO_STOPPED');

        // ACTIVE -> GRACE_PERIOD: Grace period applies ONLY when audio stops while connected
        if (_connectionState == BluetoothConnectionState.connected &&
            _sessionState == ListeningSessionState.active) {
          _sessionState = ListeningSessionState.gracePeriod;
          _startGracePeriod();
        } else if (_sessionState == ListeningSessionState.gracePeriod) {
          // Already in grace period: do not restart timer
        } else {
          // Idle remains idle
          _sessionState = ListeningSessionState.idle;
        }
        break;

      case 'AUDIO_OUTPUT_CHANGED':
        _emitTrackingEvent(
          eventType: 'OUTPUT_CHANGED',
          metadata: {
            'connectionType': connectionType,
            'deviceName': deviceName,
          },
        );

        if (connectionType == 'internal' || deviceName == 'Phone Speaker') {
          // Switched to built-in phone speaker
          final connToClose = _activeConnectionRecord;
          _activeConnectionRecord = null;
          if (connToClose != null) {
            await _closeConnectionRecord(connToClose, now);
          }

          final sessionToClose = _currentDeviceSession;
          _currentDeviceSession = null;
          if (sessionToClose != null) {
            await _closeDeviceSession(sessionToClose, now);
          }

          final continuousToClose = _currentContinuousSession;
          _currentContinuousSession = null;
          if (continuousToClose != null) {
            await _closeContinuousSession(continuousToClose, now);
          }

          _cancelGracePeriod();
          _activeOutputDevice = null;
          _connectionState = _connectedDevices.isNotEmpty
              ? BluetoothConnectionState.connected
              : BluetoothConnectionState.disconnected;
          _sessionState = ListeningSessionState.idle;
        } else if (deviceName != null && connectionType != null) {
          final stableId = AudioDevice.generateStableId(
            name: deviceName,
            connectionType: connectionType,
            address: deviceAddress,
          );

          // If switching from Device A to Device B
          if (_activeOutputDevice != null &&
              _activeOutputDevice!.id != stableId) {
            final prevConn = _activeConnectionRecord;
            _activeConnectionRecord = null;
            if (prevConn != null) {
              await _closeConnectionRecord(prevConn, now);
            }

            final prevSession = _currentDeviceSession;
            _currentDeviceSession = null;
            if (prevSession != null) {
              await _closeDeviceSession(prevSession, now);
            }
          }

          final newDevice =
              _connectedDevices[stableId] ??
              AudioDevice(
                id: stableId,
                name: deviceName,
                deviceType: deviceType ?? 'Audio Device',
                connectionType: connectionType,
                address: deviceAddress,
                firstSeen: now,
                lastSeen: now,
              );

          _activeOutputDevice = newDevice;
          _connectionState = BluetoothConnectionState.connected;

          if (_activeConnectionRecord == null ||
              _activeConnectionRecord!.deviceId != stableId) {
            await _startConnectionRecord(newDevice, now);
          }

          // Listening depends strictly on actual audio state
          if (_audioState == AudioPlaybackState.playing) {
            await _startListeningSession(newDevice, now);
          } else {
            _sessionState = ListeningSessionState.idle;
          }
        }
        break;
    }

    await refreshHistory();
    onStateChanged?.call();
  }

  // =========================================================================
  // ConnectionRecord & ListeningSession Helpers
  // =========================================================================

  Future<void> _startConnectionRecord(AudioDevice device, DateTime now) async {
    _activeConnectionRecord = ConnectionRecord(
      id: 'conn_${now.microsecondsSinceEpoch}',
      deviceId: device.id,
      deviceName: device.name,
      deviceType: device.deviceType,
      connectedAt: now,
      durationSeconds: 0,
      status: 'active',
    );
    await _db.saveConnectionRecord(_activeConnectionRecord!);
    _emitTrackingEvent(
      eventType: 'CONNECTION_STARTED',
      deviceId: device.id,
      deviceName: device.name,
      deviceType: device.deviceType,
    );
  }

  Future<void> _closeConnectionRecord(
    ConnectionRecord record,
    DateTime now,
  ) async {
    final duration = now.difference(record.connectedAt).inSeconds;
    final finalized = record.copyWith(
      disconnectedAt: now,
      durationSeconds: duration > record.durationSeconds
          ? duration
          : record.durationSeconds,
      status: 'completed',
    );
    await _db.saveConnectionRecord(finalized);
    _emitTrackingEvent(
      eventType: 'CONNECTION_ENDED',
      deviceId: record.deviceId,
      deviceName: record.deviceName,
      durationSeconds: finalized.durationSeconds,
    );
  }

  Future<void> _startListeningSession(AudioDevice device, DateTime now) async {
    _cancelGracePeriod();

    _currentDeviceSession = ListeningSession(
      id: 'ds_${DateTime.now().microsecondsSinceEpoch}',
      deviceId: device.id,
      deviceName: device.name,
      deviceType: device.deviceType,
      connectedAt: _activeConnectionRecord?.connectedAt ?? now,
      listeningStartedAt: now,
      connectedDurationSeconds: _activeConnectionRecord?.durationSeconds ?? 0,
      activeListeningDurationSeconds: 0,
      silentDurationSeconds: 0,
      status: 'active',
    );

    _sessionState = ListeningSessionState.active;

    // Handle Continuous Listening Session
    if (_currentContinuousSession == null) {
      _currentContinuousSession = ContinuousListeningSession(
        id: 'cs_${DateTime.now().microsecondsSinceEpoch}',
        startedAt: now,
        activeListeningDurationSeconds: 0,
        pausedDurationSeconds: 0,
        deviceIds: [device.id],
        deviceNames: [device.name],
        status: 'active',
      );
    } else {
      if (!_currentContinuousSession!.deviceIds.contains(device.id)) {
        final updatedIds = List<String>.from(
          _currentContinuousSession!.deviceIds,
        )..add(device.id);
        final updatedNames = List<String>.from(
          _currentContinuousSession!.deviceNames,
        )..add(device.name);
        _currentContinuousSession = _currentContinuousSession!.copyWith(
          deviceIds: updatedIds,
          deviceNames: updatedNames,
        );
      }
    }

    _emitTrackingEvent(
      eventType: 'LISTENING_STARTED',
      deviceId: device.id,
      deviceName: device.name,
      deviceType: device.deviceType,
    );
  }

  Future<void> _closeDeviceSession(
    ListeningSession session,
    DateTime now,
  ) async {
    final totalConnected = now.difference(session.connectedAt).inSeconds;
    final active = session.activeListeningDurationSeconds;
    final silent = (totalConnected > active)
        ? (totalConnected - active)
        : session.silentDurationSeconds;

    final completed = session.copyWith(
      disconnectedAt: now,
      listeningEndedAt: now,
      connectedDurationSeconds:
          totalConnected > session.connectedDurationSeconds
          ? totalConnected
          : session.connectedDurationSeconds,
      activeListeningDurationSeconds: active,
      silentDurationSeconds: silent,
      status: 'completed',
    );

    await _db.saveDeviceSession(completed);
    _emitTrackingEvent(
      eventType: 'LISTENING_ENDED',
      deviceId: session.deviceId,
      deviceName: session.deviceName,
      durationSeconds: active,
      reason: 'Session finalized',
    );
  }

  Future<void> _closeContinuousSession(
    ContinuousListeningSession session,
    DateTime now,
  ) async {
    final completed = session.copyWith(endedAt: now, status: 'completed');
    await _db.saveContinuousSession(completed);
  }

  // =========================================================================
  // Grace Period with Token / Generation Safety
  // =========================================================================

  void _startGracePeriod() {
    _cancelGracePeriod();

    final currentToken = ++_graceTimerToken;
    _gracePeriodStartedAt = DateTime.now();

    _emitTrackingEvent(
      eventType: 'GRACE_STARTED',
      reason:
          'Audio stopped while connected (waiting up to ${gracePeriod.inSeconds}s)',
    );

    _gracePeriodTimer = Timer(gracePeriod, () async {
      // Invariant 6 & Stale Timer Guard: Token must match, session must still be in grace
      if (_graceTimerToken != currentToken) return;
      if (_sessionState != ListeningSessionState.gracePeriod) return;
      if (_connectionState != BluetoothConnectionState.connected) return;

      await _onGraceExpired();
    });
  }

  void _cancelGracePeriod() {
    _graceTimerToken++; // Invalidate any in-flight timers
    _gracePeriodTimer?.cancel();
    _gracePeriodTimer = null;
    _gracePeriodStartedAt = null;
  }

  Future<void> _onGraceExpired() async {
    final now = DateTime.now();

    _emitTrackingEvent(
      eventType: 'GRACE_EXPIRED',
      reason: 'Grace period expired without audio resuming',
    );

    _sessionState = ListeningSessionState.idle;
    _gracePeriodTimer = null;
    _gracePeriodStartedAt = null;

    final sessionToClose = _currentDeviceSession;
    _currentDeviceSession = null;
    if (sessionToClose != null) {
      await _closeDeviceSession(sessionToClose, now);
    }

    final continuousToClose = _currentContinuousSession;
    _currentContinuousSession = null;
    if (continuousToClose != null) {
      await _closeContinuousSession(continuousToClose, now);
    }

    await refreshHistory();
    onStateChanged?.call();
  }

  /// Exposed for testing to simulate grace period expiration deterministically
  @visibleForTesting
  Future<void> triggerGraceExpiredForTesting() async {
    if (_sessionState == ListeningSessionState.gracePeriod) {
      await _onGraceExpired();
    }
  }

  // =========================================================================
  // Ticker Timer & Durations
  // =========================================================================

  void _startTicker() {
    _tickerTimer?.cancel();
    _lastTickAt = DateTime.now();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _onTick();
    });
  }

  void _stopTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = null;
    _lastTickAt = null;
  }

  void _onTick() {
    final now = DateTime.now();
    final previousTick =
        _lastTickAt ?? now.subtract(const Duration(seconds: 1));
    final elapsedSeconds = now
        .difference(previousTick)
        .inSeconds
        .clamp(0, 86400);
    _lastTickAt = now;
    if (elapsedSeconds == 0) return;
    bool stateChanged = false;

    // 1. Connection Duration: Increments whenever connected
    if (_activeConnectionRecord != null) {
      _activeConnectionRecord = _activeConnectionRecord!.copyWith(
        durationSeconds:
            _activeConnectionRecord!.durationSeconds + elapsedSeconds,
      );
      stateChanged = true;
    }

    // 2. Device Session Duration: Tracks listening vs silent
    if (_currentDeviceSession != null) {
      final newConnected =
          _currentDeviceSession!.connectedDurationSeconds + elapsedSeconds;
      final previousActive =
          _currentDeviceSession!.activeListeningDurationSeconds;
      int newActive = previousActive;
      int newSilent = _currentDeviceSession!.silentDurationSeconds;

      if (_sessionState == ListeningSessionState.active &&
          _audioState == AudioPlaybackState.playing) {
        newActive += elapsedSeconds;
      } else {
        newSilent += elapsedSeconds;
      }

      _currentDeviceSession = _currentDeviceSession!.copyWith(
        connectedDurationSeconds: newConnected,
        activeListeningDurationSeconds: newActive,
        silentDurationSeconds: newSilent,
      );
      stateChanged = true;

      // Periodic checkpoint every 60 seconds of active listening to avoid excessive writes
      if (newActive > 0 &&
          newActive ~/ 60 > previousActive ~/ 60 &&
          _sessionState == ListeningSessionState.active) {
        _emitTrackingEvent(
          eventType: 'SESSION_CHECKPOINT',
          deviceId: _currentDeviceSession!.deviceId,
          deviceName: _currentDeviceSession!.deviceName,
          durationSeconds: newActive,
          reason: 'Active listening checkpoint after elapsed timer delay',
        );
      }
    }

    // 3. Continuous Session Duration
    if (_currentContinuousSession != null) {
      if (_sessionState == ListeningSessionState.active &&
          _audioState == AudioPlaybackState.playing) {
        final newActive =
            _currentContinuousSession!.activeListeningDurationSeconds +
            elapsedSeconds;
        _currentContinuousSession = _currentContinuousSession!.copyWith(
          activeListeningDurationSeconds: newActive,
        );
        stateChanged = true;
      } else if (_sessionState == ListeningSessionState.gracePeriod) {
        final newPaused =
            _currentContinuousSession!.pausedDurationSeconds + elapsedSeconds;
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

  // =========================================================================
  // Structured Event Logging
  // =========================================================================

  void _emitTrackingEvent({
    required String eventType,
    String? deviceId,
    String? deviceName,
    String? deviceType,
    String? reason,
    int? durationSeconds,
    Map<String, dynamic>? metadata,
  }) {
    final now = DateTime.now();
    final event = TrackingEvent(
      id: 'te_${now.microsecondsSinceEpoch}',
      eventType: eventType,
      timestamp: now,
      deviceId: deviceId ?? _activeOutputDevice?.id,
      deviceName: deviceName ?? _activeOutputDevice?.name,
      deviceType: deviceType ?? _activeOutputDevice?.deviceType,
      connectionState: _connectionState,
      audioState: _audioState,
      sessionState: _sessionState,
      reason: reason,
      durationSeconds: durationSeconds,
      metadata: metadata,
    );

    onTrackingEvent?.call(event);
    onLog?.call(event.toString());

    // Persist to diagnostic logger safely
    DiagnosticLogger.instance.logEvent(
      eventType: eventType,
      source: 'flutter',
      timestamp: now,
      deviceId: deviceId ?? _activeOutputDevice?.id,
      deviceName: deviceName ?? _activeOutputDevice?.name,
      reason: reason,
      sessionState: _sessionState.name,
      connectionState: _connectionState.name,
      rawPayload: () {
        final map = <String, dynamic>{...?metadata};
        if (durationSeconds != null) map['durationSeconds'] = durationSeconds;
        return map;
      }(),
    );
  }

  void dispose() {
    _stopTicker();
    _cancelGracePeriod();
  }
}
