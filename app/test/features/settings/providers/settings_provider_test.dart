import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

void main() {
  test('nested reminder settings round-trip without losing legacy fields', () {
    final settings = appSettingsFromDto(_configDto);

    expect(settings.pollIntervalMs, 1500);
    expect(settings.excludedApps, const ['secret.exe']);
    expect(settings.pomodoro.enabled, isTrue);
    expect(settings.pomodoro.focusMinutes, 50);
    expect(settings.pomodoro.longBreakInterval, 3);
    expect(settings.pomodoro.notificationSound, isFalse);
    expect(settings.appTimeout.enabled, isTrue);
    expect(settings.appTimeout.defaultThresholdMinutes, 75);
    expect(settings.appTimeout.defaultCooldownMinutes, 20);

    final roundTrip = appSettingsToDto(settings);
    expect(roundTrip.pollIntervalMs, BigInt.from(1500));
    expect(roundTrip.idleThresholdMinutes, BigInt.from(7));
    expect(roundTrip.minimizeToTray, isFalse);
    expect(roundTrip.startMinimized, isTrue);
    expect(roundTrip.autoStartTracking, isFalse);
    expect(roundTrip.excludedApps, const ['secret.exe']);
    expect(roundTrip.dbPath, r'd:\data\time.db');
    expect(roundTrip.pomodoro, _configDto.pomodoro);
    expect(roundTrip.appTimeout, _configDto.appTimeout);
  });

  test(
    'preview stays draft while save updates persisted runtime state',
    () async {
      final api = _FakeApi(_configDto);
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final loaded = await container.read(settingsProvider.future);
      expect(container.read(persistedSettingsProvider), loaded);

      final draft = loaded.copyWith(
        pomodoro: loaded.pomodoro.copyWith(focusMinutes: 90),
      );
      container.read(settingsProvider.notifier).preview(draft);
      expect(container.read(settingsProvider).value, draft);
      expect(container.read(persistedSettingsProvider), loaded);
      expect(api.setCalls, 0);

      await container.read(settingsProvider.notifier).save();
      expect(api.setCalls, 1);
      expect(container.read(persistedSettingsProvider), draft);
      expect(api.savedConfig!.pomodoro.focusMinutes, BigInt.from(90));

      final immediate = draft.copyWith(
        appTimeout: draft.appTimeout.copyWith(enabled: false),
      );
      await container.read(settingsProvider.notifier).previewAndSave(immediate);
      expect(api.setCalls, 2);
      expect(container.read(persistedSettingsProvider), immediate);
      expect(api.savedConfig!.appTimeout.enabled, isFalse);
    },
  );
}

final _configDto = ConfigDto(
  pollIntervalMs: BigInt.from(1500),
  idleThresholdMinutes: BigInt.from(7),
  minimizeToTray: false,
  startMinimized: true,
  autoStartTracking: false,
  excludedApps: ['secret.exe'],
  dbPath: r'd:\data\time.db',
  pomodoro: PomodoroConfigDto(
    enabled: true,
    focusMinutes: BigInt.from(50),
    shortBreakMinutes: BigInt.from(10),
    longBreakMinutes: BigInt.from(30),
    longBreakInterval: BigInt.from(3),
    autoStartNext: true,
    notificationsEnabled: true,
    notificationSound: false,
  ),
  appTimeout: AppTimeoutConfigDto(
    enabled: true,
    defaultThresholdMinutes: BigInt.from(75),
    defaultCooldownMinutes: BigInt.from(20),
    notificationsEnabled: false,
    notificationSound: true,
  ),
);

final class _FakeApi implements TimeTraceApi {
  _FakeApi(this.config);

  final ConfigDto config;
  ConfigDto? savedConfig;
  int setCalls = 0;

  @override
  ConfigDto getConfig() => config;

  @override
  void setConfig({required ConfigDto config}) {
    setCalls++;
    savedConfig = config;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
