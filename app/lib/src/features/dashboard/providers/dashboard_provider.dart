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
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => ref.invalidateSelf());
    ref.onDispose(() => _timer?.cancel());
    return _load();
  }

  Future<DashboardState> _load() async {
    final api = ref.read(apiProvider);
    final range = ref.read(dashboardRangeProvider);
    final (start, end) = _rangeBounds(range);
    final split = api.getUsageSplit(start: start, end: end);
    final stats = api.getStats(start: start, end: end);
    return DashboardState(
      apps: split
          .map((s) => AppUsageItem(
                appName: s.appName,
                activeSeconds: s.activeSeconds.toInt(),
                idleSeconds: s.idleSeconds.toInt(),
              ))
          .toList(),
      totalActiveSeconds: stats.activeSeconds.toInt(),
      totalIdleSeconds: stats.idleSeconds.toInt(),
      lifetimeSeconds: stats.totalSeconds.toInt(),
      since: stats.since,
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
    AsyncNotifierProvider<DashboardNotifier, DashboardState>(
        DashboardNotifier.new);
