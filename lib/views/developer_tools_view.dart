import 'package:flutter/material.dart';

import '../audio_monitor_service.dart';
import '../database/database_adapter.dart';
import '../session_engine.dart';
import 'diagnostic_log_viewer.dart';

/// A clearly separated container for debug-only controls and diagnostics.
class DeveloperToolsView extends StatelessWidget {
  final SessionEngine engine;
  final DatabaseAdapter database;
  final AudioMonitorService audioService;

  const DeveloperToolsView({
    super.key,
    required this.engine,
    required this.database,
    required this.audioService,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer Tools'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to Live Monitor',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        key: const Key('developer_tools_screen'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          DebugSimulationCard(engine: engine),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Diagnostics',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Browse, filter, and export the persistent event log.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('open_diagnostic_log_button'),
                    icon: const Icon(Icons.list_alt),
                    label: const Text('Open diagnostic log'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DiagnosticLogViewer(
                            database: database,
                            audioService: audioService,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DebugSimulationCard extends StatefulWidget {
  final SessionEngine engine;

  const DebugSimulationCard({super.key, required this.engine});

  @override
  State<DebugSimulationCard> createState() => _DebugSimulationCardState();
}

class _DebugSimulationCardState extends State<DebugSimulationCard> {
  @override
  Widget build(BuildContext context) {
    final state = widget.engine.breakState;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Break simulation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Debug-only time controls for exercising reminder states.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (state.isSimulated) ...[
              const SizedBox(height: 8),
              Text(
                '+${widget.engine.breakEngine.debugSimulatedOffset.inMinutes} min simulated',
                key: const Key('debug_simulated_offset'),
                style: const TextStyle(color: Color(0xFFB9A3FF)),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('btn_simulate_45m'),
                  onPressed: () {
                    widget.engine.debugSimulateContinuousListening(
                      const Duration(minutes: 45),
                    );
                    setState(() {});
                  },
                  child: const Text('+45 min'),
                ),
                OutlinedButton(
                  key: const Key('btn_simulate_15m'),
                  onPressed: () {
                    widget.engine.debugSimulateContinuousListening(
                      const Duration(minutes: 15),
                    );
                    setState(() {});
                  },
                  child: const Text('+15 min'),
                ),
                OutlinedButton(
                  key: const Key('btn_reset_simulation'),
                  onPressed: state.isSimulated
                      ? () {
                          widget.engine.debugResetSimulatedListening();
                          setState(() {});
                        }
                      : null,
                  child: const Text('Reset simulation'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
