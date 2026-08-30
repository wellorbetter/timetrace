import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/dashboard_summary_strip.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/hourly_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('概览')),
      body: asyncState.when(
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
  int? _selected;
  List<PageDto>? _pages;
  bool _loadingPages = false;
  final List<GlobalKey> _rowKeys = [];
  List<AppUsageItem> _visibleApps = const [];

  static const int _kCarouselBase = 200000;
  late final int _carouselInit;
  late final PageController _carouselCtrl;
  int _carouselAbs = 0;
  int _carouselIndex = 0;
  final ValueNotifier<int> _carouselDot = ValueNotifier<int>(0);

  final GlobalKey _calendarKey = GlobalKey();
  double _calendarH = 0;
  final GlobalKey _appsViewportKey = GlobalKey();
  final ScrollController _appsScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    final order = _activeOrder();
    final pageCount = order.isEmpty ? 1 : order.length;
    _carouselInit = (_kCarouselBase ~/ pageCount) * pageCount;
    _carouselCtrl = PageController(initialPage: _carouselInit);
    _carouselAbs = _carouselInit;

    ref.listenManual(hourlyFocusProvider, (prev, next) {
      if (next == null) return;
      final orderNow = _activeOrder();
      final idx = orderNow.indexOf('hourly');
      if (idx >= 0) _goToReal(idx, animate: false);
    });
    ref.listenManual(dashboardHiddenViewsProvider, (previous, next) {
      final summaryIndex = _activeOrder().indexOf('summary');
      if (summaryIndex < 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goToReal(summaryIndex, animate: false);
      });
    });
  }

  @override
  void dispose() {
    _carouselCtrl.dispose();
    _carouselDot.dispose();
    _appsScrollCtrl.dispose();
    super.dispose();
  }

  void _goToReal(int realIdx, {bool animate = false}) {
    final order = _activeOrder();
    final pageCount = order.length;
    if (pageCount <= 0 || realIdx < 0 || realIdx >= pageCount) return;

    final currentAbsolute = _carouselCtrl.hasClients
        ? (_carouselCtrl.page?.round() ?? _carouselAbs)
        : _carouselAbs;
    final currentIndex = currentAbsolute % pageCount;
    var delta = realIdx - currentIndex;
    if (delta > pageCount / 2) delta -= pageCount;
    if (delta < -pageCount / 2) delta += pageCount;
    final target = currentAbsolute + delta;
    if (target == currentAbsolute) return;

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

  List<String> _activeOrder() => dashboardVisibleOrder(
    ref.read(dashboardOrderProvider),
    ref.read(dashboardHiddenViewsProvider),
  );

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
      final selectedRange = ref.read(dashboardRangeProvider);
      final day = selectedRange.effectiveDay;
      final date =
          '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      final pages = api.getWindowTitles(
        appName: _visibleApps[i].appName,
        date: date,
      );
      if (!mounted) return;

      setState(() {
        _pages = pages;
        _loadingPages = false;
      });

      if (fromAppsPage) {
        _scrollAppsToRow(i);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  void _selectAppByName(String name) {
    final idx = _visibleApps.indexWhere((app) => app.appName == name);
    if (idx < 0) return;
    if (_selected != idx) _selectApp(idx);

    final order = _activeOrder();
    final appsIdx = order.indexOf('apps');
    if (appsIdx >= 0) {
      _goToReal(appsIdx);
      _scrollAppsToRow(idx);
    }
  }

  void _scrollAppsToRow(int i) {
    Future<void>.delayed(TimeTraceMotion.normal, () {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || i >= _rowKeys.length || !_appsScrollCtrl.hasClients) {
          return;
        }
        final rowContext = _rowKeys[i].currentContext;
        final viewportContext = _appsViewportKey.currentContext;
        final rowBox = rowContext?.findRenderObject() as RenderBox?;
        final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
        if (rowBox == null || viewportBox == null) return;

        final rowTop = rowBox
            .localToGlobal(Offset.zero, ancestor: viewportBox)
            .dy;
        final rowBottom = rowTop + rowBox.size.height;
        final viewportHeight = viewportBox.size.height;
        var target = _appsScrollCtrl.offset;
        if (rowTop < TimeTraceSpace.xs) {
          target += rowTop - TimeTraceSpace.xs;
        } else if (rowBottom > viewportHeight - TimeTraceSpace.xs) {
          target += rowBottom - viewportHeight + TimeTraceSpace.xs;
        } else {
          return;
        }
        final safeTarget = target.clamp(
          _appsScrollCtrl.position.minScrollExtent,
          _appsScrollCtrl.position.maxScrollExtent,
        );
        _appsScrollCtrl.animateTo(
          safeTarget.toDouble(),
          duration: TimeTraceMotion.normal,
          curve: TimeTraceMotion.standard,
        );
      });
    });
  }

  void _measureCalendar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _calendarKey.currentContext?.size;
      if (size != null && (size.height - _calendarH).abs() > 0.5) {
        setState(() => _calendarH = size.height);
      }
    });
  }

  Widget _buildPage(
    String key, {
    required DateTime day,
    required List<String> order,
    required List<AppUsageItem> apps,
  }) {
    final Widget page = switch (key) {
      'bar' =>
        apps.isEmpty
            ? _placeholder('暂无使用数据')
            : AppChartSection(
                apps: apps,
                selected: _selected,
                onSelect: (i) {
                  _selectApp(i);
                  final appsIdx = order.indexOf('apps');
                  if (appsIdx >= 0) {
                    _goToReal(appsIdx);
                    _scrollAppsToRow(i);
                  }
                },
                tall: true,
              ),
      'pie' =>
        apps.isEmpty
            ? _placeholder('暂无使用数据')
            : PieChartCard(
                apps: apps,
                selectedIndex: _selected,
                onSelectApp: (i) {
                  if (_selected != i) _selectApp(i);
                  final appsIdx = order.indexOf('apps');
                  if (appsIdx >= 0) {
                    _goToReal(appsIdx, animate: true);
                    _scrollAppsToRow(i);
                  }
                },
              ),
      'hourly' =>
        apps.isEmpty
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
        padding: EdgeInsets.zero,
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: DaySummaryPanel(date: day),
          ),
        ),
      ),
      'apps' =>
        apps.isEmpty
            ? _placeholder('暂无使用数据')
            : LayoutBuilder(
                builder: (context, constraints) => Scrollbar(
                  controller: _appsScrollCtrl,
                  child: SingleChildScrollView(
                    key: _appsViewportKey,
                    controller: _appsScrollCtrl,
                    primary: false,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
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
                ),
              ),
      _ => const SizedBox.shrink(),
    };

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
          Icon(Icons.insights_outlined, size: 34, color: scheme.outlineVariant),
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
        .where((app) => app.totalSeconds > 0)
        .toList(growable: false);
    final selection = ref.watch(dashboardRangeProvider);
    final calendarDay = selection.effectiveDay;

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
        final screenSize = screenSizeOf(constraints);
        final compactHeight = constraints.maxHeight < 860;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final horizontalPadding =
            constraints.maxWidth < TimeTraceLayout.compactBreakpoint
            ? TimeTraceSpace.sm
            : TimeTraceSpace.lg;

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TimeTraceLayout.dashboardWidth,
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                compactHeight ? TimeTraceSpace.sm : TimeTraceSpace.md,
                horizontalPadding,
                compactHeight ? TimeTraceSpace.md : TimeTraceSpace.xl,
              ),
              children: [
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
                      ChoiceChip(
                        label: Text(label),
                        selected: selection.range == range,
                        onSelected: (_) => ref
                            .read(dashboardRangeProvider.notifier)
                            .select(range),
                      ),
                  ],
                ),
                SizedBox(
                  height: compactHeight ? TimeTraceSpace.xs : TimeTraceSpace.sm,
                ),
                DashboardSummaryStrip(
                  state: state,
                  apps: apps,
                  compact: compactHeight,
                ),
                SizedBox(
                  height: compactHeight ? TimeTraceSpace.sm : TimeTraceSpace.md,
                ),
                if (apps.isEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: TimeTraceSpace.md),
                    padding: const EdgeInsets.all(TimeTraceSpace.sm),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.34),
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(
                        TimeTraceRadius.surface,
                      ),
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
                LayoutBuilder(
                  builder: (context, innerConstraints) {
                    final narrow =
                        innerConstraints.maxWidth <
                        TimeTraceLayout.compactBreakpoint;
                    final allViews = ref.watch(dashboardOrderProvider);
                    final hiddenViews = ref.watch(dashboardHiddenViewsProvider);
                    final order = dashboardVisibleOrder(allViews, hiddenViews);
                    final pageCount = order.length;
                    final carouselHeight = narrow
                        ? (compactHeight ? 300.0 : 330.0)
                        : compactHeight
                        ? 350.0
                        : (screenSize.twoColumn ? 400.0 : 360.0);

                    final carouselViewport = Row(
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
                            allowImplicitScrolling: false,
                            onPageChanged: (i) {
                              _carouselAbs = i;
                              _carouselIndex = i % pageCount;
                              _carouselDot.value = _carouselIndex;
                            },
                            itemCount: _carouselInit * 2,
                            itemBuilder: (context, i) => _KeepAlivePage(
                              child: RepaintBoundary(
                                child: _buildPage(
                                  order[i % pageCount],
                                  day: calendarDay,
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
                    );

                    Widget carouselAtHeight(double pageHeight) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(height: pageHeight, child: carouselViewport),
                        const SizedBox(height: TimeTraceSpace.xxs),
                        ValueListenableBuilder<int>(
                          valueListenable: _carouselDot,
                          builder: (context, dot, _) => _CarouselIndicator(
                            order: order,
                            selectedIndex: dot,
                            onSelected: (i) => _goToReal(i, animate: true),
                          ),
                        ),
                      ],
                    );

                    final calendar = Card(
                      key: _calendarKey,
                      child: Padding(
                        padding: EdgeInsets.all(
                          compactHeight ? TimeTraceSpace.xs : TimeTraceSpace.sm,
                        ),
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
                                Text(
                                  switch (selection.range) {
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
                            SizedBox(
                              height: compactHeight
                                  ? TimeTraceSpace.xxs
                                  : TimeTraceSpace.xs,
                            ),
                            CalendarGrid(
                              selected: calendarDay,
                              onSelected: (day) => ref
                                  .read(dashboardRangeProvider.notifier)
                                  .selectDay(day),
                              rowHeight: narrow
                                  ? (compactHeight ? 42 : 48)
                                  : (compactHeight ? 42 : 52),
                            ),
                          ],
                        ),
                      ),
                    );

                    if (narrow) {
                      return Column(
                        children: [
                          carouselAtHeight(carouselHeight),
                          const SizedBox(height: TimeTraceSpace.md),
                          calendar,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: calendar),
                        const SizedBox(width: TimeTraceSpace.md),
                        Expanded(
                          flex: 7,
                          child: carouselAtHeight(
                            _calendarH > 0 ? _calendarH : carouselHeight,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CarouselIndicator extends StatelessWidget {
  const _CarouselIndicator({
    required this.order,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> order;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (order.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final safeIndex = selectedIndex.clamp(0, order.length - 1).toInt();
    final currentLabel = kViews[order[safeIndex]] ?? '数据视图';

    return Semantics(
      liveRegion: true,
      label: '当前轮播视图：$currentLabel，${safeIndex + 1}/${order.length}',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              currentLabel,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          for (var i = 0; i < order.length; i++)
            Semantics(
              button: true,
              selected: safeIndex == i,
              label: '切换到${kViews[order[i]] ?? '数据视图'}',
              child: Tooltip(
                message: kViews[order[i]] ?? '数据视图',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onSelected(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TimeTraceSpace.xxs,
                      vertical: TimeTraceSpace.xs,
                    ),
                    child: AnimatedContainer(
                      duration: TimeTraceMotion.fast,
                      curve: TimeTraceMotion.standard,
                      width: safeIndex == i ? 18 : 7,
                      height: 4,
                      decoration: BoxDecoration(
                        color: safeIndex == i
                            ? scheme.primary
                            : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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
