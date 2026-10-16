import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../database/database_adapter.dart';
import '../models/daily_trend_point.dart';
import '../models/device_usage_stats.dart';
import '../models/period_comparison.dart';
import '../models/period_stats.dart';
import '../models/weekly_listening_insights.dart';
import '../services/analytics_calculator.dart';

enum AnalyticsPeriod { today, last7Days, last30Days }

/// Screen providing comprehensive listening analytics, period summaries,
/// per-device usage breakdowns, and chronological daily trends.
class AnalyticsView extends StatefulWidget {
  final DatabaseAdapter database;

  const AnalyticsView({super.key, required this.database});

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
  WeeklyListeningInsights? _weeklyInsights;

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
    final weekStart = AnalyticsCalculator.startOfLocalWeek(now);
    final weeklySessionsFuture = widget.database.getDeviceSessionsForDateRange(
      weekStart,
      now,
    );

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
    final rawDeviceStats = await widget.database.getDeviceUsageStats(
      rangeStart,
      todayEnd,
    );
    final sortedDevices = AnalyticsCalculator.sortDeviceUsage(rawDeviceStats);
    final mostUsed = AnalyticsCalculator.findMostUsedDevice(sortedDevices);

    // 3. Fetch trend records
    final sessions = await widget.database.getDeviceSessionsForDateRange(
      rangeStart,
      todayEnd,
    );
    final connections = await widget.database.getConnectionRecordsForDateRange(
      rangeStart,
      todayEnd,
    );
    final trends = AnalyticsCalculator.buildDailyTrends(
      startDate: rangeStart,
      endDate: todayEnd,
      sessions: sessions,
      connectionRecords: connections,
    );
    final weeklySessions = await weeklySessionsFuture;
    final weeklyInsights = AnalyticsCalculator.buildWeeklyListeningInsights(
      referenceDate: now,
      sessions: weeklySessions,
    );

