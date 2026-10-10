import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio_monitor_service.dart';
import '../database/database_adapter.dart';
import '../models/diagnostic_event.dart';
import '../services/diagnostic_logger.dart';

/// Screen for browsing, filtering, inspecting, and exporting persistent diagnostic logs.
class DiagnosticLogViewer extends StatefulWidget {
  final DatabaseAdapter database;
  final AudioMonitorService? audioService;

  const DiagnosticLogViewer({
    super.key,
    required this.database,
    this.audioService,
  });

  @override
  State<DiagnosticLogViewer> createState() => _DiagnosticLogViewerState();
}

class _DiagnosticLogViewerState extends State<DiagnosticLogViewer> {
  List<DiagnosticEvent> _events = [];
  bool _isLoading = true;
  int _totalCount = 0;
  String _selectedFilter = 'ALL';
  int _page = 0;
  static const int _pageSize = 50;
  bool _hasMore = true;

  // Search/Filter controllers
  final TextEditingController _searchController = TextEditingController();

  final List<String> _filterCategories = [
    'ALL',
    'AUDIO',
    'STOP_WINDOW',
    'CONNECTION',
    'GRACE',
    'SESSION',
    'STARTUP',
    'ERRORS',
  ];

  @override
  void initState() {
    super.initState();
    _loadEvents(reset: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEvents({bool reset = false}) async {
    if (reset) {
      setState(() {
        _isLoading = true;
        _page = 0;
        _events.clear();
      });
    }

    try {
      final total = await widget.database.getDiagnosticEventCount();
      final offset = _page * _pageSize;
      final fetched = await widget.database.getDiagnosticEvents(
        limit: _pageSize,
        offset: offset,
      );

      if (mounted) {
        setState(() {
          if (reset) {
            _events = fetched;
          } else {
            _events.addAll(fetched);
          }
          _totalCount = total;
          _hasMore = fetched.length == _pageSize;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to load logs: $e')));
      }
    }
  }

  List<DiagnosticEvent> get _filteredEvents {
    return _events.where((event) {
      // Category filter
      if (_selectedFilter == 'AUDIO') {
        if (!event.eventType.contains('AUDIO')) return false;
      } else if (_selectedFilter == 'STOP_WINDOW') {
        if (!event.eventType.contains('STOP_CONFIRMATION')) return false;
      } else if (_selectedFilter == 'CONNECTION') {
        if (!event.eventType.contains('CONNECT') &&
            !event.eventType.contains('DEVICE')) {
          return false;
        }
      } else if (_selectedFilter == 'GRACE') {
        if (!event.eventType.contains('GRACE')) return false;
      } else if (_selectedFilter == 'SESSION') {
        if (!event.eventType.contains('SESSION') &&
            !event.eventType.contains('LISTENING')) {
          return false;
        }
      } else if (_selectedFilter == 'STARTUP') {
        const startupTerms = [
          'SERVICE',
          'FOREGROUND',
          'MONITORING',
          'RECEIVER',
          'LIFECYCLE',
          'SNAPSHOT',
          'EVENT_CHANNEL',
        ];
        if (!startupTerms.any(event.eventType.contains)) return false;
      } else if (_selectedFilter == 'ERRORS') {
        if (!event.eventType.contains('ERROR') &&
            !event.eventType.contains('FAIL') &&
            event.errorDetails == null) {
          return false;
        }
      }

      // Search query filter
      final query = _searchController.text.trim().toLowerCase();
      if (query.isNotEmpty) {
        final matchesType = event.eventType.toLowerCase().contains(query);
        final matchesDevice = (event.deviceName ?? '').toLowerCase().contains(
          query,
        );
        final matchesReason = (event.reason ?? '').toLowerCase().contains(
          query,
        );
        final matchesSignals = (event.resolverReason ?? '')
            .toLowerCase()
            .contains(query);
        if (!matchesType &&
            !matchesDevice &&
            !matchesReason &&
            !matchesSignals) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  Color _getEventColor(String eventType) {
    if (eventType.contains('AUDIO_STARTED') ||
        eventType.contains('LISTENING_STARTED')) {
      return Colors.greenAccent;
    } else if (eventType.contains('AUDIO_STOPPED') ||
        eventType.contains('STOP_CONFIRMATION_CONFIRMED')) {
      return Colors.amberAccent;
    } else if (eventType.contains('STOP_CONFIRMATION_SCHEDULED')) {
      return Colors.orangeAccent;
    } else if (eventType.contains('STOP_CONFIRMATION_CANCELLED')) {
      return Colors.lightGreenAccent;
    } else if (eventType.contains('CONNECTED')) {
      return Colors.cyanAccent;
    } else if (eventType.contains('DISCONNECTED')) {
      return Colors.redAccent;
    } else if (eventType.contains('ERROR') || eventType.contains('FAIL')) {
      return Colors.pinkAccent;
    } else if (eventType.contains('GRACE')) {
      return Colors.tealAccent;
    }
    return Colors.grey.shade300;
  }

  Future<void> _exportLogs() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final jsonString = await DiagnosticLogger.instance.exportEventsAsJson(
        limit: 5000,
      );
      if (mounted) Navigator.pop(context); // Dismiss loading dialog

      final fileName =
          'listening_tracker_logs_${DateTime.now().millisecondsSinceEpoch}.json';

      // Attempt native Android share sheet first via AudioMonitorService
      bool shared = false;
      if (widget.audioService != null) {
        shared = await widget.audioService!.shareLogFile(jsonString, fileName);
      }

      if (!shared && mounted) {
        // Fallback: Copy to clipboard
        await Clipboard.setData(ClipboardData(text: jsonString));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Exported ${jsonString.length} chars! Copied to clipboard (Share fallback).',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Dismiss loading dialog
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  void _showEventDetail(DiagnosticEvent event) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E222A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                controller: scrollController,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _getEventColor(event.eventType),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          event.eventType,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.copy,
                          size: 20,
                          color: Colors.grey,
                        ),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text: const JsonEncoder.withIndent('  ')
                                  .convert(event.toMap()),
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Copied event JSON to clipboard'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  _buildDetailRow('Timestamp', event.timestampIso),
                  _buildDetailRow('Epoch (ms)', '${event.timestamp}'),
                  _buildDetailRow('Source', event.source),
                  if (event.deviceName != null)
                    _buildDetailRow('Device Name', event.deviceName!),
                  if (event.deviceId != null)
                    _buildDetailRow('Device ID', event.deviceId!),
                  if (event.reason != null)
                    _buildDetailRow('Reason', event.reason!),
                  if (event.sessionState != null)
                    _buildDetailRow('Session State', event.sessionState!),
                  if (event.connectionState != null)
                    _buildDetailRow('Connection State', event.connectionState!),
                  if (event.stopConfirmationStatus != null)
                    _buildDetailRow(
                      'Stop Confirmation',
                      event.stopConfirmationStatus!,
                    ),

                  // Playback Resolver Signals Section
                  if (event.hasPlaybackDiagnostics) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Playback Resolver Signals',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.tealAccent,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildDetailRow(
                            'Configs Count',
                            '${event.playbackConfigsCount ?? 0}',
                          ),
                          _buildDetailRow(
                            'Active Media Count',
                            '${event.activeMediaCount ?? 0}',
                          ),
                          _buildDetailRow(
                            'Player States',
                            event.playbackStates ?? '[]',
                          ),
                          _buildDetailRow(
                            'isMusicActive',
                            '${event.isMusicActive ?? false}',
                          ),
                          _buildDetailRow(
                            'isA2dpStreaming',
                            '${event.isA2dpStreaming ?? false}',
                          ),
                          _buildDetailRow(
                            'prevPlaying',
                            '${event.prevPlaying ?? false}',
                          ),
                          _buildDetailRow(
                            'resolvedPlaying',
                            '${event.resolvedPlaying ?? false}',
                          ),
                          _buildDetailRow(
                            'Resolver Reason',
                            event.resolverReason ?? 'none',
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (event.errorDetails != null) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Error Details',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.pinkAccent,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.pink.shade900.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.pinkAccent.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        event.errorDetails!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],

                  if (event.metadata != null) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Raw Metadata',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        jsonEncode(event.metadata),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredEvents;

    return Scaffold(
      backgroundColor: const Color(0xFF121418),
      appBar: AppBar(
        title: const Text('Diagnostic Logs'),
        backgroundColor: const Color(0xFF1E222A),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Colors.tealAccent),
            tooltip: 'Export Logs (JSON)',
            onPressed: _exportLogs,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => _loadEvents(reset: true),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar & Filter Chips
          Container(
            color: const Color(0xFF1E222A),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search event, device, or reason...',
                    hintStyle: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 13,
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 20,
                      color: Colors.grey,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              size: 18,
                              color: Colors.grey,
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF121418),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _filterCategories.map((cat) {
                      final isSelected = _selectedFilter == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(cat),
                          selected: isSelected,
                          onSelected: (val) {
                            if (val) setState(() => _selectedFilter = cat);
                          },
                          labelStyle: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? Colors.black
                                : Colors.grey.shade400,
                          ),
                          selectedColor: Colors.tealAccent,
                          backgroundColor: const Color(0xFF282C34),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          // Total Count Info Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Showing ${filtered.length} of $_totalCount stored events',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                ),
                Text(
                  'Retention: 10,000 max',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
                ),
              ],
            ),
          ),

          // Events List
          Expanded(
            child: _isLoading && _events.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? Center(
                    child: Text(
                      'No diagnostic events match current filters.',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (scroll) {
                      if (!_isLoading &&
                          _hasMore &&
                          scroll.metrics.pixels >=
                              scroll.metrics.maxScrollExtent - 200) {
                        _page++;
                        _loadEvents(reset: false);
                      }
                      return false;
                    },
                    child: ListView.builder(
                      itemCount: filtered.length + (_hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == filtered.length) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }

                        final event = filtered[index];
                        final color = _getEventColor(event.eventType);

                        return InkWell(
                          onTap: () => _showEventDetail(event),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Color(0xFF1E222A),
                                  width: 1,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      event.timeClock,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: color.withValues(alpha: 0.5),
                                        ),
                                      ),
                                      child: Text(
                                        event.eventType,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: color,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      event.source,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade500,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                if (event.deviceName != null &&
                                    event.deviceName!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text(
                                      event.deviceName!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                if (event.playbackSignalsSummary.isNotEmpty)
                                  Text(
                                    event.playbackSignalsSummary,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Colors.tealAccent.shade100,
                                    ),
                                  ),
                                if (event.reason != null &&
                                    event.reason!.isNotEmpty)
                                  Text(
                                    event.reason!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade400,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
