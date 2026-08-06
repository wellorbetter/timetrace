import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/hourly_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

/// Single-page dashboard (概览 + 日历日记 merged):
/// stats → data carousel (柱状图/饼图/汇总) → calendar → app list → journal.
/// The carousel holds three DATA DISPLAYS; the calendar is a permanent
/// element (day selection drives 汇总 + 日记).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('使用统计')),
      body: asyncState.when(
        // 切换日期范围时保留旧数据直到新数据到达，避免全屏重绘/闪白。
        skipLoadingOnReload: true,
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('正在加载使用数据…', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (state) => _DashboardBody(state: state),
      ),
    );
  }
}

class _DashboardBody extends ConsumerStatefulWidget {
  const _DashboardBody({required this.state});

  final DashboardState state;

  @override
  ConsumerState<_DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends ConsumerState<_DashboardBody> {
  /// Shared app selection: bar chart + app list stay in sync.
  int? _selected;
  List<PageDto>? _pages;
  bool _loadingPages = false;
  final List<GlobalKey> _rowKeys = [];

  /// Apps shown in the charts (totalSeconds > 0), same order as charts.
  List<AppUsageItem> _visibleApps = const [];

  /// Carousel state + shared calendar day.
  /// Infinite paging: the controller starts at a large aligned page so
  /// wrap-around (last → first) is a normal one-page step, no sweep.
  static const int _kCarouselBase = 200000;
  late final int _carouselInit;
  late final PageController _carouselCtrl;
  int _carouselAbs = 0;
  int _carouselIndex = 0;

  /// 页码圆点指示器：切页只更新它，不重建整页。
  final ValueNotifier<int> _carouselDot = ValueNotifier<int>(0);

  /// 左侧日历卡片实际高度（动态测量），右侧轮播与之等高对齐。
  final GlobalKey _calendarKey = GlobalKey();
  double _calendarH = 0;

  @override
  void initState() {
    super.initState();
    final order = ref.read(dashboardOrderProvider);
    final pageCount = order.isEmpty ? 1 : order.length;
    _carouselInit = (_kCarouselBase ~/ pageCount) * pageCount;
    _carouselCtrl = PageController(initialPage: _carouselInit);
    _carouselAbs = _carouselInit;
    // Calendar heatmap → 时段分布 page: jump there and select the hour.
    ref.listenManual(hourlyFocusProvider, (prev, next) {
      if (next == null) return;
      final orderNow = ref.read(dashboardOrderProvider);
      final idx = orderNow.indexOf('hourly');
      if (idx >= 0) _goToReal(idx, animate: false);
    });
  }

  @override
  void dispose() {
    _carouselCtrl.dispose();
    _carouselDot.dispose();
    super.dispose();
  }

  /// Jump to a real carousel page using the shortest direction.
  void _goToReal(int realIdx, {bool animate = false}) {
    final order = ref.read(dashboardOrderProvider);
    final pageCount = order.length;
    if (pageCount <= 0 || realIdx < 0 || realIdx >= pageCount) return;
    final delta = (realIdx - _carouselIndex + pageCount) % pageCount;
    final target = _carouselAbs + delta;
    if (target == _carouselAbs) return;
    if (animate) {
      _carouselCtrl.animateToPage(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _carouselCtrl.jumpToPage(target);
    }
  }

  /// Select/deselect an app and load its page breakdown. `fromAppsPage`
  /// enables the follow-up scroll only when the row is already visible,
  /// so chart clicks never fight with the page transition.
  void _selectApp(int i, {bool fromAppsPage = false}) {
    if (i < 0 || i >= _visibleApps.length) return;
    final deselecting = _selected == i;
    setState(() {
      _selected = deselecting ? null : i;
      _pages = null;
      _loadingPages = !deselecting;
    });
    if (deselecting) return;
    try {
      final api = ref.read(apiProvider);
      final sel = ref.read(dashboardRangeProvider);
      final d = sel.effectiveDay;
      final end =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final pages = api.getWindowTitles(
        appName: _visibleApps[i].appName,
        date: end,
      );
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _loadingPages = false;
      });
      if (fromAppsPage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || i >= _rowKeys.length) return;
          final ctx = _rowKeys[i].currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              alignment: 0.2,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  /// Select an app by its (normalized) name, then jump to the apps page.
  void _selectAppByName(String name) {
    final idx = _visibleApps.indexWhere((a) => a.appName == name);
    if (idx < 0) return;
    if (_selected != idx) _selectApp(idx);
    final order = ref.read(dashboardOrderProvider);
    final appsIdx = order.indexOf('apps');
    if (appsIdx >= 0) {
      _goToReal(appsIdx);
      _scrollToRow(idx);
    }
  }

  /// 跳页后滚动应用列表，让选中行可见（仅应用列表页已就绪时）。
  void _scrollToRow(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || i >= _rowKeys.length) return;
      final ctx = _rowKeys[i].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
      }
    });
  }

  /// 测量日历卡片高度，让右侧轮播与其对齐（月份 4~6 行、日记
  /// 自定义区间行出现/隐藏都会改变高度，每次 build 后重新测量）。
  void _measureCalendar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _calendarKey.currentContext?.size;
      if (size != null && (size.height - _calendarH).abs() > 0.5) {
        setState(() => _calendarH = size.height);
      }
    });
  }

  /// 日记范围随顶部范围 chips 合并（移除日历卡片内重复选择器）。
  DiaryRange _diaryRangeFor(DateRangeSelection sel) {
    switch (sel.range) {
      case DateRange.today:
      case DateRange.yesterday:
      case DateRange.custom:
        return DiaryRange.day;
      case DateRange.week:
        return DiaryRange.week;
      case DateRange.month:
        return DiaryRange.month;
    }
  }

  /// One carousel page for a real view key.
  Widget _buildPage(
    String key, {
    required DateTime day,
    required List<String> order,
    required List<AppUsageItem> apps,
  }) {
    final Widget page = switch (key) {
      'bar' => apps.isEmpty
          ? _placeholder('暂无使用数据')
          : AppChartSection(
              apps: apps,
              selected: _selected,
              // Clicking a bar also jumps to the apps page (sessions).
              onSelect: (i) {
                _selectApp(i);
                final appsIdx = order.indexOf('apps');
                if (appsIdx >= 0) {
                  _goToReal(appsIdx);
                  _scrollToRow(i);
                }
              },
              tall: true,
            ),
      'pie' => apps.isEmpty
          ? _placeholder('暂无使用数据')
          : PieChartCard(apps: apps),
      'hourly' => apps.isEmpty
          ? _placeholder('暂无使用数据')
          : HourlyChartCard(
              date: day,
              apps: apps,
              selectedName: _selected != null && _selected! < apps.length
                  ? apps[_selected!].appName
                  : null,
              onSelectApp: _selectAppByName,
              onClearSelected: () {
                if (_selected != null) _selectApp(_selected!);
              },
            ),
      'summary' => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: DaySummaryPanel(date: day),
          ),
        ),
      ),
      'apps' => apps.isEmpty
          ? _placeholder('暂无使用数据')
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SingleChildScrollView(
                child: AppListSection(
                  apps: apps,
                  selected: _selected,
                  pages: _pages,
                  loading: _loadingPages,
                  onSelect: (i) => _selectApp(i, fromAppsPage: true),
                  rowKeys: _rowKeys,
                ),
              ),
            ),
      _ => const SizedBox.shrink(),
    };
    // PageView 某些布局阶段会给页面无界高度，统一兑底，
    // 避免 Expanded/LayoutBuilder 报 Infinity错误。
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: double.infinity,
        height: constraints.maxHeight.isFinite ? constraints.maxHeight : 360,
        child: page,
      ),
    );
  }

  Widget _placeholder(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_outlined, size: 40, color: scheme.outlineVariant),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(fontSize: 12, color: scheme.outline)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps = state.apps
        .where((a) => a.totalSeconds > 0)
        .toList(growable: false);
    final sel = ref.watch(dashboardRangeProvider);
    final calDay = sel.effectiveDay;
    _visibleApps = apps;
    _measureCalendar();

    while (_rowKeys.length < apps.length) {
      _rowKeys.add(GlobalKey());
    }
    while (_rowKeys.length > apps.length) {
      _rowKeys.removeLast();
    }
    if (_selected != null && _selected! >= apps.length) {
      _selected = null;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = screenSizeOf(constraints);
        final scheme = Theme.of(context).colorScheme;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Range chips
                Wrap(
                  spacing: 6,
                  children: [
                    for (final (label, range) in [
                      ('今天', DateRange.today),
                      ('昨天', DateRange.yesterday),
                      ('本周', DateRange.week),
                      ('本月', DateRange.month),
                    ])
                      Consumer(
                        builder: (context, ref, _) {
                          final selected =
                              ref.watch(dashboardRangeProvider).range == range;
                          return ChoiceChip(
                            label: Text(
                              label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: selected,
                            onSelected: (_) => ref
                                .read(dashboardRangeProvider.notifier)
                                .select(range),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                // First-launch hint when the current range has no data yet
                if (apps.isEmpty)
                  Card(
                    color: scheme.secondaryContainer.withValues(alpha: 0.4),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '暂无使用数据 — 开始使用应用后将自动记录，也可以切换右上角日期范围查看。',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // ── Data area: calendar (left) + ordered carousel (right) ──
                LayoutBuilder(
                  builder: (context, con) {
                    final narrow = con.maxWidth < 760;
                    final order = ref.watch(dashboardOrderProvider);
                    final pageCount = order.length;
                    final carouselH = narrow
                        ? 330.0
                        : (size.twoColumn ? 400.0 : 360.0);

                    Widget carousel = Column(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                                                // ◀ prev
                                IconButton(
                                  icon: Icon(
                                    Icons.chevron_left,
                                    size: 22,
                                    color: scheme.primary,
                                  ),
                                  tooltip: '上一个视图',
                                  // 无缝轮播：永远只移动一页，首尾互切不再横扫。
                                  onPressed: () => _carouselCtrl.previousPage(
                                    duration: const Duration(
                                      milliseconds: 200,
                                    ),
                                    curve: Curves.easeOut,
                                  ),
                                ),
                                Expanded(
                                  child: PageView.builder(
                                    controller: _carouselCtrl,
                                    onPageChanged: (i) {
                                      _carouselAbs = i;
                                      _carouselIndex = i % pageCount;
                                      _carouselDot.value = _carouselIndex;
                                    },
                                    itemCount: _carouselInit * 2,
                                    itemBuilder: (context, i) =>
                                        _KeepAlivePage(
                                      // 每页独立绘制层，切页滑动时只移动已缓存的画布，避免重绘卡顿。
                                      child: RepaintBoundary(
                                        child: _buildPage(
                                          order[i % pageCount],
                                          day: calDay,
                                          order: order,
                                          apps: apps,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
// ▶ next
                                IconButton(
                                  icon: Icon(
                                    Icons.chevron_right,
                                    size: 22,
                                    color: scheme.primary,
                                  ),
                                  tooltip: '下一个视图',
                                  // Wrap-around: last page goes to first
                                  onPressed: () => _carouselCtrl.nextPage(
                                    duration: const Duration(
                                      milliseconds: 200,
                                    ),
                                    curve: Curves.easeOut,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Carousel dots (clickable) — 切页时只重建这一行。
                          ValueListenableBuilder<int>(
                            valueListenable: _carouselDot,
                            builder: (context, dot, _) => Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                for (var i = 0; i < pageCount; i++)
                                  GestureDetector(
                                    onTap: () =>
                                        _goToReal(i, animate: true),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        width: dot == i ? 18 : 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: dot == i
                                              ? scheme.primary
                                              : scheme.outlineVariant,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                    );

                    // Calendar block (left column / top on narrow)
                    Widget calendar = Card(
                      key: _calendarKey,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.calendar_month,
                                  size: 18,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '日历',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                                const Spacer(),
                                // 范围与顶部 chips 合并：这里只显示当前范围。
                                Text(
                                  switch (sel.range) {
                                    DateRange.today => '今天',
                                    DateRange.yesterday => '昨天',
                                    DateRange.week => '本周',
                                    DateRange.month => '本月',
                                    DateRange.custom => '所选日',
                                  },
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.outline,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            CalendarGrid(
                              selected: calDay,
                              onSelected: (d) => ref
                                  .read(dashboardRangeProvider.notifier)
                                  .selectDay(d),
                              rowHeight: narrow ? 48 : 52,
                            ),
                          ],
                        ),
                      ),
                    );

                    if (narrow) {
                      // Stack: carousel first (the "data"), calendar below
                      return Column(
                        children: [
                          SizedBox(height: carouselH, child: carousel),
                          const SizedBox(height: 12),
                          calendar,
                        ],
                      );
                    }
                    // Wide: calendar LEFT, carousel RIGHT — 与日历等高对齐
                    // （测量到前先用默认高度，首帧后对齐）。
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: calendar),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 7,
                          child: SizedBox(
                            height: _calendarH > 0 ? _calendarH : carouselH,
                            child: carousel,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                // ── Journal (selected day) ──
                // Diary section — no outer Card (avoids card-in-card);
                // posts/editor carry their own tone+shadow.
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DiarySection(
                    date: calDay,
                    range: _diaryRangeFor(sel),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Keeps a carousel page alive so swiping back doesn't rebuild heavy
/// charts. Pages still update via didUpdateWidget when the range/day
/// changes, so data stays fresh.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