    if (mounted) {
      setState(() {
        _periodStats = stats;
        _comparison = comparison;
        _deviceStats = sortedDevices;
        _dailyTrends = trends;
        _mostUsedDevice = mostUsed;
        _weeklyInsights = weeklyInsights;
        _isLoading = false;
      });
    }
  }

  String _formatDateShort(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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
          if (_weeklyInsights case final insights?) ...[
            _buildWeeklyInsightsCard(insights),
            const SizedBox(height: 12),
          ],
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

  Widget _buildWeeklyInsightsCard(WeeklyListeningInsights insights) {
    return Card(
      key: const Key('weekly_insights_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This week',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: ListeningPalette.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${_formatWeekDate(insights.weekStart)} – ${_formatWeekDate(insights.throughDate)} · local time',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: ListeningPalette.muted),
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final metrics = [
                  _buildWeeklyMetric(
                    'Listening time',
                    insights.totalListeningFormatted,
                    key: const Key('weekly_total_duration'),
                  ),
                  _buildWeeklyMetric(
                    'Sessions',
                    '${insights.totalSessionCount}',
                    key: const Key('weekly_session_count'),
                  ),
                ];
                if (constraints.maxWidth < 350) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      metrics[0],
                      const SizedBox(height: 12),
                      metrics[1],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: metrics[0]),
                    const SizedBox(width: 12),
                    Expanded(child: metrics[1]),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            const Divider(),
            const SizedBox(height: 12),
            Text(
              'Sessions across the week',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Bars show listening time · counts show sessions per day',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: ListeningPalette.muted),
            ),
            const SizedBox(height: 12),
            if (insights.hasSessions)
              _buildWeeklyTrendChart(insights)
            else
              Container(
                key: const Key('weekly_empty_state'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: ListeningPalette.surfaceRaised,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'No listening sessions this week yet.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: ListeningPalette.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeeklyMetric(String label, String value, {Key? key}) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: ListeningPalette.muted),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: ListeningPalette.mint,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildWeeklyTrendChart(WeeklyListeningInsights insights) {
    final maxListeningSeconds = insights.dailyTrends.fold<int>(
      0,
      (maxSeconds, point) => point.listeningSeconds > maxSeconds
          ? point.listeningSeconds
          : maxSeconds,
    );
    const weekdayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Row(
      key: const Key('weekly_trend_chart'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final point in insights.dailyTrends)
          Expanded(
            child: Semantics(
              label:
                  '${_formatWeekDate(point.date)}, ${point.sessionCount} sessions, ${point.listeningFormatted} listening',
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${point.sessionCount}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: point.sessionCount > 0
                            ? ListeningPalette.text
                            : ListeningPalette.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 52,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: AnimatedContainer(
                          key: Key(
                            'weekly_trend_day_${point.date.year}-${point.date.month.toString().padLeft(2, '0')}-${point.date.day.toString().padLeft(2, '0')}',
                          ),
                          duration: const Duration(milliseconds: 240),
                          width: 14,
                          height: maxListeningSeconds == 0
                              ? 4
                              : (point.listeningSeconds /
                                        maxListeningSeconds *
                                        48)
                                    .clamp(4.0, 48.0),
                          decoration: BoxDecoration(
                            color: point.listeningSeconds > 0
                                ? ListeningPalette.mint
                                : ListeningPalette.separator,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      weekdayLabels[point.date.weekday - 1],
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: ListeningPalette.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _formatWeekDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
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
    final stats =
        _periodStats ?? PeriodStats.empty(DateTime.now(), DateTime.now());
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
                    color: ListeningPalette.text,
                    letterSpacing: 0.2,
                  ),
                ),
                if (comparison != null && !comparison.isListeningEqual)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: comparison.isListeningIncreased
                          ? Colors.green.shade900.withValues(alpha: 0.4)
                          : Colors.red.shade900.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: comparison.isListeningIncreased
                            ? ListeningPalette.mint
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
                            ? ListeningPalette.mint
                            : Colors.redAccent,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 16),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(color: Colors.transparent),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total Listening Time',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade300),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    stats.totalListeningFormatted,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: ListeningPalette.mint,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            _buildMetricRow(
              'Total Bluetooth Time',
              stats.totalConnectedFormatted,
              valueColor: ListeningPalette.cyan,
            ),
            _buildMetricRow(
              'Listening Ratio',
              '${(stats.listeningRatio * 100).toStringAsFixed(1)}%',
              valueColor: ListeningPalette.mint,
            ),
            _buildMetricRow('Listening Sessions', '${stats.sessionCount}'),
            _buildMetricRow('Average Session', stats.averageSessionFormatted),
            _buildMetricRow(
              'Longest Session',
              stats.longestSessionFormatted,
              valueColor: ListeningPalette.mint,
            ),
            _buildMetricRow(
              'Most-Used Device',
              _mostUsedDevice?.deviceName ?? 'None',
              valueColor: _mostUsedDevice != null
                  ? Colors.white
                  : Colors.grey.shade500,
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
                color: ListeningPalette.text,
                letterSpacing: 0.2,
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
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    border: const Border(
                      bottom: BorderSide(color: ListeningPalette.separator),
                    ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade900.withValues(
                                  alpha: 0.4,
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'CONNECTED ONLY',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: ListeningPalette.amber,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _buildDeviceMetric(
                                  'Listening',
                                  dev.totalListeningFormatted,
                                  ListeningPalette.mint,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _buildDeviceMetric(
                                  'Connected',
                                  dev.totalConnectedFormatted,
                                  ListeningPalette.cyan,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _buildDeviceMetric(
                                  'Sessions',
                                  '${dev.sessionCount}',
                                  Colors.white,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _buildDeviceMetric(
                                  'Ratio',
                                  '${(dev.listeningRatio * 100).toStringAsFixed(0)}%',
                                  ListeningPalette.mint,
                                ),
                              ),
                            ],
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

  Widget _buildDeviceMetric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
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
                color: ListeningPalette.text,
                letterSpacing: 0.2,
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
              ..._dailyTrends.reversed.map(_buildDailyTrendRow),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyTrendRow(DailyTrendPoint point) {
    final dateLabel = _formatDateShort(point.date);
    final hasActivity = point.hasActivity;
    final progress = point.connectedSeconds <= 0
        ? 0.0
        : (point.listeningSeconds / point.connectedSeconds).clamp(0.0, 1.0);

    final values = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 2,
      children: hasActivity
          ? [
              Text(
                point.listeningFormatted,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: ListeningPalette.mint,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                '/ ${point.connectedFormatted}',
                style: TextStyle(fontSize: 11, color: ListeningPalette.cyan),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: ListeningPalette.surfaceRaised,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${(point.listeningRatio * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: ListeningPalette.mint,
                  ),
                ),
              ),
            ]
          : [
              Text(
                'No activity',
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final date = Text(
                dateLabel,
                softWrap: true,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: hasActivity ? FontWeight.bold : FontWeight.normal,
                  color: hasActivity ? Colors.white : Colors.grey.shade500,
                ),
              );
              if (constraints.maxWidth < 240) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [date, const SizedBox(height: 2), values],
                );
              }
              return Row(
                children: [
                  Flexible(flex: 4, child: date),
                  const SizedBox(width: 8),
                  Expanded(flex: 6, child: values),
                ],
              );
            },
          ),
          if (hasActivity) ...[
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: ListeningPalette.separator,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  ListeningPalette.mint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
