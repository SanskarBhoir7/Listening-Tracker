import 'package:flutter/material.dart';
import '../database/database_adapter.dart';
import '../models/listening_session.dart';
import '../models/period_stats.dart';

/// Screen displaying historical listening sessions, daily summaries,
/// and individual session breakdowns for any chosen calendar date.
class HistoryView extends StatefulWidget {
  final DatabaseAdapter database;

  const HistoryView({
    super.key,
    required this.database,
  });

  @override
  State<HistoryView> createState() => HistoryViewState();
}

class HistoryViewState extends State<HistoryView> {
  late DateTime _selectedDate;
  bool _isLoading = true;
  PeriodStats? _dayStats;
  List<ListeningSession> _sessions = [];

  /// Public reload mechanism allowing external callers (or parent AppBars)
  /// to refresh history data for the currently selected date.
  Future<void> loadHistoryData() => _loadHistoryData();
  Future<void> refresh() => _loadHistoryData();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _loadHistoryData();
  }

  Future<void> _loadHistoryData() async {
    setState(() => _isLoading = true);

    final startOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      0,
      0,
      0,
      0,
    );
    final endOfDay = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      23,
      59,
      59,
      999,
    );

    // PeriodStats guarantees: totalConnectedSeconds comes strictly from connection_records
    final stats = await widget.database.getPeriodStats(startOfDay, endOfDay);
    final sessions = await widget.database.getDeviceSessionsForDateRange(startOfDay, endOfDay);

    if (mounted) {
      setState(() {
        _dayStats = stats;
        _sessions = sessions;
        _isLoading = false;
      });
    }
  }

  void _previousDay() {
    setState(() {
      _selectedDate = _selectedDate.subtract(const Duration(days: 1));
    });
    _loadHistoryData();
  }

  void _nextDay() {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final next = _selectedDate.add(const Duration(days: 1));
    if (next.isBefore(tomorrow)) {
      setState(() {
        _selectedDate = next;
      });
      _loadHistoryData();
    }
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() {
      _selectedDate = DateTime(now.year, now.month, now.day);
    });
    _loadHistoryData();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.dark(
              primary: Colors.teal.shade300,
              onPrimary: Colors.black,
              surface: Colors.grey.shade900,
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDate = DateTime(picked.year, picked.month, picked.day);
      });
      _loadHistoryData();
    }
  }

  String _formatDateTitle(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final normalized = DateTime(date.year, date.month, date.day);
    if (normalized == today) return 'Today';
    if (normalized == yesterday) return 'Yesterday';

    final weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDateSelector(),
          const SizedBox(height: 12),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _buildDailySummaryCard(),
            const SizedBox(height: 14),
            _buildSessionsListHeader(),
            const SizedBox(height: 8),
            if (_sessions.isEmpty)
              _buildEmptyState()
            else
              ..._sessions.map(_buildSessionCard),
          ],
        ],
      ),
    );
  }

  Widget _buildDateSelector() {
    final now = DateTime.now();
    final isToday = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day) ==
        DateTime(now.year, now.month, now.day);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _previousDay,
              tooltip: 'Previous day',
            ),
            Expanded(
              child: InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 16, color: Colors.tealAccent),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _formatDateTitle(_selectedDate),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: isToday ? null : _nextDay,
              tooltip: 'Next day',
            ),
            if (!isToday) ...[
              const SizedBox(width: 4),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _goToToday,
                child: const Text('Today', style: TextStyle(fontSize: 12)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDailySummaryCard() {
    final stats = _dayStats ?? PeriodStats.empty(_selectedDate, _selectedDate);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Daily Summary',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal.shade300,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('history_refresh_button'),
                  icon: const Icon(Icons.refresh, size: 18),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  tooltip: 'Refresh history',
                  onPressed: _loadHistoryData,
                ),
              ],
            ),
            const Divider(height: 16),
            _buildSummaryRow(
              'Active Listening',
              stats.totalListeningFormatted,
              valueColor: Colors.greenAccent,
              isBold: true,
            ),
            _buildSummaryRow(
              'Bluetooth Connected',
              stats.totalConnectedFormatted,
              valueColor: Colors.cyanAccent.shade100,
            ),
            _buildSummaryRow(
              'Silent / Paused',
              stats.totalSilentFormatted,
              valueColor: Colors.grey.shade300,
            ),
            _buildSummaryRow(
              'Listening Sessions',
              '${stats.sessionCount}',
            ),
            _buildSummaryRow(
              'Longest Session',
              stats.longestSessionFormatted,
              valueColor: Colors.tealAccent.shade100,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(
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

  Widget _buildSessionsListHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'Recorded Sessions (${_sessions.length})',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.teal.shade300,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildSessionCard(ListeningSession s) {
    final startTimeStr = _formatTime(s.connectedAt);
    final endTimeStr = s.disconnectedAt != null
        ? _formatTime(s.disconnectedAt!)
        : 'Active';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: device name & time range
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  s.deviceType.contains('Bluetooth')
                      ? Icons.bluetooth
                      : Icons.headphones,
                  size: 18,
                  color: Colors.tealAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.deviceName,
                        softWrap: true,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$startTimeStr – $endTimeStr',
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
            const Divider(height: 16),
            // Duration metrics breakdown
            _buildSummaryRow(
              'Listening Time',
              s.activeListeningDurationFormatted,
              valueColor: Colors.greenAccent,
              isBold: true,
            ),
            _buildSummaryRow(
              'Connected Time',
              s.connectedDurationFormatted,
              valueColor: Colors.cyanAccent.shade100,
            ),
            _buildSummaryRow(
              'Silent / Paused',
              s.silentDurationFormatted,
              valueColor: Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.headset_off_outlined,
              size: 48,
              color: Colors.grey.shade600,
            ),
            const SizedBox(height: 12),
            const Text(
              'No Sessions Recorded',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'No listening activity found for ${_formatDateTitle(_selectedDate)}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
