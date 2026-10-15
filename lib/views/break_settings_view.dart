import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
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
        _isCustomInterval = !BreakReminderSettings.quickIntervals.contains(
          _intervalMinutes,
        );
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
        _customError =
            'Must be between ${BreakReminderSettings.minIntervalMinutes} and ${BreakReminderSettings.maxIntervalMinutes} minutes';
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
          backgroundColor: ListeningPalette.mint,
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
        backgroundColor: ListeningPalette.background,
        appBar: AppBar(
          title: const Text('Break Reminder Settings'),
          backgroundColor: ListeningPalette.background,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: ListeningPalette.mint),
        ),
      );
    }

    return Scaffold(
      backgroundColor: ListeningPalette.background,
      appBar: AppBar(
        title: const Text(
          'Break Reminder Settings',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: ListeningPalette.background,
        elevation: 0,
        actions: [
          IconButton(
            key: const Key('save_break_settings_button'),
            icon: const Icon(Icons.check, color: ListeningPalette.mint),
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
              color: ListeningPalette.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: _enabled
                      ? ListeningPalette.mint.withValues(alpha: 0.35)
                      : ListeningPalette.separator,
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
                activeThumbColor: ListeningPalette.mint,
                title: const Text(
                  'Enable Break Reminders',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
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
                      'Reminder interval',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: ListeningPalette.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Duration of continuous active audio playback before reminding you to rest.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Quick Chips & Custom
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ...BreakReminderSettings.quickIntervals.map((mins) {
                          final isSelected =
                              !_isCustomInterval && _intervalMinutes == mins;
                          return ChoiceChip(
                            key: Key('interval_chip_$mins'),
                            label: Text(
                              mins == 45 ? '$mins min (Default)' : '$mins min',
                              softWrap: false,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isSelected ? Colors.black : Colors.white,
                              ),
                            ),
                            selected: isSelected,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            selectedColor: ListeningPalette.mint,
                            backgroundColor: ListeningPalette.surface,
                            side: BorderSide(
                              color: isSelected
                                  ? ListeningPalette.mint
                                  : Colors.white24,
                            ),
                            onSelected: (selected) {
                              if (selected) _onIntervalSelected(mins);
                            },
                          );
                        }),
                        ChoiceChip(
                          key: const Key('interval_chip_custom'),
                          label: Text(
                            _isCustomInterval
                                ? 'Custom: $_intervalMinutes min'
                                : 'Custom',
                            softWrap: false,
                            style: TextStyle(
                              fontWeight: _isCustomInterval
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: _isCustomInterval
                                  ? Colors.black
                                  : Colors.white,
                            ),
                          ),
                          selected: _isCustomInterval,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          selectedColor: ListeningPalette.mint,
                          backgroundColor: ListeningPalette.surface,
                          side: BorderSide(
                            color: _isCustomInterval
                                ? ListeningPalette.mint
                                : Colors.white24,
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
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Custom Interval (Minutes)',
                          labelStyle: const TextStyle(
                            color: ListeningPalette.mint,
                          ),
                          helperText: 'Valid range: 15 to 120 minutes',
                          helperStyle: TextStyle(color: Colors.grey.shade400),
                          errorText: _customError,
                          suffixText: 'min',
                          suffixStyle: const TextStyle(
                            color: ListeningPalette.mint,
                          ),
                          filled: true,
                          fillColor: ListeningPalette.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Colors.white24),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: ListeningPalette.mint,
                            ),
                          ),
                        ),
                        onChanged: _validateCustom,
                      ),
                    ],

                    if (_intervalGuidance case final guidance?) ...[
                      const SizedBox(height: 12),
                      Container(
                        key: const Key('break_interval_guidance'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: ListeningPalette.surfaceRaised,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: ListeningPalette.mint.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline,
                              color: ListeningPalette.mint,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                guidance,
                                style: TextStyle(
                                  color: Colors.grey.shade200,
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    // Snooze Duration Section
                    const Text(
                      'Snooze duration',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: ListeningPalette.text,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'When snoozing from the notification or app, delay the next reminder by:',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(height: 12),

                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: BreakReminderSettings.snoozeChoices.map((mins) {
                        final isSelected = _snoozeMinutes == mins;
                        return ChoiceChip(
                          key: Key('snooze_chip_$mins'),
                          label: Text(
                            mins == 10 ? '$mins min (Default)' : '$mins min',
                            softWrap: false,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: isSelected,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          selectedColor: ListeningPalette.amber,
                          backgroundColor: ListeningPalette.surface,
                          side: BorderSide(
                            color: isSelected
                                ? ListeningPalette.amber
                                : Colors.white24,
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
                      color: ListeningPalette.surface,
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
                                Icon(
                                  Icons.preview_outlined,
                                  color: ListeningPalette.mint,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'How reminders work',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      color: ListeningPalette.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(color: Colors.white12, height: 20),
                            _buildPreviewRow(
                              icon: Icons.notifications_active_outlined,
                              color: ListeningPalette.amber,
                              title: 'First Alert (Break Soon)',
                              description:
                                  'Triggers at $_intervalMinutes minutes of active listening.',
                            ),
                            const SizedBox(height: 10),
                            _buildPreviewRow(
                              icon: Icons.warning_amber_rounded,
                              color: Colors.deepOrangeAccent.shade200,
                              title: 'Urgent Alert (Break Due)',
                              description:
                                  'Triggers at ${_intervalMinutes + 15} minutes if playback continues.',
                            ),
                            const SizedBox(height: 10),
                            _buildPreviewRow(
                              icon: Icons.snooze,
                              color: Colors.lightBlueAccent,
                              title: 'Notification Snooze',
                              description:
                                  'Suppresses alerts for $_snoozeMinutes minutes of continuous listening.',
                            ),
                            const SizedBox(height: 8),
                            Theme(
                              data: Theme.of(context)
                                  .copyWith(dividerColor: Colors.transparent),
                              child: ExpansionTile(
                                key: const Key('break_session_guarantees'),
                                tilePadding: EdgeInsets.zero,
                                childrenPadding: const EdgeInsets.only(
                                  bottom: 12,
                                ),
                                title: const Text(
                                  'Session guarantees',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                children: [
                                  Text(
                                    'Bluetooth connection without audio never increments break time. Pauses within the 3-minute grace period preserve session continuity without adding listening time. Disconnecting audio peripherals immediately cancels all reminders and resets continuous time to zero.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: ListeningPalette.muted,
                                      height: 1.55,
                                    ),
                                  ),
                                ],
                              ),
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
                  backgroundColor: ListeningPalette.mint,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.check, size: 20),
                label: const Text(
                  'SAVE SETTINGS',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
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
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade300,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? get _intervalGuidance {
    if (_intervalMinutes > 60) {
      return 'A longer interval delays your reminder. Consider 45–60 minutes for more regular prompts; you can still save your chosen interval.';
    }
    if (_intervalMinutes >= 60) {
      return 'At 60 minutes, consider taking a short break when your reminder appears.';
    }
    if (_intervalMinutes >= 45) {
      return 'Around 45 minutes, consider taking a break soon when your reminder appears.';
    }
    return null;
  }
}
