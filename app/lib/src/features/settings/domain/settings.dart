import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';

/// Persisted Pomodoro preferences. Runtime countdown state is deliberately
/// transient and always starts idle after an application restart.
@freezed
abstract class PomodoroSettings with _$PomodoroSettings {
  const factory PomodoroSettings({
    required bool enabled,
    required int focusMinutes,
    required int shortBreakMinutes,
    required int longBreakMinutes,
    required int longBreakInterval,
    required bool autoStartNext,
    required bool notificationsEnabled,
    required bool notificationSound,
  }) = _PomodoroSettings;

  const PomodoroSettings._();

  factory PomodoroSettings.defaults() => const PomodoroSettings(
    enabled: false,
    focusMinutes: 25,
    shortBreakMinutes: 5,
    longBreakMinutes: 15,
    longBreakInterval: 4,
    autoStartNext: false,
    notificationsEnabled: true,
    notificationSound: true,
  );
}

/// Global application continuous-use reminder preferences. Executable-specific
/// rules are stored separately in SQLite.
@freezed
abstract class AppTimeoutSettings with _$AppTimeoutSettings {
  const factory AppTimeoutSettings({
    required bool enabled,
    required int defaultThresholdMinutes,
    required int defaultCooldownMinutes,
    required bool notificationsEnabled,
    required bool notificationSound,
  }) = _AppTimeoutSettings;

  const AppTimeoutSettings._();

  factory AppTimeoutSettings.defaults() => const AppTimeoutSettings(
    enabled: false,
    defaultThresholdMinutes: 60,
    defaultCooldownMinutes: 30,
    notificationsEnabled: true,
    notificationSound: true,
  );
}

/// App settings persisted via the Rust bridge (AppConfig.json).
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    required int pollIntervalMs,
    required int idleThresholdMinutes,
    required bool minimizeToTray,
    required bool startMinimized,
    required bool autoStartTracking,
    required List<String> excludedApps,
    required String dbPath,
    required PomodoroSettings pomodoro,
    required AppTimeoutSettings appTimeout,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.defaults() => const AppSettings(
    pollIntervalMs: 1000,
    idleThresholdMinutes: 5,
    minimizeToTray: true,
    startMinimized: false,
    autoStartTracking: true,
    excludedApps: [],
    dbPath: '',
    pomodoro: PomodoroSettings(
      enabled: false,
      focusMinutes: 25,
      shortBreakMinutes: 5,
      longBreakMinutes: 15,
      longBreakInterval: 4,
      autoStartNext: false,
      notificationsEnabled: true,
      notificationSound: true,
    ),
    appTimeout: AppTimeoutSettings(
      enabled: false,
      defaultThresholdMinutes: 60,
      defaultCooldownMinutes: 30,
      notificationsEnabled: true,
      notificationSound: true,
    ),
  );
}
