import 'package:timetrace_app/src/core/i18n/l10n.dart';

import '../../app_limits/domain/activity_snapshot.dart';
import '../../app_limits/domain/continuous_use.dart';
import '../../focus/domain/pomodoro.dart';

/// Supplies one privacy-minimal activity projection to the reminder runtime.
abstract interface class ActivitySnapshotSource {
  ActivitySnapshot readActivitySnapshot();
}

/// An immutable, internally consistent view of all persisted reminder inputs.
final class ReminderConfigurationSnapshot {
  ReminderConfigurationSnapshot({
    required this.pomodoro,
    required this.appTimeoutEnabled,
    required this.appTimeoutNotificationsEnabled,
    required this.appTimeoutNotificationSound,
    required this.rulesRevision,
    this.locale = AppLocale.zh,
    List<AppTimeoutRule> appTimeoutRules = const [],
  }) : appTimeoutRules = List.unmodifiable(appTimeoutRules);

  factory ReminderConfigurationSnapshot.disabled({
    AppLocale locale = AppLocale.zh,
  }) {
    return ReminderConfigurationSnapshot(
      pomodoro: const PomodoroConfig(),
      appTimeoutEnabled: false,
      appTimeoutNotificationsEnabled: true,
      appTimeoutNotificationSound: true,
      rulesRevision: 0,
      locale: locale,
    );
  }

  final PomodoroConfig pomodoro;
  final bool appTimeoutEnabled;
  final bool appTimeoutNotificationsEnabled;
  final bool appTimeoutNotificationSound;
  final int rulesRevision;
  final List<AppTimeoutRule> appTimeoutRules;
  final AppLocale locale;
}

/// Supplies one atomic settings-plus-rules snapshot per runtime tick.
abstract interface class ReminderConfigurationSource {
  ReminderConfigurationSnapshot readReminderConfiguration();
}
