import 'break_state.dart';

/// Configuration and persistence model for user-defined break reminder preferences.
class BreakReminderSettings {
  /// Whether break reminders are actively monitored and dispatched.
  final bool enabled;

  /// Continuous listening duration (in minutes) before triggering a break reminder.
  /// Allowed range: 15 to 120 minutes. Default: 45 minutes.
  final int intervalMinutes;

  /// Duration (in minutes) to snooze when the user snoozes a reminder.
  /// Allowed choices: 5, 10, or 15 minutes. Default: 10 minutes.
  final int snoozeMinutes;

  const BreakReminderSettings({
    this.enabled = true,
    this.intervalMinutes = defaultIntervalMinutes,
    this.snoozeMinutes = defaultSnoozeMinutes,
  });

  static const int defaultIntervalMinutes = 45;
  static const int defaultSnoozeMinutes = 10;
  static const int minIntervalMinutes = 15;
  static const int maxIntervalMinutes = 120;

  static const List<int> quickIntervals = [30, 45, 60];
  static const List<int> snoozeChoices = [5, 10, 15];

  /// Validates whether a custom interval is within the supported bounds (15-120 minutes).
  static bool isValidInterval(int minutes) =>
      minutes >= minIntervalMinutes && minutes <= maxIntervalMinutes;

  /// Validates whether a snooze choice is supported (5, 10, or 15 minutes).
  static bool isValidSnooze(int minutes) => snoozeChoices.contains(minutes);

  /// Converts user settings into the deterministic [BreakRuleConfig] used by [BreakEngine].
  BreakRuleConfig toBreakRuleConfig() {
    return BreakRuleConfig(
      enabled: enabled,
      breakSoonThreshold: Duration(minutes: intervalMinutes),
      breakRecommendedThreshold: Duration(minutes: intervalMinutes + 15),
      snoozeDuration: Duration(minutes: snoozeMinutes),
    );
  }

  Map<String, dynamic> toMap() => {
    'enabled': enabled ? 1 : 0,
    'interval_minutes': intervalMinutes,
    'snooze_minutes': snoozeMinutes,
  };

  Map<String, dynamic> toJson() => toMap();

  factory BreakReminderSettings.fromMap(Map<String, dynamic> map) {
    final rawInterval = map['interval_minutes'] as int? ?? defaultIntervalMinutes;
    final clampedInterval = rawInterval.clamp(minIntervalMinutes, maxIntervalMinutes);
    final rawSnooze = map['snooze_minutes'] as int? ?? defaultSnoozeMinutes;
    final validSnooze = snoozeChoices.contains(rawSnooze) ? rawSnooze : defaultSnoozeMinutes;

    return BreakReminderSettings(
      enabled: (map['enabled'] as int? ?? 1) == 1,
      intervalMinutes: clampedInterval,
      snoozeMinutes: validSnooze,
    );
  }

  factory BreakReminderSettings.fromJson(Map<String, dynamic> json) =>
      BreakReminderSettings.fromMap(json);

  BreakReminderSettings copyWith({
    bool? enabled,
    int? intervalMinutes,
    int? snoozeMinutes,
  }) {
    return BreakReminderSettings(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BreakReminderSettings &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          intervalMinutes == other.intervalMinutes &&
          snoozeMinutes == other.snoozeMinutes;

  @override
  int get hashCode =>
      enabled.hashCode ^ intervalMinutes.hashCode ^ snoozeMinutes.hashCode;

  @override
  String toString() =>
      'BreakReminderSettings(enabled: $enabled, interval: ${intervalMinutes}m, snooze: ${snoozeMinutes}m)';
}
