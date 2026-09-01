import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

typedef PersistedSettingsReader = AppSettings? Function();
typedef AppTimeoutRulesStateReader = AppTimeoutRulesState? Function();
typedef ReminderLocaleReader = AppLocale Function();

/// Reads only already-loaded Riverpod memory projections on every tick.
///
/// JSON and SQLite access belong to the owning notifiers' one-time loads.
final class RiverpodReminderConfigurationSource
    implements ReminderConfigurationSource {
  RiverpodReminderConfigurationSource({
    required PersistedSettingsReader readSettings,
    required AppTimeoutRulesStateReader readRules,
    required ReminderLocaleReader readLocale,
  }) : _readSettings = readSettings,
       _readRules = readRules,
       _readLocale = readLocale;

  final PersistedSettingsReader _readSettings;
  final AppTimeoutRulesStateReader _readRules;
  final ReminderLocaleReader _readLocale;
  AppSettings? _settingsIdentity;
  int? _rulesRevision;
  AppLocale? _locale;
  ReminderConfigurationSnapshot? _cachedSnapshot;
  bool _hasCachedSnapshot = false;

  @override
  ReminderConfigurationSnapshot readReminderConfiguration() {
    final settings = _readSettings();
    final rulesState = _readRules();
    final rulesRevision = rulesState?.revision;
    final locale = _readLocale();
    if (_hasCachedSnapshot &&
        identical(settings, _settingsIdentity) &&
        rulesRevision == _rulesRevision &&
        locale == _locale) {
      return _cachedSnapshot!;
    }

    final snapshot = reminderConfigurationFromMemory(
      settings: settings,
      rulesState: rulesState,
      locale: locale,
    );
    _settingsIdentity = settings;
    _rulesRevision = rulesRevision;
    _locale = locale;
    _cachedSnapshot = snapshot;
    _hasCachedSnapshot = true;
    return snapshot;
  }
}

/// Maps loaded settings/rules to one internally consistent runtime snapshot.
ReminderConfigurationSnapshot reminderConfigurationFromMemory({
  required AppSettings? settings,
  required AppTimeoutRulesState? rulesState,
  AppLocale locale = AppLocale.zh,
}) {
  if (settings == null) {
    return ReminderConfigurationSnapshot.disabled(locale: locale);
  }

  final pomodoro = settings.pomodoro;
  final appTimeout = settings.appTimeout;
  final rulesLoaded = rulesState != null;
  return ReminderConfigurationSnapshot(
    pomodoro: PomodoroConfig(
      enabled: pomodoro.enabled,
      focusDuration: Duration(minutes: pomodoro.focusMinutes),
      shortBreakDuration: Duration(minutes: pomodoro.shortBreakMinutes),
      longBreakDuration: Duration(minutes: pomodoro.longBreakMinutes),
      longBreakInterval: pomodoro.longBreakInterval,
      autoStartNext: pomodoro.autoStartNext,
      notificationsEnabled: pomodoro.notificationsEnabled,
      soundEnabled: pomodoro.notificationSound,
    ),
    appTimeoutEnabled: rulesLoaded && appTimeout.enabled,
    appTimeoutNotificationsEnabled: appTimeout.notificationsEnabled,
    appTimeoutNotificationSound: appTimeout.notificationSound,
    rulesRevision: rulesState?.revision ?? 0,
    appTimeoutRules: rulesState?.rules ?? const [],
    locale: locale,
  );
}
