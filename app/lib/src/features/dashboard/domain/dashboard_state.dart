import 'package:freezed_annotation/freezed_annotation.dart';

part 'dashboard_state.freezed.dart';

/// Immutable dashboard state combining usage split + overall stats.
@freezed
abstract class DashboardState with _$DashboardState {
  const factory DashboardState({
    required List<AppUsageItem> apps,
    required int totalActiveSeconds,
    required int totalIdleSeconds,
    required int lifetimeSeconds,
    String? since,
  }) = _DashboardState;

  const DashboardState._();

  String get totalActiveLabel {
    final h = totalActiveSeconds ~/ 3600;
    final m = (totalActiveSeconds % 3600) ~/ 60;
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }
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

  String get activeLabel {
    final h = activeSeconds ~/ 3600;
    final m = (activeSeconds % 3600) ~/ 60;
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }

  String get idleLabel {
    final m = idleSeconds ~/ 60;
    return '${m}分';
  }
}
