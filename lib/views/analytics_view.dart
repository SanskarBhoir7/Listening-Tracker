import 'package:flutter/material.dart';
import '../database/database_adapter.dart';
import '../models/daily_trend_point.dart';
import '../models/device_usage_stats.dart';
import '../models/period_comparison.dart';
import '../models/period_stats.dart';
import '../services/analytics_calculator.dart';

enum AnalyticsPeriod { today, last7Days, last30Days }

/// Screen providing comprehensive listening analytics, period summaries,
/// per-device usage breakdowns, and chronological daily trends.
class AnalyticsView extends StatefulWidget {
  final DatabaseAdapter database;

  const AnalyticsView({
    super.key,
    required this.database,
  });

  @override
  State<AnalyticsView> createState() => AnalyticsViewState();
}

class AnalyticsViewState extends State<AnalyticsView> {
  AnalyticsPeriod _selectedPeriod = AnalyticsPeriod.last7Days;
  bool _isLoading = true;

  /// Public reload mechanism allowing external callers to refresh analytics data
  Future<void> loadAnalyticsData() => _loadAnalyticsData();
  Future<void> refresh() => _loadAnalyticsData();

  PeriodStats? _periodStats;
  PeriodComparison? _comparison;
  List<DeviceUsageStats> _deviceStats = [];
  List<DailyTrendPoint> _dailyTrends = [];
  DeviceUsageStats? _mostUsedDevice;

  @override
  void initState() {
    super.initState();
    _loadAnalyticsData();
  }

  void _onPeriodChanged(AnalyticsPeriod period) {
    if (_selectedPeriod != period) {
      setState(() {
        _selectedPeriod = period;
      });
      _loadAnalyticsData();
    }
  }

  Future<void> _loadAnalyticsData() async {
    setState(() => _isLoading = true);

    final now = DateTime.now();
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

    late final DateTime rangeStart;
    late final DateTime prevStart;
    late final DateTime prevEnd;

    switch (_selectedPeriod) {
      case AnalyticsPeriod.today:
        rangeStart = DateTime(now.year, now.month, now.day, 0, 0, 0, 0);
        // Previous period = yesterday
        prevStart = DateTime(now.year, now.month, now.day - 1, 0, 0, 0, 0);
        prevEnd = DateTime(now.year, now.month, now.day - 1, 23, 59, 59, 999);
        break;
      case AnalyticsPeriod.last7Days:
        // 7 calendar days including today
        rangeStart = DateTime(now.year, now.month, now.day - 6, 0, 0, 0, 0);
        // Previous period = 7 days prior
        prevStart = DateTime(now.year, now.month, now.day - 13, 0, 0, 0, 0);
        prevEnd = DateTime(now.year, now.month, now.day - 7, 23, 59, 59, 999);
        break;
      case AnalyticsPeriod.last30Days:
        // 30 calendar days including today
        rangeStart = DateTime(now.year, now.month, now.day - 29, 0, 0, 0, 0);
        // Previous period = 30 days prior
        prevStart = DateTime(now.year, now.month, now.day - 59, 0, 0, 0, 0);
        prevEnd = DateTime(now.year, now.month, now.day - 30, 23, 59, 59, 999);
        break;
    }

    // 1. Fetch current and previous period stats (connection time comes from connection_records)
    final stats = await widget.database.getPeriodStats(rangeStart, todayEnd);
    final prevStats = await widget.database.getPeriodStats(prevStart, prevEnd);
    final comparison = AnalyticsCalculator.comparePeriods(stats, prevStats);

    // 2. Fetch device stats
    final rawDeviceStats = await widget.database.getDeviceUsageStats(rangeStart, todayEnd);
    final sortedDevices = AnalyticsCalculator.sortDeviceUsage(rawDeviceStats);
    final mostUsed = AnalyticsCalculator.findMostUsedDevice(sortedDevices);

    // 3. Fetch trend records
    final sessions = await widget.database.getDeviceSessionsForDateRange(rangeStart, todayEnd);
    final connections = await widget.database.getConnectionRecordsForDateRange(rangeStart, todayEnd);
    final trends = AnalyticsCalculator.buildDailyTrends(
      startDate: rangeStart,
      endDate: todayEnd,
      sessions: sessions,
      connectionRecords: connections,
    );

    if (mounted) {
      setState(() {
        _periodStats = stats;
        _comparison = comparison;
        _deviceStats = sortedDevices;
        _dailyTrends = trends;
        _mostUsedDevice = mostUsed;
        _isLoading = false;
      });
    }
  }

