import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/format.dart';

part 'app_usage.freezed.dart';

/// Domain model wrapping the FRB DTO with UI-computed getters.
@freezed
abstract class AppUsage with _$AppUsage {
  const factory AppUsage({
    required String appName,
    required int activeSeconds,
    required int idleSeconds,
  }) = _AppUsage;

  const AppUsage._();

  int get totalSeconds => activeSeconds + idleSeconds;

  String get activeLabel => formatDuration(activeSeconds);

  String get idleLabel => formatDuration(idleSeconds);

  factory AppUsage.fromDto(AppUsageDto dto) => AppUsage(
        appName: dto.appName,
        activeSeconds: dto.activeSeconds.toInt(),
        idleSeconds: dto.idleSeconds.toInt(),
      );
}
