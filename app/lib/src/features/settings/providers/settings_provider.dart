import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

class SettingsWriteIntent {
  const SettingsWriteIntent(
    this.id,
    this.target, {
    this.group = 'config',
    this.verified = false,
    this.failed = false,
  });
  final int id;
  final AppSettings target;
  final bool verified, failed;
  final String group;
}

class SettingsWriteFeedback extends Notifier<SettingsWriteIntent?> {
  @override
  SettingsWriteIntent? build() => null;
  void set(SettingsWriteIntent intent) => state = intent;
}

final settingsWriteFeedbackProvider =
    NotifierProvider<SettingsWriteFeedback, SettingsWriteIntent?>(
      SettingsWriteFeedback.new,
    );

/// Settings loaded from the Rust config.
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  int _generation = 0;
  @override
  Future<AppSettings> build() => _load();

  Future<AppSettings> _load() async {
    final api = ref.read(apiProvider);
    final c = api.getConfig();
    return AppSettings(
      // Bound the unsigned DTO before converting to a native Dart int.
      // Loading a legacy value never writes or migrates the raw configuration.
      pollIntervalMs: effectivePollingMilliseconds(
        c.pollIntervalMs < BigInt.from(minimumPollingMilliseconds)
            ? minimumPollingMilliseconds
            : c.pollIntervalMs > BigInt.from(maximumPollingMilliseconds)
            ? maximumPollingMilliseconds
            : c.pollIntervalMs.toInt(),
      ),
      idleThresholdMinutes: c.idleThresholdMinutes.toInt(),
      minimizeToTray: c.minimizeToTray,
      startMinimized: c.startMinimized,
      autoStartTracking: c.autoStartTracking,
      excludedApps: c.excludedApps,
      dbPath: c.dbPath,
    );
  }

  /// Legacy preview remains explicit; it is never a durability acknowledgement.
  void preview(AppSettings next) => state = AsyncData(next);

  Future<void> apply(AppSettings next) async {
    _validatePolling(next);
    final old = state.value;
    final group = old?.pollIntervalMs != next.pollIntervalMs
        ? 'poll'
        : old?.idleThresholdMinutes != next.idleThresholdMinutes
        ? 'idle'
        : old?.excludedApps.toString() != next.excludedApps.toString()
        ? 'excluded'
        : 'startup';
    preview(next);
    await _saveIntent(SettingsWriteIntent(++_generation, next, group: group));
  }

  Future<void> retry() async {
    final intent = ref.read(settingsWriteFeedbackProvider);
    if (intent == null || intent.verified) return;
    await _saveIntent(intent);
  }

  /// Persist to Rust config.
  Future<void> save() async {
    final s = state.value;
    if (s == null) return;
    await _saveIntent(SettingsWriteIntent(++_generation, s));
  }

  Future<void> _saveIntent(SettingsWriteIntent intent) async {
    final s = intent.target;
    ref.read(settingsWriteFeedbackProvider.notifier).set(intent);
    try {
      // save/retry may receive a preview or retained intent that bypassed UI.
      // Reject it before any bridge read/write, never silently normalize it.
      _validatePolling(s);
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
      final verified = await _load();
      if (verified != s) throw StateError('Config readback differs');
      if (ref.mounted &&
          ref.read(settingsWriteFeedbackProvider)?.id == intent.id) {
        ref
            .read(settingsWriteFeedbackProvider.notifier)
            .set(
              SettingsWriteIntent(
                intent.id,
                s,
                group: intent.group,
                verified: true,
              ),
            );
      }
    } catch (_) {
      if (ref.mounted &&
          ref.read(settingsWriteFeedbackProvider)?.id == intent.id) {
        ref
            .read(settingsWriteFeedbackProvider.notifier)
            .set(
              SettingsWriteIntent(
                intent.id,
                s,
                group: intent.group,
                failed: true,
              ),
            );
      }
      rethrow;
    }
  }
  void _validatePolling(AppSettings settings) {
    if (!isValidPollingMilliseconds(settings.pollIntervalMs)) {
      throw ArgumentError.value(
        settings.pollIntervalMs,
        'pollIntervalMs',
        'Must be between 30000 and 60000 milliseconds',
      );
    }
  }
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
