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
    final c = api.getConfig();
    return AppSettings(
      pollIntervalMs: c.pollIntervalMs.toInt(),
      idleThresholdMinutes: c.idleThresholdMinutes.toInt(),
      minimizeToTray: c.minimizeToTray,
      startMinimized: c.startMinimized,
      autoStartTracking: c.autoStartTracking,
      excludedApps: c.excludedApps,
      dbPath: c.dbPath,
    );
  }

  /// Update a field in memory (UI preview) — persist on save.
  void preview(AppSettings next) => state = AsyncData(next);

  /// Persist to Rust config.
  Future<void> save() async {
    final s = state.value;
    if (s == null) return;
    final api = ref.read(apiProvider);
    api.setConfig(
      config: ConfigDto(
        pollIntervalMs: BigInt.from(s.pollIntervalMs),
        idleThresholdMinutes: BigInt.from(s.idleThresholdMinutes),
        minimizeToTray: s.minimizeToTray,
        startMinimized: s.startMinimized,
        autoStartTracking: s.autoStartTracking,
        excludedApps: s.excludedApps,
        dbPath: s.dbPath,
      ),
    );
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
