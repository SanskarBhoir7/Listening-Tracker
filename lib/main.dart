import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio_monitor_service.dart';
import 'session_engine.dart';
import 'tracking_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ListeningTrackerApp());
}

class ListeningTrackerApp extends StatelessWidget {
  const ListeningTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Listening Tracker — Phase 3',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        fontFamily: 'monospace',
      ),
      home: const MonitorDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({super.key});

  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard>
    with WidgetsBindingObserver {
  final AudioMonitorService _audioService = AudioMonitorService();
  final SessionEngine _engine = SessionEngine();
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;

  // Permissions state
  Map<String, bool> _permissions = {};

  // Event log
  final List<String> _eventLog = [];
  static const int _maxLogEntries = 250;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _engine.onStateChanged = () {
      if (mounted) setState(() {});
    };

    _engine.onLog = (msg) {
      _addLogEntry(msg);
    };

    _initialize();
  }

  Future<void> _initialize() async {
    await _engine.initialize();
    await _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSubscription?.cancel();
    _engine.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _addLogEntry('LIFECYCLE: ${state.name.toUpperCase()}');
    if (state == AppLifecycleState.resumed && _engine.isMonitoring) {
      _refreshCurrentState();
    }
  }

  Future<void> _checkPermissions() async {
    final perms = await _audioService.checkPermissions();
    if (mounted) {
      setState(() {
        _permissions = perms;
      });
    }
  }

  Future<void> _requestPermissions() async {
    await _audioService.requestPermissions();
    await Future.delayed(const Duration(seconds: 2));
    await _checkPermissions();
  }

  Future<void> _startMonitoring() async {
    _addLogEntry('MONITORING_STARTED');

    _eventSubscription = _audioService.audioEvents.listen(
      _handleAudioEvent,
      onError: (error) {
        _addLogEntry('ERROR: $error');
      },
    );

    await _audioService.startMonitoring();
    _engine.startMonitoring();

    await _refreshCurrentState();
  }

  Future<void> _stopMonitoring() async {
    _addLogEntry('MONITORING_STOPPED');
    await _audioService.stopMonitoring();
    _eventSubscription?.cancel();
    _eventSubscription = null;
    await _engine.stopMonitoring();
  }

  Future<void> _refreshCurrentState() async {
    final state = await _audioService.getCurrentState();
    if (mounted && state.isNotEmpty && !state.containsKey('error')) {
      await _engine.processStateSnapshot(state);
    }
  }

  void _handleAudioEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? 'UNKNOWN';
    final deviceName = event['deviceName'] as String?;
    final previousDeviceName = event['previousDeviceName'] as String?;

    String logEntry = type;
    if (deviceName != null && deviceName.isNotEmpty) {
      logEntry += ' | $deviceName';
    }
    if (previousDeviceName != null) {
      logEntry += ' (was: $previousDeviceName)';
    }
    _addLogEntry(logEntry);

    _engine.handleNativeEvent(event);
  }

  void _addLogEntry(String entry) {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final logLine = '$timeStr $entry';

    if (mounted) {
      setState(() {
        _eventLog.insert(0, logLine);
        if (_eventLog.length > _maxLogEntries) {
          _eventLog.removeLast();
        }
      });
    }
  }

  String _computeCurrentState() {
    if (!_engine.isMonitoring) return 'IDLE (Monitoring Off)';

    final isBtConnected = _engine.connectionState == BluetoothConnectionState.connected;
    final isListening = _engine.sessionState == ListeningSessionState.active;
    final inGrace = _engine.sessionState == ListeningSessionState.gracePeriod;
    final isAudioPlaying = _engine.audioState == AudioPlaybackState.playing;

    if (isListening) return 'LISTENING (Active)';
    if (inGrace) {
      final rem = _engine.gracePeriodRemaining?.inSeconds ?? 0;
      return 'PAUSED (Grace: ${rem}s)';
    }
    if (isBtConnected && !isAudioPlaying) return 'CONNECTED (Idle / Silent)';
    if (!isBtConnected && isAudioPlaying) return 'PLAYING (Phone Speaker)';
    return 'STANDBY (No Device)';
  }

  Color _getStateColor(String state) {
    if (state.startsWith('LISTENING')) {
      return Colors.greenAccent.shade400;
    } else if (state.startsWith('PAUSED')) {
      return Colors.amberAccent.shade400;
    } else if (state.startsWith('CONNECTED')) {
      return Colors.lightBlueAccent.shade400;
    } else if (state.startsWith('PLAYING')) {
      return Colors.orangeAccent.shade400;
    } else {
      return Colors.grey.shade400;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentState = _computeCurrentState();
    final stateColor = _getStateColor(currentState);

    return Scaffold(
      appBar: AppBar(
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'LISTENING TRACKER — PHASE 3',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _engine.isMonitoring ? _refreshCurrentState : null,
            tooltip: 'Refresh state',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Permissions card if missing
            _buildPermissionsCard(),
            const SizedBox(height: 10),

            // Start/Stop monitoring button
            _buildControlButton(),
            const SizedBox(height: 14),

            // Current state big indicator
            _buildStateIndicator(currentState, stateColor),
            const SizedBox(height: 10),

            // Phase 3: Separate Connection & Listening Durations
            _buildDualDurationCard(),
            const SizedBox(height: 14),

            // Live Session Card
            _buildLiveSessionCard(),
            const SizedBox(height: 12),

            // Active Output Device
            _buildActiveOutputCard(),
            const SizedBox(height: 12),

            // Connected Devices Registry
            _buildConnectedDevicesCard(),
            const SizedBox(height: 12),

            // Today Summary
            _buildTodaySummaryCard(),
            const SizedBox(height: 12),

            // Recent Sessions (Today's history)
            _buildRecentSessionsCard(),
            const SizedBox(height: 12),

            // Live Debug Event Log
            _buildEventLog(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionsCard() {
    final allGranted = _permissions.values.isNotEmpty &&
        _permissions.values.every((granted) => granted);

    if (allGranted) return const SizedBox.shrink();

    return Card(
      color: Colors.amber.shade900.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PERMISSIONS NEEDED',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ..._permissions.entries.map((entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${entry.key}: ${entry.value ? "✅ Granted" : "❌ Not granted"}',
                    style: TextStyle(
                      color: entry.value ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                )),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _requestPermissions,
              icon: const Icon(Icons.security, size: 16),
              label: const Text('Grant Permissions'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade800,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton() {
    final isMon = _engine.isMonitoring;
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: isMon ? _stopMonitoring : _startMonitoring,
        icon: Icon(isMon ? Icons.stop : Icons.play_arrow),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            isMon ? 'STOP MONITORING' : 'START MONITORING',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: isMon ? Colors.red.shade800 : Colors.teal.shade700,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildStateIndicator(String currentState, Color stateColor) {
    final remainingGrace = _engine.gracePeriodRemaining;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: stateColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: stateColor, width: 2),
      ),
      child: Column(
        children: [
          Text(
            'CURRENT STATE',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              currentState,
              style: TextStyle(
                color: stateColor,
                fontSize: 24,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
          if (_engine.activeOutputDevice != null) ...[
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _engine.liveActiveListeningFormatted,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w300,
                  color: Colors.white,
                ),
              ),
            ),
          ],
          if (remainingGrace != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Grace Period: ${remainingGrace.inSeconds}s remaining',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.amberAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDualDurationCard() {
    final isBtConnected = _engine.connectionState == BluetoothConnectionState.connected;
    final isListening = _engine.sessionState == ListeningSessionState.active;
    final inGrace = _engine.sessionState == ListeningSessionState.gracePeriod;

    return Row(
      children: [
        // Connection Duration Box
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.cyan.shade900.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isBtConnected ? Colors.cyanAccent.shade400 : Colors.cyan.shade900,
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  'CONNECTION TIME',
                  style: TextStyle(
                    color: Colors.cyanAccent.shade100,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _engine.liveConnectedFormatted,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isBtConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    fontSize: 11,
                    color: isBtConnected ? Colors.cyanAccent : Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Listening Duration Box
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.green.shade900.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isListening
                    ? Colors.greenAccent.shade400
                    : inGrace
                        ? Colors.amberAccent.shade400
                        : Colors.green.shade900,
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  'LISTENING TIME',
                  style: TextStyle(
                    color: Colors.greenAccent.shade100,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _engine.liveActiveListeningFormatted,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isListening
                      ? 'Listening'
                      : inGrace
                          ? 'Paused (Grace)'
                          : 'Not listening',
                  style: TextStyle(
                    fontSize: 11,
                    color: isListening
                        ? Colors.greenAccent
                        : inGrace
                            ? Colors.amberAccent
                            : Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveSessionCard() {
    final isBt = _engine.connectionState == BluetoothConnectionState.connected;
    final isAudio = _engine.audioState == AudioPlaybackState.playing;
    final sessState = _engine.sessionState;

    String sessionStatus;
    Color sessionColor;
    if (sessState == ListeningSessionState.active) {
      sessionStatus = 'Active (Listening)';
      sessionColor = Colors.greenAccent.shade200;
    } else if (sessState == ListeningSessionState.gracePeriod) {
      final rem = _engine.gracePeriodRemaining?.inSeconds ?? 0;
      sessionStatus = 'Paused (Resuming within ${rem}s)';
      sessionColor = Colors.amberAccent;
    } else {
      sessionStatus = isBt ? 'Idle (Connected, Not Listening)' : 'Idle (Disconnected)';
      sessionColor = Colors.grey;
    }

    return _buildSection(
      'Live Session Tracking (Separated)',
      [
        _buildRow(
          'Bluetooth State',
          isBt ? 'Connected' : 'Disconnected',
          valueColor: isBt ? Colors.cyanAccent : Colors.grey,
        ),
        _buildRow(
          'Audio Playback',
          isAudio ? 'Playing' : 'Not Playing',
          valueColor: isAudio ? Colors.greenAccent : Colors.grey,
        ),
        _buildRow(
          'Listening Session',
          sessionStatus,
          valueColor: sessionColor,
          valueWeight: FontWeight.bold,
        ),
        _buildRow('Connection Duration', _engine.liveConnectedFormatted,
            valueColor: Colors.cyanAccent.shade100),
        _buildRow('Listening Duration', _engine.liveActiveListeningFormatted,
            valueColor: Colors.greenAccent.shade200, valueWeight: FontWeight.bold),
        _buildRow('Silent / Paused', _engine.liveSilentFormatted),
        _buildRow('Continuous Total', _engine.liveContinuousFormatted,
            valueColor: Colors.tealAccent.shade100),
        _buildRow(
          'Audio Grace Window',
          '${_engine.gracePeriod.inMinutes} min (Audio pause only)',
          valueColor: Colors.amberAccent.shade100,
        ),
      ],
    );
  }

  Widget _buildActiveOutputCard() {
    final active = _engine.activeOutputDevice;
    return _buildSection(
      'Active Audio Output',
      [
        _buildRow('Name', active?.name ?? 'Built-in Phone Speaker'),
        _buildRow('Type', active?.deviceType ?? 'Built-in Speaker'),
        _buildRow('Connection', active?.connectionType ?? 'internal'),
        _buildRow('Audio Playing', _engine.isAudioPlaying ? 'YES' : 'NO',
            valueColor: _engine.isAudioPlaying ? Colors.greenAccent : Colors.grey),
      ],
    );
  }

  Widget _buildConnectedDevicesCard() {
    final devices = _engine.connectedDevicesList;
    final activeId = _engine.activeOutputDevice?.id;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Connected Devices (${devices.length})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade300,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No headphones or earphones currently connected.',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              )
            else
              ...devices.map((dev) {
                final isActive = dev.id == activeId;
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isActive
                        ? Colors.teal.shade900.withValues(alpha: 0.3)
                        : Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isActive ? Colors.tealAccent : Colors.grey.shade800,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        dev.connectionType == 'bluetooth'
                            ? Icons.bluetooth
                            : dev.connectionType == 'usb'
                                ? Icons.usb
                                : Icons.headphones,
                        size: 18,
                        color: isActive ? Colors.tealAccent : Colors.grey.shade400,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dev.name,
                              softWrap: true,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: isActive ? Colors.white : Colors.grey.shade300,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${dev.deviceType} • ${dev.connectionType}',
                              softWrap: true,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade400,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.green.shade800
                              : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isActive ? 'ACTIVE' : 'STANDBY',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildTodaySummaryCard() {
    final stats = _engine.todayStats;

    return _buildSection(
      'Today Summary',
      [
        _buildRow('Total Connected', stats.totalConnectedFormatted),
        _buildRow('Active Listening', stats.totalActiveListeningFormatted,
            valueColor: Colors.greenAccent),
        _buildRow('Silent / Paused', stats.totalSilentFormatted),
        _buildRow('Device Sessions', '${stats.deviceSessionCount}'),
        _buildRow('Continuous Sessions', '${stats.continuousSessionCount}'),
        _buildRow('Devices Used', '${stats.devicesUsedCount}'),
        _buildRow('Longest Session', stats.longestContinuousFormatted,
            valueColor: Colors.tealAccent.shade100),
      ],
    );
  }

  Widget _buildRecentSessionsCard() {
    final sessions = _engine.recentDeviceSessions;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Sessions (Today)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade300,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(
                  '${sessions.length} saved',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No completed sessions recorded today yet.',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              )
            else
              ...sessions.map((s) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Device Name Header
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            s.deviceType.contains('Bluetooth')
                                ? Icons.bluetooth
                                : Icons.headphones,
                            size: 16,
                            color: Colors.tealAccent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              s.deviceName,
                              softWrap: true,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Durations breakdown
                      _buildMiniRow('Connected', s.connectedDurationFormatted),
                      _buildMiniRow('Listening', s.activeListeningDurationFormatted,
                          color: Colors.greenAccent),
                      _buildMiniRow('Silent', s.silentDurationFormatted),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 70, maxWidth: 100),
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color ?? Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> rows) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.teal.shade300,
                letterSpacing: 0.8,
              ),
            ),
            const Divider(height: 16),
            ...rows,
          ],
        ),
      ),
    );
  }

  /// Responsive row that guarantees zero horizontal RenderFlex overflows on any screen width
  Widget _buildRow(
    String label,
    String value, {
    Color? valueColor,
    FontWeight? valueWeight,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 90, maxWidth: 130),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(
                fontSize: 13,
                fontWeight: valueWeight ?? FontWeight.w500,
                color: valueColor ?? Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventLog() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Event Log',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade300,
                    letterSpacing: 0.8,
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _eventLog.join('\n')));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Log copied to clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: const Text('Copy', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _eventLog.clear();
                        });
                      },
                      child: const Text('Clear', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 8),
            if (_eventLog.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No events yet. Start monitoring to begin.',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontStyle: FontStyle.italic,
                    fontSize: 12,
                  ),
                ),
              )
            else
              SizedBox(
                height: 280,
                child: ListView.builder(
                  itemCount: _eventLog.length,
                  itemBuilder: (context, index) {
                    final entry = _eventLog[index];
                    Color entryColor = Colors.grey.shade300;
                    if (entry.contains('BT_CONNECTED') ||
                        entry.contains('CONNECTION_STARTED') ||
                        entry.contains('DEVICE_CONNECTED')) {
                      entryColor = Colors.cyanAccent.shade200;
                    } else if (entry.contains('BT_DISCONNECTED') ||
                        entry.contains('CONNECTION_ENDED') ||
                        entry.contains('DEVICE_DISCONNECTED')) {
                      entryColor = Colors.red.shade300;
                    } else if (entry.contains('LISTENING_STARTED') ||
                        entry.contains('AUDIO_STARTED')) {
                      entryColor = Colors.greenAccent.shade200;
                    } else if (entry.contains('LISTENING_RESUMED') ||
                        entry.contains('GRACE_CANCELLED')) {
                      entryColor = Colors.tealAccent.shade200;
                    } else if (entry.contains('AUDIO_STOPPED') ||
                        entry.contains('GRACE_STARTED')) {
                      entryColor = Colors.amberAccent.shade200;
                    } else if (entry.contains('GRACE_EXPIRED') ||
                        entry.contains('LISTENING_ENDED')) {
                      entryColor = Colors.orange.shade300;
                    } else if (entry.contains('OUTPUT_CHANGED') ||
                        entry.contains('AUDIO_OUTPUT_CHANGED')) {
                      entryColor = Colors.purple.shade300;
                    } else if (entry.contains('PERSISTED_SESSION')) {
                      entryColor = Colors.tealAccent.shade200;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        entry,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: 11,
                          color: entryColor,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
