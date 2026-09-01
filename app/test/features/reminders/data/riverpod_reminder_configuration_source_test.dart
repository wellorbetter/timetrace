import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';
import 'package:timetrace_app/src/features/reminders/data/riverpod_reminder_configuration_source.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

void main() {
  test('missing persisted settings returns fully disabled quiet defaults', () {
    final snapshot = reminderConfigurationFromMemory(
      settings: null,
      rulesState: null,
    );

    expect(snapshot.pomodoro.enabled, isFalse);
    expect(snapshot.appTimeoutEnabled, isFalse);
    expect(snapshot.appTimeoutRules, isEmpty);
    expect(snapshot.rulesRevision, 0);
  });

  test('loaded settings drive Pomodoro while unloaded rules stay disabled', () {
    final snapshot = reminderConfigurationFromMemory(
      settings: _settings,
      rulesState: null,
    );

    expect(snapshot.pomodoro.enabled, isTrue);
    expect(snapshot.pomodoro.focusDuration, const Duration(minutes: 40));
    expect(snapshot.pomodoro.shortBreakDuration, const Duration(minutes: 8));
    expect(snapshot.pomodoro.longBreakDuration, const Duration(minutes: 24));
    expect(snapshot.pomodoro.longBreakInterval, 3);
    expect(snapshot.pomodoro.autoStartNext, isTrue);
    expect(snapshot.pomodoro.notificationsEnabled, isFalse);
    expect(snapshot.pomodoro.soundEnabled, isFalse);
    expect(snapshot.appTimeoutEnabled, isFalse);
  });

  test('loaded rules map from memory with their monotonic revision', () {
    final rulesState = AppTimeoutRulesState(
      rules: const [_rule],
      runningApplications: const [],
      revision: 9,
    );
    final snapshot = reminderConfigurationFromMemory(
      settings: _settings,
      rulesState: rulesState,
    );

    expect(snapshot.appTimeoutEnabled, isTrue);
    expect(snapshot.appTimeoutNotificationsEnabled, isTrue);
    expect(snapshot.appTimeoutNotificationSound, isFalse);
    expect(snapshot.rulesRevision, 9);
    expect(snapshot.appTimeoutRules, const [_rule]);
  });

  test(
    'source reads each input once per tick and caches by identity/revision',
    () {
      var settingsReads = 0;
      var rulesReads = 0;
      var localeReads = 0;
      var settings = _settings;
      var locale = AppLocale.zh;
      var rulesState = AppTimeoutRulesState(
        rules: const [_rule],
        runningApplications: const [],
        revision: 4,
      );
      final source = RiverpodReminderConfigurationSource(
        readSettings: () {
          settingsReads++;
          return settings;
        },
        readRules: () {
          rulesReads++;
          return rulesState;
        },
        readLocale: () {
          localeReads++;
          return locale;
        },
      );

      final first = source.readReminderConfiguration();
      final cached = source.readReminderConfiguration();

      expect(settingsReads, 2);
      expect(rulesReads, 2);
      expect(localeReads, 2);
      expect(first.rulesRevision, 4);
      expect(identical(first, cached), isTrue);

      rulesState = AppTimeoutRulesState(
        rules: const [_rule],
        runningApplications: const [],
        revision: 5,
      );
      final rulesChanged = source.readReminderConfiguration();
      expect(identical(rulesChanged, cached), isFalse);
      expect(rulesChanged.rulesRevision, 5);

      settings = settings.copyWith(
        pomodoro: settings.pomodoro.copyWith(focusMinutes: 41),
      );
      final settingsChanged = source.readReminderConfiguration();
      expect(identical(settingsChanged, rulesChanged), isFalse);
      expect(
        settingsChanged.pomodoro.focusDuration,
        const Duration(minutes: 41),
      );
      expect(settingsReads, 4);
      expect(rulesReads, 4);

      locale = AppLocale.en;
      final localeChanged = source.readReminderConfiguration();
      expect(localeChanged.locale, AppLocale.en);
      expect(identical(localeChanged, settingsChanged), isFalse);
      expect(localeReads, 5);
    },
  );
}

const _settings = AppSettings(
  pollIntervalMs: 1000,
  idleThresholdMinutes: 5,
  minimizeToTray: true,
  startMinimized: false,
  autoStartTracking: true,
  excludedApps: [],
  dbPath: '',
  pomodoro: PomodoroSettings(
    enabled: true,
    focusMinutes: 40,
    shortBreakMinutes: 8,
    longBreakMinutes: 24,
    longBreakInterval: 3,
    autoStartNext: true,
    notificationsEnabled: false,
    notificationSound: false,
  ),
  appTimeout: AppTimeoutSettings(
    enabled: true,
    defaultThresholdMinutes: 70,
    defaultCooldownMinutes: 25,
    notificationsEnabled: true,
    notificationSound: false,
  ),
);

const _rule = AppTimeoutRule(
  id: 1,
  executablePath: r'c:\apps\alpha.exe',
  displayName: 'Alpha',
  threshold: Duration(minutes: 70),
  cooldown: Duration(minutes: 25),
  enabled: true,
  repeatEnabled: true,
);
