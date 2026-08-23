import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:window_manager/window_manager.dart';

/// Currently selected date range (Riverpod 3 - small Notifier).
class DateRangeNotifier extends Notifier<DateRangeSelection> {
  @override
  DateRangeSelection build() => const DateRangeSelection(DateRange.today);

  /// Pick a range shortcut (today / yesterday / week / month).
  void select(DateRange range) => state = DateRangeSelection(range);

  /// Pick a concrete calendar day; drives every chart on the dashboard.
  void selectDay(DateTime day) =>
      state = DateRangeSelection(DateRange.custom, day: day);
}

final dashboardRangeProvider =
    NotifierProvider<DateRangeNotifier, DateRangeSelection>(
      DateRangeNotifier.new,
    );

/// One caller-captured local-calendar range shared by every dashboard reader.
/// It invalidates once at the next local midnight so the DB and AI projection
/// can never compute different dates during the same frame.
final dashboardRangeBoundsProvider = Provider<DateRangeBounds>((ref) {
  final now = DateTime.now();
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(nextMidnight.difference(now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return resolveDateRange(ref.watch(dashboardRangeProvider), now);
});


/// Dashboard state provider with auto-refresh.
class DashboardNotifier extends AsyncNotifier<DashboardState> {
  /// 按范围边界缓存最近 8 个范围，切回时秒开、不再重新加载。
  static final Map<String, DashboardState> _cache = {};
  static const int _cacheCap = 8;
  Timer? _timer;

  @override
  Future<DashboardState> build() async {
    // Rebuild when the range changes.
    final bounds = ref.watch(dashboardRangeBoundsProvider);
    _timer?.cancel();
    // Refresh only while the window is visible; 10s is plenty for a local DB.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    ref.onDispose(() => _timer?.cancel());
    final cached = _cache[bounds.cacheKey];
    if (cached != null) {
      // 先展示缓存，再后台刷新保证新鲜度。
      Future.microtask(_refresh);
      return cached;
    }
    final loaded = await _load();
    _cache[bounds.cacheKey] = loaded;
    _trimCache();
    return loaded;
  }

  /// 后台刷新当前范围：只更新 state 与缓存，不触发全屏 loading/重绘。
  Future<void> _refresh() async {
    try {
      if (!(await windowManager.isVisible())) return;
      final loaded = await _load();
      final bounds = ref.read(dashboardRangeBoundsProvider);
      _cache[bounds.cacheKey] = loaded;
      _trimCache();
      state = AsyncData(loaded);
    } catch (_) {
      // 保持旧数据，静默失败。
    }
  }

  void _trimCache() {
    while (_cache.length > _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
  }


  Future<DashboardState> _load() async {
    final api = ref.read(apiProvider);
    final bounds = ref.read(dashboardRangeBoundsProvider);
    // Single FFI call for the whole dashboard.
    final data = api.getDashboardData(start: bounds.start, end: bounds.end);
    final databaseDegraded = api.isDatabaseDegraded();
    final (thisWeek, lastWeek) = api.getWeekTotals();
    return DashboardState(
      apps: _mergeApps(data.apps),
      totalActiveSeconds: data.activeSeconds.toInt(),
      totalIdleSeconds: data.idleSeconds.toInt(),
      lifetimeSeconds: data.totalSeconds.toInt(),
      thisWeekSeconds: thisWeek.toInt(),
      lastWeekSeconds: lastWeek.toInt(),
      databaseDegraded: databaseDegraded,
      since: data.since,
    );
  }

}

final dashboardProvider =
    AsyncNotifierProvider.autoDispose<DashboardNotifier, DashboardState>(
      DashboardNotifier.new,
    );

/// Rust normalizes app names before persistence; this layer only merges rows
/// defensively for legacy databases and keeps the first icon path.
List<AppUsageItem> _mergeApps(List<AppUsageDto> rows) {
  final merged = <String, _MergedApp>{};
  for (final s in rows) {
    final name = s.appName;
    final e =
        merged[name] ??
        _MergedApp(
          active: 0,
          idle: 0,
          exePath: s.exePath.isEmpty ? null : s.exePath,
        );
    e.active += (s.activeSeconds as num).toInt();
    e.idle += (s.idleSeconds as num).toInt();

    if (e.exePath == null && s.exePath.isNotEmpty) e.exePath = s.exePath;
    merged[name] = e;
  }
  final list = merged.entries
      .map(
        (e) => AppUsageItem(
          appName: e.key,
          activeSeconds: e.value.active,
          idleSeconds: e.value.idle,
          exePath: e.value.exePath,
        ),
      )
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
