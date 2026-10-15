import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'audio_monitor_service.dart';
import 'database/database_adapter.dart';
import 'database/database_helper.dart';
import 'models/break_state.dart';
import 'session_engine.dart';
import 'tracking_state.dart';
import 'services/diagnostic_logger.dart';
import 'views/analytics_view.dart';
import 'views/break_settings_view.dart';
import 'views/developer_tools_view.dart';
import 'views/history_view.dart';
import 'widgets/soundspan_logo.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ListeningTrackerApp());
}

class ListeningTrackerApp extends StatelessWidget {
  const ListeningTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SoundSpan',
      theme: ListeningTheme.dark,
      home: const MonitorDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MonitorDashboard extends StatefulWidget {
  final AudioMonitorService? audioService;
  final SessionEngine? engine;
  final DatabaseAdapter? database;

  const MonitorDashboard({
    super.key,
    this.audioService,
    this.engine,
    this.database,
  });

  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard>
    with WidgetsBindingObserver {
  late final AudioMonitorService _audioService;
  late final SessionEngine _engine;
  late final DatabaseAdapter _database;
  late final bool _ownsEngine;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;

  // Selected navigation tab (0: Live Monitor, 1: History, 2: Analytics)
  int _selectedTabIndex = 0;

  // Global keys to trigger reloads on child views
  final GlobalKey<HistoryViewState> _historyKey = GlobalKey<HistoryViewState>();
  final GlobalKey<AnalyticsViewState> _analyticsKey =
      GlobalKey<AnalyticsViewState>();

  // Permissions state
  Map<String, bool> _permissions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _database = widget.database ?? DatabaseHelper.instance;
    _audioService = widget.audioService ?? AudioMonitorService();
    if (widget.engine != null) {
      _engine = widget.engine!;
      _ownsEngine = false;
    } else {
      _engine = SessionEngine(database: _database);
      _ownsEngine = true;
    }

    _engine.onStateChanged = () {
      if (mounted) setState(() {});
    };

    _engine.onLog = (msg) {
      _addLogEntry(msg);
    };

    // Configure persistent diagnostic logger with active database
    DiagnosticLogger.instance.setDatabase(_database);

    _initialize();
  }

  bool _isStartingMonitoring = false;

  Future<void> _initialize() async {
    await DiagnosticLogger.instance.logLifecycle(
      'FLUTTER_APP_INITIALIZATION_STARTED',
      source: 'flutter',
    );
    await _engine.initialize();
    await _checkPermissions();
    await _importNativeLifecycleEvents();
    _ensureSubscribedToEvents();
    if (mounted) {
      await _refreshCurrentState();
    }
  }

  Future<void> _importNativeLifecycleEvents() async {
    final events = await _audioService.drainNativeLifecycleEvents();
    final importedIds = <String>[];
    for (final event in events) {
      final details = Map<String, dynamic>.from(
        event['details'] as Map? ?? const {},
      );
      details['nativeEventId'] = event['id'];
      details['nativeProcessId'] = event['processId'];
      final persisted = await DiagnosticLogger.instance.logEvent(
        eventId: 'native_${event['id']}',
        eventType: event['eventType'] as String? ?? 'NATIVE_LIFECYCLE_UNKNOWN',
        source: 'native_lifecycle',
        timestampMs: event['timestamp'] as int?,
        rawPayload: details,
      );
      if (persisted != null) importedIds.add(event['id'] as String);
    }
    await _audioService.acknowledgeNativeLifecycleEvents(importedIds);
  }

  void _ensureSubscribedToEvents() {
    _eventSubscription ??= _audioService.audioEvents.listen(
      _handleAudioEvent,
      onError: (error) {
        _addLogEntry('ERROR: $error');
        DiagnosticLogger.instance.logEvent(
          eventType: 'ERROR',
          source: 'flutter',
          errorDetails: '$error',
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSubscription?.cancel();
    if (_ownsEngine) {
      _engine.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _addLogEntry('LIFECYCLE: ${state.name.toUpperCase()}');
    DiagnosticLogger.instance.logLifecycle(
      'APP_LIFECYCLE_${state.name.toUpperCase()}',
      source: 'flutter',
    );
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
    if (mounted) {
      await _refreshCurrentState();
    }
  }

  Future<void> _startMonitoring() async {
    if (_isStartingMonitoring || _engine.isMonitoring) return;
    _isStartingMonitoring = true;
    try {
      _addLogEntry('MONITORING_START_REQUESTED');
      DiagnosticLogger.instance.logEvent(
        eventType: 'MONITORING_START_REQUESTED',
        source: 'flutter',
        reason: 'User or system initiated monitoring',
      );
      _ensureSubscribedToEvents();

      final accepted = await _audioService.startMonitoring();
      if (!accepted) {
        throw StateError('Native monitoring service start was rejected');
      }

      await _refreshCurrentState();
    } catch (e) {
      DiagnosticLogger.instance.logEvent(
        eventType: 'MONITORING_START_FAILED',
        source: 'flutter',
        errorDetails: '$e',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Monitoring could not start: $e')),
        );
      }
    } finally {
      _isStartingMonitoring = false;
    }
  }

  Future<void> _stopMonitoring() async {
    if (!_engine.isMonitoring) return;
    _addLogEntry('MONITORING_STOPPED');
    DiagnosticLogger.instance.logEvent(
      eventType: 'MONITORING_STOPPED',
      source: 'flutter',
      reason: 'User or system stopped monitoring',
    );
    await _audioService.stopMonitoring();
    await _engine.stopMonitoring();
    if (mounted) setState(() {});
  }

  Future<void> _refreshCurrentState() async {
    DiagnosticLogger.instance.logEvent(
      eventType: 'FLUTTER_SNAPSHOT_RECOVERY_REQUESTED',
      source: 'flutter',
      reason: 'Refreshing native monitoring state',
    );
    final state = await _audioService.getCurrentState();
    DiagnosticLogger.instance.logEvent(
      eventType: 'FLUTTER_SNAPSHOT_RECOVERY_COMPLETED',
      source: 'flutter',
      rawPayload: {
        'nativeMonitoring': state['isMonitoring'],
        'connectedDeviceCount':
            (state['connectedDevices'] as List?)?.length ?? 0,
        'hasError': state.containsKey('error'),
      },
    );
    if (mounted && state.isNotEmpty && !state.containsKey('error')) {
      final isMon = state['isMonitoring'] as bool? ?? false;
      if (isMon && !_engine.isMonitoring) {
        _engine.startMonitoring();
      } else if (!isMon && _engine.isMonitoring) {
        await _engine.stopMonitoring();
      }
      await _engine.processStateSnapshot(state);
    }
  }

  Future<void> _handleAudioEvent(Map<String, dynamic> event) async {
    final type = event['type'] as String? ?? 'UNKNOWN';
    if (type == 'MONITORING_STATE_CHANGED') {
      final active = event['isMonitoring'] as bool? ?? false;
      if (active && !_engine.isMonitoring) {
        _engine.startMonitoring();
      } else if (!active && _engine.isMonitoring) {
        await _engine.stopMonitoring();
      }
      DiagnosticLogger.instance.logEvent(
        eventType: active ? 'MONITORING_ACTIVE' : 'MONITORING_INACTIVE',
        source: 'native',
        reason: event['reason'] as String?,
      );
      return;
    }
    final deviceName = event['deviceName'] as String?;
    final previousDeviceName = event['previousDeviceName'] as String?;
    final diagnostics = event['diagnostics'] as String?;

    String logEntry = type;
    if (deviceName != null && deviceName.isNotEmpty) {
      logEntry += ' | $deviceName';
    }
    if (previousDeviceName != null) {
      logEntry += ' (was: $previousDeviceName)';
    }
    if (diagnostics != null && diagnostics.isNotEmpty) {
      logEntry += ' ($diagnostics)';
    }
    _addLogEntry(logEntry);

    // Save native event to persistent diagnostic log
    DiagnosticLogger.instance.logNativeAudioEvent(event);

    try {
      // Bluetooth connection lifecycle controls monitoring:
      // Await database finalization & session reconciliation
      await _engine.handleNativeEvent(event);

      // Disconnect finalization order: SessionEngine closes sessions first, then monitoring stops
      if (type == 'DEVICE_DISCONNECTED') {
        if (_engine.connectedDevicesList.isEmpty && _engine.isMonitoring) {
          await _engine.stopMonitoring();
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      _addLogEntry('ERROR processing event $type: $e');
      await DiagnosticLogger.instance.logEvent(
        eventType: 'ERROR_PROCESSING_EVENT',
        source: 'flutter',
        errorDetails: '$e',
        rawPayload: {'originalEvent': event},
      );
    }
  }

  void _addLogEntry(String entry) {
    debugPrint('ListeningTracker: $entry');
  }

  String _computeCurrentState() {
    final isBtConnected =
        _engine.connectionState == BluetoothConnectionState.connected;
    final isListening = _engine.sessionState == ListeningSessionState.active;
    final inGrace = _engine.sessionState == ListeningSessionState.gracePeriod;
    final isAudioPlaying = _engine.audioState == AudioPlaybackState.playing;

    if (isListening) return 'LISTENING (Active)';
    if (inGrace) {
      final rem = _engine.gracePeriodRemaining?.inSeconds ?? 0;
      return 'PAUSED (Grace: ${rem}s)';
    }
    if (isBtConnected && !_engine.isMonitoring) {
      return 'CONNECTED (Monitoring Inactive)';
    }
    if (isBtConnected && !isAudioPlaying) return 'CONNECTED (Idle / Silent)';
    if (!_engine.isMonitoring) return 'IDLE (Monitoring Off)';
    if (!isBtConnected && isAudioPlaying) return 'PLAYING (Phone Speaker)';
    return 'STANDBY (No Device)';
  }

  Color _getStateColor(String state) {
    if (state.startsWith('LISTENING')) {
      return ListeningPalette.mint;
    } else if (state.startsWith('PAUSED')) {
      return ListeningPalette.amber;
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

    String appTitle;
    switch (_selectedTabIndex) {
      case 1:
        appTitle = 'History';
        break;
      case 2:
        appTitle = 'Analytics';
        break;
      default:
        appTitle = 'Live Monitor';
    }

    return Scaffold(
      appBar: AppBar(
        title: _selectedTabIndex == 0
            ? LayoutBuilder(
                builder: (context, constraints) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SoundSpanLogo(key: Key('soundspan_logo'), size: 26),
                    const SizedBox(width: 9),
                    Flexible(
                      child: Text(
                        key: const Key('screen_title'),
                        'SoundSpan',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (constraints.maxWidth >= 190) ...[
                      const SizedBox(width: 9),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: ListeningPalette.surfaceRaised,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          'Live',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: ListeningPalette.muted,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              )
            : Text(
                key: const Key('screen_title'),
                appTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        centerTitle: false,
        actions: [
          if (kDebugMode)
            IconButton(
              key: const Key('appbar_developer_tools_button'),
              icon: const Icon(Icons.code_rounded),
              tooltip: 'Developer tools',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DeveloperToolsView(
                      engine: _engine,
                      database: _database,
                      audioService: _audioService,
                    ),
                  ),
                );
              },
            ),
          IconButton(
            key: const Key('appbar_break_settings_button'),
            icon: const Icon(Icons.timer_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BreakSettingsView(sessionEngine: _engine),
                ),
              );
            },
            tooltip: 'Break reminder settings',
          ),
          IconButton(
            key: const Key('appbar_refresh_button'),
            icon: const Icon(Icons.refresh),
            onPressed: (_selectedTabIndex == 0 && !_engine.isMonitoring)
                ? null
                : () {
                    if (_selectedTabIndex == 1) {
                      _historyKey.currentState?.loadHistoryData();
                    } else if (_selectedTabIndex == 2) {
                      _analyticsKey.currentState?.loadAnalyticsData();
                    } else if (_engine.isMonitoring) {
                      _refreshCurrentState();
                    }
                  },
            tooltip: _selectedTabIndex == 1
                ? 'Refresh history'
                : (_selectedTabIndex == 2
                      ? 'Refresh analytics'
                      : 'Refresh state'),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: [
          _buildLiveMonitorView(currentState, stateColor),
          HistoryView(key: _historyKey, database: _database),
          AnalyticsView(key: _analyticsKey, database: _database),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 72,
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Live Monitor',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.analytics_outlined),
            selectedIcon: Icon(Icons.analytics),
            label: 'Analytics',
          ),
        ],
      ),
    );
  }

  Widget _buildLiveMonitorView(String currentState, Color stateColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPermissionsCard(),
          const SizedBox(height: 12),
          _buildStateIndicator(currentState, stateColor),
          const SizedBox(height: 12),
          _buildDualDurationCard(),
          const SizedBox(height: 12),
          _buildBreakStatusCard(),
          const SizedBox(height: 12),
          _buildControlButton(),
          const SizedBox(height: 12),
          _buildLiveSessionCard(),
          const SizedBox(height: 12),
          _buildActiveOutputCard(),
          const SizedBox(height: 12),
          _buildConnectedDevicesCard(),
          const SizedBox(height: 12),
          _buildTodaySummaryCard(),
          const SizedBox(height: 12),
          _buildRecentSessionsCard(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildPermissionsCard() {
    final runtimePerms = {
      if (_permissions.containsKey('bluetooth_connect'))
        'bluetooth_connect': _permissions['bluetooth_connect']!,
      if (_permissions.containsKey('post_notifications'))
        'post_notifications': _permissions['post_notifications']!,
    };
    final allGranted =
        runtimePerms.values.isNotEmpty &&
        runtimePerms.values.every((granted) => granted);

    if (allGranted) return const SizedBox.shrink();

    return Card(
      color: ListeningPalette.surface,
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
            ...runtimePerms.entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${entry.key}: ${entry.value ? "✅ Granted" : "❌ Not granted"}',
                  style: TextStyle(
                    color: entry.value
                        ? ListeningPalette.mint
                        : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _requestPermissions,
              icon: const Icon(Icons.security, size: 16),
              label: const Text('Grant Permissions'),
              style: ElevatedButton.styleFrom(
                backgroundColor: ListeningPalette.amber,
                foregroundColor: ListeningPalette.background,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
          backgroundColor: isMon
              ? ListeningPalette.urgent
              : ListeningPalette.mint,
          foregroundColor: ListeningPalette.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _buildStateIndicator(String currentState, Color stateColor) {
    final remainingGrace = _engine.gracePeriodRemaining;
    final activeDevice = _engine.activeOutputDevice;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ListeningPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: stateColor.withValues(alpha: 0.65),
          width: 1.3,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.monitor_heart, color: stateColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'MONITOR STATUS',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 10,
                        letterSpacing: 1.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      currentState,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: stateColor,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                _engine.isMonitoring
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 12,
                color: _engine.isMonitoring
                    ? const Color(0xFF2CE59B)
                    : Colors.grey.shade500,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _engine.isMonitoring ? 'Monitoring active' : 'Monitoring off',
                  softWrap: true,
                  style: TextStyle(
                    color: _engine.isMonitoring
                        ? const Color(0xFF2CE59B)
                        : Colors.grey.shade400,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (activeDevice != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.headphones,
                    size: 16,
                    color: Color(0xFF00F5D4),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      activeDevice.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ],
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
                  color: ListeningPalette.amber,
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
    final isBtConnected =
        _engine.connectionState == BluetoothConnectionState.connected;
    final isListening = _engine.sessionState == ListeningSessionState.active;
    final inGrace = _engine.sessionState == ListeningSessionState.gracePeriod;
    final listeningColor = isListening
        ? ListeningPalette.mint
        : inGrace
        ? ListeningPalette.amber
        : ListeningPalette.muted;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LISTENING TIME',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: ListeningPalette.muted,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(
                _engine.liveActiveListeningFormatted,
                key: const Key('primary_listening_timer'),
                style: TextStyle(
                  fontSize: 48,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: listeningColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isListening
                  ? 'Audio is playing'
                  : inGrace
                  ? 'Playback paused · session continues briefly'
                  : isBtConnected
                  ? 'Headphones connected · waiting for audio'
                  : 'Listening time starts when audio plays',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: ListeningPalette.muted),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _compactMetric(
                  'Connected',
                  _engine.liveConnectedFormatted,
                  color: isBtConnected
                      ? ListeningPalette.cyan
                      : ListeningPalette.muted,
                ),
                _compactMetric(
                  'Silent / paused',
                  _engine.liveSilentFormatted,
                  color: ListeningPalette.muted,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactMetric(String label, String value, {required Color color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: ListeningPalette.muted, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildBreakStatusCard() {
    final breakState = _engine.breakState;
    final color = breakState.statusColor;
    final breakConfig = _engine.breakEngine.config;
    final nextThreshold = breakState.status == BreakStatus.normal
        ? breakConfig.breakSoonThreshold
        : breakConfig.breakRecommendedThreshold;
    final thresholdProgress = nextThreshold.inSeconds <= 0
        ? 1.0
        : (breakState.continuousListeningDuration.inSeconds /
                  nextThreshold.inSeconds)
              .clamp(0.0, 1.0);

    return Card(
      key: const Key('break_status_card'),
      color: ListeningPalette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: breakState.status != BreakStatus.normal
              ? color.withValues(alpha: 0.8)
              : Colors.white12,
          width: breakState.status != BreakStatus.normal ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        breakState.status == BreakStatus.normal
                            ? Icons.headphones
                            : (breakState.status == BreakStatus.breakSoon
                                  ? Icons.alarm
                                  : Icons.warning_amber_rounded),
                        color: color,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      const Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Break reminders',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        key: const Key('break_engine_settings_icon_button'),
                        icon: const Icon(Icons.settings, size: 18),
                        color: ListeningPalette.mint,
                        padding: const EdgeInsets.all(2),
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        tooltip: 'Break reminder settings',
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  BreakSettingsView(sessionEngine: _engine),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: color.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          breakState.statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: color,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'CONTINUOUS LISTENING',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          breakState.listeningDurationFormatted,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'NEXT THRESHOLD',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          breakState.timeUntilNextThresholdFormatted,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color:
                                breakState.timeUntilNextThreshold ==
                                    Duration.zero
                                ? Colors.grey.shade500
                                : ListeningPalette.mint,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (breakState.isEnabled) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      breakState.status == BreakStatus.normal
                          ? 'Progress to first reminder'
                          : breakState.status == BreakStatus.breakSoon
                          ? 'Progress to recommended break'
                          : 'Recommended threshold reached',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(thresholdProgress * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  key: const Key('break_threshold_progress'),
                  value: thresholdProgress,
                  minHeight: 7,
                  backgroundColor: Colors.white10,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 15, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      breakState.recommendation,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (breakState.isEnabled &&
                (breakState.status != BreakStatus.normal ||
                    breakState.isSnoozed)) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      key: const Key('card_snooze_break_button'),
                      icon: const Icon(Icons.snooze, size: 16),
                      label: Text(
                        breakState.isSnoozed
                            ? 'Snoozed (~${breakState.snoozeRemaining != null ? (breakState.snoozeRemaining!.inSeconds / 60).ceil() : 0}m)'
                            : 'Snooze',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ListeningPalette.amber,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      onPressed: () async {
                        await _engine.snoozeBreakReminder();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('card_dismiss_break_button'),
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(
                        breakState.isDismissed ? 'Dismissed' : 'Dismiss',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      onPressed: breakState.isDismissed
                          ? null
                          : () async {
                              await _engine.dismissBreakReminder();
                            },
                    ),
                  ),
                ],
              ),
            ],
            if (!breakState.isEnabled) ...[
              const SizedBox(height: 10),
              InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BreakSettingsView(sessionEngine: _engine),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text(
                        'Reminders are paused in settings',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      Text(
                        'Configure',
                        style: TextStyle(
                          fontSize: 11,
                          color: ListeningPalette.mint,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('card_break_settings_button'),
                icon: const Icon(Icons.tune, size: 16, color: Colors.black),
                label: const Text(
                  'Break Settings',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.8,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ListeningPalette.mint,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BreakSettingsView(sessionEngine: _engine),
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

  Widget _buildLiveSessionCard() {
    final isBt = _engine.connectionState == BluetoothConnectionState.connected;
    final isAudio = _engine.audioState == AudioPlaybackState.playing;
    final sessState = _engine.sessionState;

    String sessionStatus;
    Color sessionColor;
    if (sessState == ListeningSessionState.active) {
      sessionStatus = 'Active (Listening)';
      sessionColor = ListeningPalette.mint;
    } else if (sessState == ListeningSessionState.gracePeriod) {
      final rem = _engine.gracePeriodRemaining?.inSeconds ?? 0;
      sessionStatus = 'Paused (Resuming within ${rem}s)';
      sessionColor = ListeningPalette.amber;
    } else {
      sessionStatus = isBt
          ? 'Idle (Connected, Not Listening)'
          : 'Idle (Disconnected)';
      sessionColor = Colors.grey;
    }

    return _buildSection('Playback details', [
      _buildRow(
        'Bluetooth State',
        isBt ? 'Connected' : 'Disconnected',
        valueColor: isBt ? ListeningPalette.cyan : Colors.grey,
      ),
      _buildRow(
        'Audio Playback',
        isAudio ? 'Playing' : 'Not Playing',
        valueColor: isAudio ? ListeningPalette.mint : Colors.grey,
      ),
      _buildRow(
        'Listening Session',
        sessionStatus,
        valueColor: sessionColor,
        valueWeight: FontWeight.bold,
      ),
      _buildRow('Silent / Paused', _engine.liveSilentFormatted),
      _buildRow(
        'Audio Grace Window',
        '${_engine.gracePeriod.inMinutes} min (Audio pause only)',
        valueColor: ListeningPalette.amber,
      ),
    ]);
  }

  Widget _buildActiveOutputCard() {
    final active = _engine.activeOutputDevice;
    final isPlaying = _engine.isAudioPlaying;

    return Card(
      color: const Color(0xFF151B23),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: ListeningPalette.cyan.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.graphic_eq,
                  color: Color(0xFF00F5D4),
                  size: 18,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Active Audio Output',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00F5D4),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (isPlaying ? const Color(0xFF2CE59B) : Colors.white30)
                            .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isPlaying ? 'PLAYING' : 'SILENT',
                    style: TextStyle(
                      color: isPlaying
                          ? const Color(0xFF2CE59B)
                          : Colors.grey.shade400,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  active?.connectionType == 'bluetooth'
                      ? Icons.bluetooth
                      : Icons.headphones,
                  size: 20,
                  color: ListeningPalette.cyan,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active?.name ?? 'Built-in Phone Speaker',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${active?.deviceType ?? 'Built-in Speaker'} · ${active?.connectionType ?? 'internal'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
            Text(
              'Connected Devices (${devices.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: ListeningPalette.mint,
                letterSpacing: 0.8,
              ),
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
                        ? ListeningPalette.surfaceRaised.withValues(alpha: 0.3)
                        : ListeningPalette.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isActive
                          ? ListeningPalette.mint
                          : Colors.grey.shade800,
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
                        color: isActive
                            ? ListeningPalette.mint
                            : Colors.grey.shade400,
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
                                color: isActive
                                    ? Colors.white
                                    : Colors.grey.shade300,
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
                            if (dev.connectionType == 'bluetooth') ...[
                              const SizedBox(height: 2),
                              Text(
                                'Battery: unavailable from Android',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
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

    return _buildSection('Today Summary', [
      _buildRow('Total Connected', stats.totalConnectedFormatted),
      _buildRow(
        'Active Listening',
        stats.totalActiveListeningFormatted,
        valueColor: ListeningPalette.mint,
      ),
      _buildRow('Silent / Paused', stats.totalSilentFormatted),
      _buildRow('Device Sessions', '${stats.deviceSessionCount}'),
      _buildRow('Continuous Sessions', '${stats.continuousSessionCount}'),
      _buildRow('Devices Used', '${stats.devicesUsedCount}'),
      _buildRow(
        'Longest Session',
        stats.longestContinuousFormatted,
        valueColor: ListeningPalette.mint,
      ),
    ]);
  }

  Widget _buildRecentSessionsCard() {
    final sessions = _engine.recentDeviceSessions;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  'Recent Sessions (Today)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: ListeningPalette.mint,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(
                  '${sessions.length} saved',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
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
                    color: ListeningPalette.surface,
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
                            color: ListeningPalette.mint,
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
                      _buildMiniRow(
                        'Listening',
                        s.activeListeningDurationFormatted,
                        color: ListeningPalette.mint,
                      ),
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
          Flexible(
            flex: 4,
            child: Text(
              label,
              softWrap: true,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
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
                color: ListeningPalette.mint,
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          // If available width is extremely narrow (< 240px) or high accessibility scale,
          // stack label and value vertically so long values like
          // "Paused (Resuming within 179s)" never overflow horizontally.
          if (constraints.maxWidth < 240) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  softWrap: true,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  softWrap: true,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: valueWeight ?? FontWeight.w500,
                    color: valueColor ?? Colors.white,
                  ),
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                flex: 4,
                child: Text(
                  label,
                  softWrap: true,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 6,
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
          );
        },
      ),
    );
  }
}
