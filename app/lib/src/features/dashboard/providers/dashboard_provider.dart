import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';

/// Supported date ranges.
enum DateRange { today, yesterday, week, month }

/// Currently selected date range (Riverpod 3 — small Notifier).
class DateRangeNotifier extends Notifier<DateRange> {
  @override
  DateRange build() => DateRange.today;

  void select(DateRange range) => state = range;
}

final dashboardRangeProvider =
    NotifierProvider<DateRangeNotifier, DateRange>(DateRangeNotifier.new);

/// Dashboard state provider with auto-refresh.
class DashboardNotifier extends AsyncNotifier<DashboardState> {
  Timer? _timer;

  @override
  Future<DashboardState> build() async {
    // Rebuild when the range changes.
    ref.watch(dashboardRangeProvider);
    _timer?.cancel();
    // Refresh less aggressively; 3s is smooth enough for a local DB.
    _timer = Timer.periodic(
        const Duration(seconds: 3), (_) => ref.invalidateSelf());
    ref.onDispose(() => _timer?.cancel());
    return _load();
  }

  Future<DashboardState> _load() async {
    final api = ref.read(apiProvider);
    final range = ref.read(dashboardRangeProvider);
    final (start, end) = _rangeBounds(range);
    // Single FFI call for the whole dashboard.
    final data = api.getDashboardData(start: start, end: end);
    final (thisWeek, lastWeek) = api.getWeekTotals();
    return DashboardState(
      apps: data.apps
          .map((s) => AppUsageItem(
                appName: s.appName,
                activeSeconds: s.activeSeconds.toInt(),
                idleSeconds: s.idleSeconds.toInt(),
                exePath: s.exePath.isEmpty ? null : s.exePath,
              ))
          .toList(),
      totalActiveSeconds: data.activeSeconds.toInt(),
      totalIdleSeconds: data.idleSeconds.toInt(),
      lifetimeSeconds: data.totalSeconds.toInt(),
      thisWeekSeconds: thisWeek.toInt(),
      lastWeekSeconds: lastWeek.toInt(),
      since: data.since,
    );
  }

  (String, String) _rangeBounds(DateRange range) {
    final now = DateTime.now();
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final today = fmt(now);
    switch (range) {
      case DateRange.today:
        return (today, today);
      case DateRange.yesterday:
        final y = now.subtract(const Duration(days: 1));
        final ys = fmt(y);
        return (ys, ys);
      case DateRange.week:
        final monday = now.subtract(Duration(days: now.weekday - 1));
        return (fmt(monday), today);
      case DateRange.month:
        return ('${now.year}-${now.month.toString().padLeft(2, '0')}-01', today);
    }
  }
}

final dashboardProvider =
    AsyncNotifierProvider.autoDispose<DashboardNotifier, DashboardState>(
        DashboardNotifier.new);
