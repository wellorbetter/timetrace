import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
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
/// The carousel holds data displays; the calendar is a permanent element
/// whose day selection drives the summary and journal.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('概览')),
      body: asyncState.when(
        // 切换日期范围时保留旧数据直到新数据到达，避免全屏重绘/闪白。
        skipLoadingOnReload: true,
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: TimeTraceSpace.sm),
              Text('正在加载使用数据…', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (state) => Column(
          children: [
            if (state.databaseDegraded)
              MaterialBanner(
                leading: const Icon(Icons.warning_amber_outlined),
                content: const Text('数据库查询异常，当前数据可能不完整；详细信息已记录到日志。'),
                actions: [
                  TextButton(
                    onPressed: () => ref.invalidate(dashboardProvider),
                    child: const Text('重试'),
                  ),
                ],
              ),
            Expanded(child: _DashboardBody(state: state)),
          ],
        ),
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

  /// 页码指示器：切页只更新它，不重建整页。
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
        duration: TimeTraceMotion.normal,
        curve: TimeTraceMotion.standard,
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
              duration: TimeTraceMotion.normal,
              curve: TimeTraceMotion.standard,
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
          duration: TimeTraceMotion.normal,
          curve: TimeTraceMotion.standard,
          alignment: 0.2,
        );
      }
    });
  }

  /// 测量日历卡片高度，让右侧轮播与之对齐（月份 4~6 行、日记
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
        padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: DaySummaryPanel(date: day),
          ),
        ),
      ),
      'apps' => apps.isEmpty
          ? _placeholder('暂无使用数据')
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xxs),
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
    // PageView 某些布局阶段会给页面无界高度，统一兜底，
    // 避免 Expanded/LayoutBuilder 报 Infinity 错误。
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: double.infinity,
        height: constraints.maxHeight.isFinite ? constraints.maxHeight : 360,
        child: page,
      ),
    );
  }

  Widget _placeholder(String text) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.insights_outlined,
            size: 34,
            color: scheme.outlineVariant,
          ),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
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
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TimeTraceLayout.dashboardWidth,
            ),
            child: ListView(
              padding: TimeTraceLayout.pagePadding(constraints.maxWidth),
              children: [
                // Range controls stay lightweight; they are filters, not cards.
                Wrap(
                  spacing: TimeTraceSpace.xs,
                  runSpacing: TimeTraceSpace.xs,
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
                            label: Text(label),
                            selected: selected,
                            onSelected: (_) => ref
                                .read(dashboardRangeProvider.notifier)
                                .select(range),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: TimeTraceSpace.md),
                // First-launch hint when the current range has no data yet.
                if (apps.isEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: TimeTraceSpace.md),
                    padding: const EdgeInsets.all(TimeTraceSpace.sm),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.34),
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius:
                          BorderRadius.circular(TimeTraceRadius.surface),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 17,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: TimeTraceSpace.xs),
                        Expanded(
                          child: Text(
                            '暂无使用数据。开始使用应用后会自动记录，也可以切换日期范围查看。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                // ── Data area: calendar (left) + ordered carousel (right) ──
                LayoutBuilder(
                  builder: (context, con) {
                    final narrow =
                        con.maxWidth < TimeTraceLayout.compactBreakpoint;
                    final order = ref.watch(dashboardOrderProvider);
                    final pageCount = order.length;
                    final carouselH = narrow
                        ? 330.0
                        : (size.twoColumn ? 400.0 : 360.0);

                    final carousel = Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.chevron_left_rounded),
                                tooltip: '上一个视图',
                                onPressed: () => _carouselCtrl.previousPage(
                                  duration: TimeTraceMotion.normal,
                                  curve: TimeTraceMotion.standard,
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
                                  itemBuilder: (context, i) => _KeepAlivePage(
                                    // 每页独立绘制层，切页滑动时只移动已缓存的画布。
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
                              IconButton(
                                icon: const Icon(Icons.chevron_right_rounded),
                                tooltip: '下一个视图',
                                onPressed: () => _carouselCtrl.nextPage(
                                  duration: TimeTraceMotion.normal,
                                  curve: TimeTraceMotion.standard,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: TimeTraceSpace.xs),
                        // Thin page marks read more quietly than large carousel dots.
                        ValueListenableBuilder<int>(
                          valueListenable: _carouselDot,
                          builder: (context, dot, _) => Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < pageCount; i++)
                                GestureDetector(
                                  onTap: () => _goToReal(i, animate: true),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: TimeTraceSpace.xxs,
                                      vertical: TimeTraceSpace.xxs,
                                    ),
                                    child: AnimatedContainer(
                                      duration: TimeTraceMotion.fast,
                                      curve: TimeTraceMotion.standard,
                                      width: dot == i ? 18 : 7,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: dot == i
                                            ? scheme.primary
                                            : scheme.outlineVariant,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    );

                    // Calendar block (left column / top on narrow).
                    final calendar = Card(
                      key: _calendarKey,
                      child: Padding(
                        padding: const EdgeInsets.all(TimeTraceSpace.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.calendar_month_outlined,
                                  size: 17,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: TimeTraceSpace.xs),
                                Text(
                                  '日历',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
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
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: TimeTraceSpace.xs),
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
                      return Column(
                        children: [
                          SizedBox(height: carouselH, child: carousel),
                          const SizedBox(height: TimeTraceSpace.md),
                          calendar,
                        ],
                      );
                    }

                    // Wide: calendar LEFT, carousel RIGHT — align their heights.
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: calendar),
                        const SizedBox(width: TimeTraceSpace.md),
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
                const SizedBox(height: TimeTraceSpace.md),
                // Diary has no outer card; posts/editor carry their own surface.
                Padding(
                  padding: const EdgeInsets.only(bottom: TimeTraceSpace.md),
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

/// Keeps a carousel page alive so swiping back doesn't rebuild heavy charts.
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
