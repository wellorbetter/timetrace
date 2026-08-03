import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';

/// App settings persisted via the Rust bridge (AppConfig.json).
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    required int pollIntervalMs,
    required int idleThresholdMinutes,
    required List<String> excludedApps,
    required String dbPath,
  }) = _AppSettings;

  const AppSettings._();

  factory AppSettings.defaults() => const AppSettings(
        pollIntervalMs: 1000,
        idleThresholdMinutes: 5,
        excludedApps: [],
        dbPath: '',
      );
}
