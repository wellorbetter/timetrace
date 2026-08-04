import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
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
        const Duration(seconds: 2), (_) => ref.invalidateSelf());
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
      apps: _mergeApps(data.apps),
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


/// Normalize a raw process name to a friendly display name, merging the
/// many exe variants of the same app (msedge vs browser, LeagueClientUx
/// vs League of Legends) so statistics show ONE row.
String normalizeAppName(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('msedge') || lower.contains('webview2')) {
    return 'Edge';
  }
  // qbblinktrial/browser is WeGame's bundled browser trial — NOT Edge.
  if (lower == 'browser' || lower.contains('qbblink')) {
    return 'WeGame浏览器';
  }
  if (lower.contains('leagueclient') ||
      lower.contains('league of legends') ||
      lower.contains('lol')) {
    return '英雄联盟';
  }
  if (lower.contains('startmenu') ||
      lower.contains('shellhost') ||
      lower.contains('searchhost') ||
      lower.contains('lockapp') ||
      lower.contains('applicationframehost') ||
      lower.contains('shellexperiencehost') ||
      lower.contains('runtimebroker') ||
      lower.contains('textinputhost') ||
      lower.contains('dwm')) {
    return '系统';
  }
  if (lower.contains('explorer')) return '资源管理器';
  if (lower.contains('windows terminal') || lower.contains('terminal')) {
    return '终端';
  }
  return raw;
}

/// Merge DTO rows by normalized name (sum durations, keep first exe path).
List<AppUsageItem> _mergeApps(List<AppUsageDto> rows) {
  final merged = <String, _MergedApp>{};
  for (final s in rows) {
    final name = normalizeAppName(s.appName);
    final e = merged[name] ??
        _MergedApp(active: 0, idle: 0, exePath: s.exePath.isEmpty ? null : s.exePath);
    e.active += (s.activeSeconds as num).toInt();
    e.idle += (s.idleSeconds as num).toInt();

    if (e.exePath == null && s.exePath.isNotEmpty) e.exePath = s.exePath;
    merged[name] = e;
  }
  final list = merged.entries
      .map((e) => AppUsageItem(
            appName: e.key,
            activeSeconds: e.value.active,
            idleSeconds: e.value.idle,
            exePath: e.value.exePath,
          ))
      .toList();
  list.sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
  return list;
}

class _MergedApp {
  _MergedApp({required this.active, required this.idle, this.exePath});
  int active;
  int idle;
  String? exePath;
}
