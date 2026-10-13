import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/break_reminder_settings.dart';
import '../session_engine.dart';

/// Screen allowing the user to configure continuous listening break reminders.
///
/// Settings include:
/// 1. Master toggle (enable/disable reminders)
/// 2. Quick intervals (30, 45, 60 min) or validated custom interval (15-120 min)
/// 3. Snooze duration choices (5, 10, 15 min)
/// 4. Live rule preview and background safety guidance
class BreakSettingsView extends StatefulWidget {
  final SessionEngine sessionEngine;

  const BreakSettingsView({super.key, required this.sessionEngine});

  @override
  State<BreakSettingsView> createState() => _BreakSettingsViewState();
}

class _BreakSettingsViewState extends State<BreakSettingsView> {
  bool _isLoading = true;
  bool _enabled = true;
  int _intervalMinutes = BreakReminderSettings.defaultIntervalMinutes;
  int _snoozeMinutes = BreakReminderSettings.defaultSnoozeMinutes;
  bool _isCustomInterval = false;

  late final TextEditingController _customController;
  String? _customError;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController();
    _loadSettings();
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = await widget.sessionEngine.getBreakReminderSettings();
    if (mounted) {
      setState(() {
        _enabled = settings.enabled;
        _intervalMinutes = settings.intervalMinutes;
        _snoozeMinutes = settings.snoozeMinutes;
        _isCustomInterval = !BreakReminderSettings.quickIntervals.contains(_intervalMinutes);
        if (_isCustomInterval) {
          _customController.text = _intervalMinutes.toString();
        }
        _isLoading = false;
      });
    }
  }

  void _onIntervalSelected(int minutes) {
    setState(() {
      _isCustomInterval = false;
      _intervalMinutes = minutes;
      _customError = null;
    });
  }

  void _onCustomSelected() {
    setState(() {
      _isCustomInterval = true;
      if (_customController.text.isEmpty) {
        _customController.text = _intervalMinutes.toString();
      }
    });
  }

  void _validateCustom(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null) {
      setState(() {
        _customError = 'Enter a valid number of minutes';
      });
      return;
    }
    if (parsed < BreakReminderSettings.minIntervalMinutes ||
        parsed > BreakReminderSettings.maxIntervalMinutes) {
      setState(() {
        _customError = 'Must be between ${BreakReminderSettings.minIntervalMinutes} and ${BreakReminderSettings.maxIntervalMinutes} minutes';
      });
      return;
    }
    setState(() {
      _customError = null;
      _intervalMinutes = parsed;
    });
  }

  Future<void> _saveSettings() async {
    if (_isCustomInterval) {
      _validateCustom(_customController.text);
      if (_customError != null) return;
    }

    final newSettings = BreakReminderSettings(
      enabled: _enabled,
      intervalMinutes: _intervalMinutes,
      snoozeMinutes: _snoozeMinutes,
    );

    await widget.sessionEngine.updateBreakReminderSettings(newSettings);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _enabled
                ? 'Break reminder set to $_intervalMinutes minutes'
                : 'Break reminders disabled',
          ),
          backgroundColor: Colors.teal.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('Break Reminder Settings'),
          backgroundColor: Colors.grey.shade900,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Colors.tealAccent),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Break Reminder Settings',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: Colors.grey.shade900,
        elevation: 0,
        actions: [
          IconButton(
            key: const Key('save_break_settings_button'),
            icon: const Icon(Icons.check, color: Colors.tealAccent),
            tooltip: 'Save Settings',
            onPressed: _saveSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Master Toggle
            Card(
              color: Colors.grey.shade900,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: _enabled ? Colors.tealAccent.withValues(alpha: 0.5) : Colors.white12,
                ),
              ),
              child: SwitchListTile(
                key: const Key('break_reminder_enable_switch'),
                value: _enabled,
                onChanged: (val) {
                  setState(() {
                    _enabled = val;
                  });
                },
                activeThumbColor: Colors.tealAccent,
                title: const Text(
                  'Enable Break Reminders',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                subtitle: Text(
                  _enabled
                      ? 'Periodic alerts to protect your hearing during long sessions'
                      : 'Reminders are paused. No notifications will be dispatched.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 20),

            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _enabled ? 1.0 : 0.4,
              child: IgnorePointer(
                ignoring: !_enabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Interval Section Header
                    const Text(
                      'REMINDER INTERVAL',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.tealAccent,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Duration of continuous active audio playback before reminding you to rest.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    ),
                    const SizedBox(height: 12),

                    // Quick Chips & Custom
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ...BreakReminderSettings.quickIntervals.map((mins) {
                          final isSelected = !_isCustomInterval && _intervalMinutes == mins;
                          return ChoiceChip(
                            key: Key('interval_chip_$mins'),
                            label: Text(
                              mins == 45 ? '$mins min (Default)' : '$mins min',
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? Colors.black : Colors.white,
                              ),
                            ),
                            selected: isSelected,
                            selectedColor: Colors.tealAccent,
                            backgroundColor: Colors.grey.shade900,
                            side: BorderSide(
                              color: isSelected ? Colors.tealAccent : Colors.white24,
                            ),
                            onSelected: (selected) {
                              if (selected) _onIntervalSelected(mins);
                            },
                          );
                        }),
                        ChoiceChip(
                          key: const Key('interval_chip_custom'),
                          label: Text(
                            _isCustomInterval ? 'Custom: $_intervalMinutes min' : 'Custom',
                            style: TextStyle(
                              fontWeight: _isCustomInterval ? FontWeight.bold : FontWeight.normal,
                              color: _isCustomInterval ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: _isCustomInterval,
                          selectedColor: Colors.tealAccent,
                          backgroundColor: Colors.grey.shade900,
                          side: BorderSide(
                            color: _isCustomInterval ? Colors.tealAccent : Colors.white24,
                          ),
                          onSelected: (selected) {
                            if (selected) _onCustomSelected();
                          },
                        ),
                      ],
                    ),

                    if (_isCustomInterval) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('custom_interval_field'),
                        controller: _customController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Custom Interval (Minutes)',
                          labelStyle: const TextStyle(color: Colors.tealAccent),
                          helperText: 'Valid range: 15 to 120 minutes',
                          helperStyle: TextStyle(color: Colors.grey.shade400),
                          errorText: _customError,
                          suffixText: 'min',
                          suffixStyle: const TextStyle(color: Colors.tealAccent),
                          filled: true,
                          fillColor: Colors.grey.shade900,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Colors.white24),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Colors.tealAccent),
                          ),
                        ),
                        onChanged: _validateCustom,
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Snooze Duration Section
                    const Text(
                      'SNOOZE DURATION',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.tealAccent,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'When snoozing from the notification or app, delay the next reminder by:',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                    ),
                    const SizedBox(height: 12),

                    Wrap(
                      spacing: 8,
                      children: BreakReminderSettings.snoozeChoices.map((mins) {
                        final isSelected = _snoozeMinutes == mins;
                        return ChoiceChip(
                          key: Key('snooze_chip_$mins'),
                          label: Text(
                            mins == 10 ? '$mins min (Default)' : '$mins min',
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: Colors.amberAccent.shade400,
                          backgroundColor: Colors.grey.shade900,
                          side: BorderSide(
                            color: isSelected ? Colors.amberAccent : Colors.white24,
                          ),
                          onSelected: (selected) {
                            if (selected) {
                              setState(() {
                                _snoozeMinutes = mins;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 24),

                    // Rule Preview Card
                    Card(
                      color: Colors.grey.shade900,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: Colors.white12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.preview_outlined, color: Colors.tealAccent.shade400, size: 18),
                                const SizedBox(width: 8),
                                const Text(
                                  'RULE BEHAVIOR PREVIEW',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    letterSpacing: 1.0,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            const Divider(color: Colors.white12, height: 20),
                            _buildPreviewRow(
                              icon: Icons.notifications_active_outlined,
                              color: Colors.amberAccent.shade400,
                              title: 'First Alert (Break Soon)',
                              description: 'Triggers at $_intervalMinutes minutes of active listening.',
                            ),
                            const SizedBox(height: 10),
                            _buildPreviewRow(
                              icon: Icons.warning_amber_rounded,
                              color: Colors.deepOrangeAccent.shade200,
                              title: 'Urgent Alert (Break Due)',
                              description: 'Triggers at ${_intervalMinutes + 15} minutes if playback continues.',
                            ),
                            const SizedBox(height: 10),
                            _buildPreviewRow(
                              icon: Icons.snooze,
                              color: Colors.lightBlueAccent,
                              title: 'Notification Snooze',
                              description: 'Suppresses alerts for $_snoozeMinutes minutes of continuous listening.',
                            ),
                            const Divider(color: Colors.white12, height: 20),
                            Text(
                              'Guarantees & Invariants:\n'
                              '• Bluetooth connection without audio never increments break time.\n'
                              '• Pauses within the 3-minute grace period preserve session continuity without adding listening time.\n'
                              '• Disconnecting audio peripherals immediately cancels all reminders and resets continuous time to zero.',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade400, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Save Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                key: const Key('save_break_settings_primary_button'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.check, size: 20),
                label: const Text(
                  'SAVE SETTINGS',
                  style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0),
                ),
                onPressed: _saveSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewRow({
    required IconData icon,
    required Color color,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade300,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