  String _formatDateShort(DateTime dt) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${weekdays[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPeriodSelector(),
          const SizedBox(height: 12),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _buildPeriodSummaryCard(),
            const SizedBox(height: 14),
            _buildDeviceBreakdownCard(),
            const SizedBox(height: 14),
            _buildDailyTrendCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return SegmentedButton<AnalyticsPeriod>(
      segments: const [
        ButtonSegment(
          value: AnalyticsPeriod.today,
          label: Text('Today', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: AnalyticsPeriod.last7Days,
          label: Text('7 Days', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: AnalyticsPeriod.last30Days,
          label: Text('30 Days', style: TextStyle(fontSize: 12)),
        ),
      ],
      selected: {_selectedPeriod},
      onSelectionChanged: (newSelection) {
        if (newSelection.isNotEmpty) {
          _onPeriodChanged(newSelection.first);
        }
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildPeriodSummaryCard() {
    final stats = _periodStats ?? PeriodStats.empty(DateTime.now(), DateTime.now());
    final comparison = _comparison;

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
                  'Period Summary',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade300,
                    letterSpacing: 0.8,
                  ),
                ),
                if (comparison != null && !comparison.isListeningEqual)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: comparison.isListeningIncreased
                          ? Colors.green.shade900.withValues(alpha: 0.4)
                          : Colors.red.shade900.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: comparison.isListeningIncreased
                            ? Colors.greenAccent
                            : Colors.redAccent,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      '${comparison.isListeningIncreased ? '+' : ''}${comparison.listeningPercentageChange.toStringAsFixed(0)}% vs prev',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: comparison.isListeningIncreased
                            ? Colors.greenAccent
                            : Colors.redAccent,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 16),
            _buildMetricRow(
              'Total Listening Time',
              stats.totalListeningFormatted,
              valueColor: Colors.greenAccent,
              isBold: true,
            ),
            _buildMetricRow(
              'Total Bluetooth Time',
              stats.totalConnectedFormatted,
              valueColor: Colors.cyanAccent.shade100,
            ),
            _buildMetricRow(
              'Listening Ratio',
              '${(stats.listeningRatio * 100).toStringAsFixed(1)}%',
              valueColor: Colors.tealAccent,
            ),
            _buildMetricRow(
              'Listening Sessions',
              '${stats.sessionCount}',
            ),
            _buildMetricRow(
              'Average Session',
              stats.averageSessionFormatted,
            ),
            _buildMetricRow(
              'Longest Session',
              stats.longestSessionFormatted,
              valueColor: Colors.tealAccent.shade100,
            ),
            _buildMetricRow(
              'Most-Used Device',
              _mostUsedDevice?.deviceName ?? 'None',
              valueColor: _mostUsedDevice != null ? Colors.white : Colors.grey.shade500,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(
    String label,
    String value, {
    Color? valueColor,
    bool isBold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            flex: 5,
            child: Text(
              label,
              softWrap: true,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
                color: valueColor ?? Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceBreakdownCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device Breakdown (${_deviceStats.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.teal.shade300,
                letterSpacing: 0.8,
              ),
            ),
            const Divider(height: 16),
            if (_deviceStats.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'No device activity in this period.',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontStyle: FontStyle.italic,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else
              ..._deviceStats.map((dev) {
                final isConnOnly = AnalyticsCalculator.isConnectionOnly(dev);

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade800),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              dev.deviceName,
                              softWrap: true,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (isConnOnly)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade900.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'CONNECTED ONLY',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.amberAccent,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Listening',
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  dev.totalListeningFormatted,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.greenAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Connected',
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  dev.totalConnectedFormatted,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.cyanAccent.shade100,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sessions',
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${dev.sessionCount}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ratio',
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${(dev.listeningRatio * 100).toStringAsFixed(0)}%',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.tealAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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

  Widget _buildDailyTrendCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Daily Trend (${_dailyTrends.length} days)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.teal.shade300,
                letterSpacing: 0.8,
              ),
            ),
            const Divider(height: 16),
            if (_dailyTrends.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'No trend data available.',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontStyle: FontStyle.italic,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else
              ..._dailyTrends.reversed.map((point) {
                final dateLabel = _formatDateShort(point.date);
                final hasActivity = point.hasActivity;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 240) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dateLabel,
                              softWrap: true,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: hasActivity ? FontWeight.bold : FontWeight.normal,
                                color: hasActivity ? Colors.white : Colors.grey.shade500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            if (!hasActivity)
                              Text(
                                'No activity',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  color: Colors.grey.shade600,
                                ),
                              )
                            else
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  Text(
                                    point.listeningFormatted,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.greenAccent,
                                    ),
                                  ),
                                  Text(
                                    '/ ${point.connectedFormatted}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.cyanAccent.shade100,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.shade900.withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      '${(point.listeningRatio * 100).toStringAsFixed(0)}%',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.tealAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            flex: 4,
                            child: Text(
                              dateLabel,
                              softWrap: true,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: hasActivity ? FontWeight.bold : FontWeight.normal,
                                color: hasActivity ? Colors.white : Colors.grey.shade500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 6,
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,
                              runSpacing: 2,
                              children: [
                                if (!hasActivity)
                                  Text(
                                    'No activity',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: Colors.grey.shade600,
                                    ),
                                  )
                                else ...[
                                  Text(
                                    point.listeningFormatted,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.greenAccent,
                                    ),
                                  ),
                                  Text(
                                    '/ ${point.connectedFormatted}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.cyanAccent.shade100,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.teal.shade900.withValues(alpha: 0.5),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      '${(point.listeningRatio * 100).toStringAsFixed(0)}%',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.tealAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
