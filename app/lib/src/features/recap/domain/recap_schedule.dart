enum RecapScheduleCadence { off, daily, weekly }

class RecapScheduleSettings {
  const RecapScheduleSettings({
    this.cadence = RecapScheduleCadence.off,
    this.hour = 22,
    this.minute = 0,
    this.weekday = DateTime.sunday,
    this.notify = true,
    this.lastRunKey,
  });

  final RecapScheduleCadence cadence;
  final int hour;
  final int minute;
  final int weekday;
  final bool notify;

  /// Internal de-duplication marker persisted with the schedule. Daily runs
  /// use YYYY-MM-DD; weekly runs use YYYY-Www.
  final String? lastRunKey;

  bool get enabled => cadence != RecapScheduleCadence.off;

  RecapScheduleSettings copyWith({
    RecapScheduleCadence? cadence,
    int? hour,
    int? minute,
    int? weekday,
    bool? notify,
    String? lastRunKey,
    bool clearLastRunKey = false,
  }) =>
      RecapScheduleSettings(
        cadence: cadence ?? this.cadence,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        weekday: weekday ?? this.weekday,
        notify: notify ?? this.notify,
        lastRunKey: clearLastRunKey ? null : (lastRunKey ?? this.lastRunKey),
      );

  Map<String, Object?> toJson() => {
        'cadence': cadence.name,
        'hour': hour,
        'minute': minute,
        'weekday': weekday,
        'notify': notify,
        'last_run_key': lastRunKey,
      };

  factory RecapScheduleSettings.fromJson(Map<String, Object?> json) {
    final cadenceName = json['cadence'] as String?;
    final cadence = RecapScheduleCadence.values.where((e) => e.name == cadenceName).firstOrNull ?? RecapScheduleCadence.off;
    return RecapScheduleSettings(
      cadence: cadence,
      hour: (json['hour'] as num?)?.toInt().clamp(0, 23) ?? 22,
      minute: (json['minute'] as num?)?.toInt().clamp(0, 59) ?? 0,
      weekday: (json['weekday'] as num?)?.toInt().clamp(DateTime.monday, DateTime.sunday) ?? DateTime.sunday,
      notify: json['notify'] as bool? ?? true,
      lastRunKey: json['last_run_key'] as String?,
    );
  }
}
