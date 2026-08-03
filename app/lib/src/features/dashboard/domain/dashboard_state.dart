import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:timetrace_app/src/core/format.dart';

part 'dashboard_state.freezed.dart';

/// Immutable dashboard state combining usage split + overall stats.
@freezed
abstract class DashboardState with _$DashboardState {
  const factory DashboardState({
    required List<AppUsageItem> apps,
    required int totalActiveSeconds,
    required int totalIdleSeconds,
    required int lifetimeSeconds,
    @Default(0) int thisWeekSeconds,
    @Default(0) int lastWeekSeconds,
    String? since,
  }) = _DashboardState;

  const DashboardState._();

  String get totalActiveLabel => formatDuration(totalActiveSeconds);
}

@freezed
abstract class AppUsageItem with _$AppUsageItem {
  const factory AppUsageItem({
    required String appName,
    required int activeSeconds,
    required int idleSeconds,
    String? exePath,
  }) = _AppUsageItem;

  const AppUsageItem._();

  int get totalSeconds => activeSeconds + idleSeconds;

  String get activeLabel => formatDuration(activeSeconds);

  String get idleLabel {
    final m = idleSeconds ~/ 60;
    return '${m}分';
  }
}
