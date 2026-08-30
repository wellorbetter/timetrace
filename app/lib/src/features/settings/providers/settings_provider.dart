import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

/// Settings loaded from the Rust config.
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => _load();

  Future<AppSettings> _load() async {
    final api = ref.read(apiProvider);
    final settings = appSettingsFromDto(api.getConfig());
    // Provider initialization may not synchronously mutate another provider.
    // Yield once, then publish the successfully loaded persisted projection.
    await Future<void>.value();
    if (ref.mounted) {
      ref.read(persistedSettingsProvider.notifier).replace(settings);
    }
    return settings;
  }

  /// Update a field in memory (UI preview) — persist on save.
  void preview(AppSettings next) => state = AsyncData(next);

  /// Persist to Rust config.
  Future<void> save() async {
    final s = state.value;
    if (s == null) return;
    _persist(s);
  }

  /// Preview and immediately persist a reminder-sensitive settings change.
  ///
  /// The runtime consumes [persistedSettingsProvider], so an unsaved call to
  /// [preview] can never reconfigure countdowns or notification delivery.
  Future<void> previewAndSave(AppSettings next) async {
    preview(next);
    _persist(next);
  }

  void _persist(AppSettings settings) {
    final api = ref.read(apiProvider);
    api.setConfig(config: appSettingsToDto(settings));
    ref.read(persistedSettingsProvider.notifier).replace(settings);
  }
}

/// Maps the generated bridge contract into the immutable Flutter model.
AppSettings appSettingsFromDto(ConfigDto config) {
  return AppSettings(
    pollIntervalMs: config.pollIntervalMs.toInt(),
    idleThresholdMinutes: config.idleThresholdMinutes.toInt(),
    minimizeToTray: config.minimizeToTray,
    startMinimized: config.startMinimized,
    autoStartTracking: config.autoStartTracking,
    excludedApps: config.excludedApps,
    dbPath: config.dbPath,
    pomodoro: PomodoroSettings(
      enabled: config.pomodoro.enabled,
      focusMinutes: config.pomodoro.focusMinutes.toInt(),
      shortBreakMinutes: config.pomodoro.shortBreakMinutes.toInt(),
      longBreakMinutes: config.pomodoro.longBreakMinutes.toInt(),
      longBreakInterval: config.pomodoro.longBreakInterval.toInt(),
      autoStartNext: config.pomodoro.autoStartNext,
      notificationsEnabled: config.pomodoro.notificationsEnabled,
      notificationSound: config.pomodoro.notificationSound,
    ),
    appTimeout: AppTimeoutSettings(
      enabled: config.appTimeout.enabled,
      defaultThresholdMinutes: config.appTimeout.defaultThresholdMinutes
          .toInt(),
      defaultCooldownMinutes: config.appTimeout.defaultCooldownMinutes.toInt(),
      notificationsEnabled: config.appTimeout.notificationsEnabled,
      notificationSound: config.appTimeout.notificationSound,
    ),
  );
}

/// Maps all legacy and nested settings back to the generated bridge contract.
ConfigDto appSettingsToDto(AppSettings settings) {
  return ConfigDto(
    pollIntervalMs: BigInt.from(settings.pollIntervalMs),
    idleThresholdMinutes: BigInt.from(settings.idleThresholdMinutes),
    minimizeToTray: settings.minimizeToTray,
    startMinimized: settings.startMinimized,
    autoStartTracking: settings.autoStartTracking,
    excludedApps: settings.excludedApps,
    dbPath: settings.dbPath,
    pomodoro: PomodoroConfigDto(
      enabled: settings.pomodoro.enabled,
      focusMinutes: BigInt.from(settings.pomodoro.focusMinutes),
      shortBreakMinutes: BigInt.from(settings.pomodoro.shortBreakMinutes),
      longBreakMinutes: BigInt.from(settings.pomodoro.longBreakMinutes),
      longBreakInterval: BigInt.from(settings.pomodoro.longBreakInterval),
      autoStartNext: settings.pomodoro.autoStartNext,
      notificationsEnabled: settings.pomodoro.notificationsEnabled,
      notificationSound: settings.pomodoro.notificationSound,
    ),
    appTimeout: AppTimeoutConfigDto(
      enabled: settings.appTimeout.enabled,
      defaultThresholdMinutes: BigInt.from(
        settings.appTimeout.defaultThresholdMinutes,
      ),
      defaultCooldownMinutes: BigInt.from(
        settings.appTimeout.defaultCooldownMinutes,
      ),
      notificationsEnabled: settings.appTimeout.notificationsEnabled,
      notificationSound: settings.appTimeout.notificationSound,
    ),
  );
}

/// Last successfully persisted settings, separate from unsaved UI previews.
class PersistedSettingsNotifier extends Notifier<AppSettings?> {
  @override
  AppSettings? build() => null;

  void replace(AppSettings settings) => state = settings;
}

final persistedSettingsProvider =
    NotifierProvider<PersistedSettingsNotifier, AppSettings?>(
      PersistedSettingsNotifier.new,
    );

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
