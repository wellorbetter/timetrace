import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/format.dart';

part 'dashboard_state.freezed.dart';

/// A projection of one canonical Rust accounting snapshot.
@freezed
abstract class DashboardState with _$DashboardState {
  const factory DashboardState({
    required List<AppUsageItem> apps,
    required List<AttributionTotalDto> appAttribution,
    required List<AttributionTotalDto> windows,
    required List<AttributionTotalDto> pages,
    required List<LocalHourBucketDto> hours,
    required int totalActiveSeconds,
    required int totalIdleSeconds,
    required int pausedSeconds,
    required int privacyExcludedSeconds,
    required int systemGapSeconds,
    required int unknownSeconds,
    required int accountedSeconds,
    required SnapshotIntegrityDto integrity,
    required String requestedStartUtc,
    required String requestedEndUtc,
    required String effectiveStartUtc,
    required String effectiveEndUtc,
    required String observedThroughUtc,
    @Default(false) bool databaseDegraded,
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
    return '$m分';
  }
}
