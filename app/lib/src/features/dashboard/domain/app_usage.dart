import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:timetrace_app/src/bridge/api.dart';

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

  String get activeLabel {
    final h = activeSeconds ~/ 3600;
    final m = (activeSeconds % 3600) ~/ 60;
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }

  String get idleLabel {
    final m = idleSeconds ~/ 60;
    return '${m}分';
  }

  factory AppUsage.fromDto(AppUsageDto dto) => AppUsage(
        appName: dto.appName,
        activeSeconds: dto.activeSeconds.toInt(),
        idleSeconds: dto.idleSeconds.toInt(),
      );
}
