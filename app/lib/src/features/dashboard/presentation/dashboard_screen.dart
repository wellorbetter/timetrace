import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browsing/presentation/recap_button.dart';
import 'widgets/component_workspace.dart';
import 'dashboard_viewport_budget.dart';
import 'widgets/diary_heading_content.dart';
import '../../../core/widgets/context_help.dart';
import '../../browsing/providers/accounting_snapshot_provider.dart'
    show browsingClockProvider;
import '../providers/workspace_layout_provider.dart';

import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/material/material.dart';
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
import 'package:timetrace_app/src/features/browsing/presentation/date_range_control.dart';
import 'package:timetrace_app/src/features/browsing/providers/browsing_provider.dart';

List<AttributionTotalDto> windowsForApp(
  List<AttributionTotalDto> windows,
  String appId,
) =>
    windows.where((window) => window.parentId == appId).toList(growable: false);

/// Real analytics, calendar and diary components in a configurable workspace.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final query = accountingQueryFor(
      selection,
      ref.read(browsingClockProvider)(),
      timezone: ref.watch(dashboardIanaTimezoneProvider),
    );
    final status = ref.watch(dashboardRefreshStatusProvider);
    final currentStatus = status.queryKey == query.key;
    final hasDataComponent = ref
        .watch(workspaceLayoutProvider)
        .expand((group) => group)
        .any((component) => component.isData);
    final candidate =
        asyncState is AsyncData<DashboardState> && !asyncState.isLoading
        ? asyncState.value
        : null;
    final matches =
        currentStatus &&
        status.acceptedQueryKey == query.key &&
        candidate != null &&
        (query.range is! AccountingRangeRequest_Utc ||
            (DateTime.parse(candidate.requestedStartUtc) ==
                    DateTime.parse(query.startUtc) &&
                DateTime.parse(candidate.requestedEndUtc) ==
                    DateTime.parse(query.endUtc)));
    final displayed = matches ? candidate : null;
    final error = currentStatus ? status.error : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final toolbarTextScaler = MediaQuery.textScalerOf(context);
        final toolbarHeight = WorkspaceEditActions.heightFor(
          context,
          constraints.maxWidth - 2 * MaterialTokens.spaceMd,
          editing: ref.watch(workspaceEditProvider),
          trailingCount: 2,
        );
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            toolbarHeight: toolbarHeight + MaterialTokens.spaceSm,
            titleSpacing: MaterialTokens.spaceMd,
            title: Builder(
              builder: (titleContext) => MediaQuery(
                // AppBar clamps its title scaler. Restore the page's chosen
                // scaler so heightFor and actual reset text share one metric.
                data: MediaQuery.of(titleContext).copyWith(
                  textScaler: toolbarTextScaler,
                ),
                child: WorkspaceEditActions(
                  trailingActions: [
                    const RecapButton(),
                    MaterialIconAction(
                      buttonKey: const Key('dashboard_refresh'),
                      tooltip: '刷新数据',
                      onPressed: () =>
                          ref.read(dashboardProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DateRangeControl(
                    selection: selection,
                    onRange: ref.read(dashboardRangeProvider.notifier).select,
                    onDay: ref.read(dashboardRangeProvider.notifier).selectDay,
                  ),
                ),
              ),
              if (!hasDataComponent &&
                  (currentStatus && status.refreshing || error != null))
                _DashboardDataStatus(
                  error: error,
                  refreshing: currentStatus && status.refreshing,
                  compact: true,
                  coldRetry: displayed == null,
                  notice: true,
                ),
              Expanded(
                key: const ValueKey('dashboard_workspace_body'),
                child: _DashboardBody(
                  state: displayed,
                  queryKey: query.key,
                  refreshing: currentStatus && status.refreshing,
                  error:
                      error ??
                      (asyncState.hasError && currentStatus
                          ? '数据暂时无法读取，可重试'
                          : null),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DashboardBody extends ConsumerStatefulWidget {
  const _DashboardBody({
    required this.state,
    required this.queryKey,
    required this.refreshing,
    this.error,
  });

  final DashboardState? state;
  final String queryKey;
  final bool refreshing;
  final String? error;

  @override
  ConsumerState<_DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends ConsumerState<_DashboardBody> {
  /// Shared app selection: bar chart + app list stay in sync.
  int? _selected;
  List<AttributionTotalDto>? _windows;
  String? _selectedWindowId;
  String? _lastSyncedFragmentKey;
  final List<GlobalKey> _rowKeys = [];

  /// Apps shown in the charts (totalSeconds > 0), same order as charts.
  List<AppUsageItem> _visibleApps = const [];
  DashboardState? _selectionState;
  bool _diaryExpanded = false;

  @override
  void initState() {
    super.initState();
    _selectionState = widget.state;
    // Calendar heatmap → 时段分布 page: jump there and select the hour.
    ref.listenManual(hourlyFocusProvider, (prev, next) {
      if (next == null) return;
      final orderNow = ref.read(dashboardOrderProvider);
      final idx = orderNow.indexOf('hourly');
      if (idx >= 0) _goToReal(idx, animate: false);
    });
    ref.listenManual(browsingProvider, (_, next) {
      _syncBrowsingSelection(next);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBrowsingSelection(ref.read(browsingProvider));
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DashboardBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.state;
    if (next == null)
      return; // Do not reconcile app selection with a fake empty query.
    final previous = _selectionState;
    _selectionState = next;
    final selected = _selected;
    if (selected == null || previous == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncBrowsingSelection(ref.read(browsingProvider));
      });
      return;
    }
    final oldApps = previous.apps
        .where((app) => app.totalSeconds > 0)
        .toList(growable: false);
    if (selected >= oldApps.length) {
      _selected = null;
      _windows = null;
      return;
    }
    final appId = oldApps[selected].appName;
    final newApps = next.apps
        .where((app) => app.totalSeconds > 0)
        .toList(growable: false);
    final newIndex = newApps.indexWhere((app) => app.appName == appId);
    _selected = newIndex < 0 ? null : newIndex;
    _windows = newIndex < 0 ? null : windowsForApp(next.windows, appId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBrowsingSelection(ref.read(browsingProvider));
    });
  }

  void _syncBrowsingSelection(BrowsingState browsing) {
    if (!mounted || widget.state == null || browsing.page != BrowsingPage.data)
      return;
    final anchor = browsing.selectedAnchor;
    if (anchor == null ||
        anchor.isPrivacyExcluded ||
        anchor.fragmentKey == _lastSyncedFragmentKey) {
      return;
    }
    final appId = anchor.appId ?? anchor.windowAppId;
    if (appId == null) return;
    final apps = widget.state!.apps
        .where((app) => app.totalSeconds > 0)
        .toList(growable: false);
    final index = apps.indexWhere((app) => app.appName == appId);
    if (index < 0) return;
    _lastSyncedFragmentKey = anchor.fragmentKey;
    setState(() {
      _selected = index;
      _windows = windowsForApp(widget.state!.windows, appId);
      _selectedWindowId = anchor.windowId;
    });
    final appsPage = ref.read(dashboardOrderProvider).indexOf('apps');
    if (appsPage >= 0) _goToReal(appsPage);
    _scrollToRow(index);
  }

  /// Focus the actual component wherever the user has placed it.
  void _goToReal(int realIdx, {bool animate = false}) {
    final order = ref.read(dashboardOrderProvider);
    if (realIdx < 0 || realIdx >= order.length) return;
    final component = WorkspaceComponent.values.firstWhere(
      (item) => item.name == order[realIdx],
    );
    ref.read(workspaceLayoutProvider.notifier).reveal(component);
    ref.read(workspaceFocusProvider.notifier).select(component);
  }

  /// Select/deselect an app and reveal snapshot window attribution. `fromAppsPage`
  /// enables the follow-up scroll only when the row is already visible,
  /// so chart clicks never fight with the page transition.
  void _selectApp(int i, {bool fromAppsPage = false}) {
    if (widget.state == null || i < 0 || i >= _visibleApps.length) return;
    final deselecting = _selected == i;
    setState(() {
      _selected = deselecting ? null : i;
      _selectedWindowId = null;
      _windows = deselecting
          ? null
          : windowsForApp(widget.state!.windows, _visibleApps[i].appName);
    });
    if (deselecting) return;
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
    required bool singleDay,
    required bool timezoneAvailable,
  }) {
    final snapshot = widget.state;
    if (snapshot == null) {
      return _DashboardDataStatus(error: widget.error, refreshing: true);
    }
    final Widget page = switch (key) {
      'bar' =>
        apps.isEmpty
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
      'pie' => apps.isEmpty ? _placeholder('暂无使用数据') : PieChartCard(apps: apps),
      'hourly' => HourlyChartCard(
        date: day,
        hours: snapshot.hours,
        singleDay: singleDay,
        timezoneAvailable: timezoneAvailable,
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
        child: MaterialCard(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: DaySummaryPanel(
              date: day,
              state: snapshot,
              singleDay: singleDay,
              timezoneAvailable: timezoneAvailable,
            ),
          ),
        ),
      ),
      'apps' =>
        apps.isEmpty
            ? _placeholder('暂无使用数据')
            : AppListSection(
                apps: apps,
                selected: _selected,
                windows: _windows,
                selectedWindowId: _selectedWindowId,
                onSelect: (i) => _selectApp(i, fromAppsPage: true),
                rowKeys: _rowKeys,
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
    final apps =
        state?.apps.where((a) => a.totalSeconds > 0).toList(growable: false) ??
        const <AppUsageItem>[];
    final sel = ref.watch(dashboardRangeProvider);
    final timezoneAvailable = ref.watch(dashboardIanaTimezoneProvider) != null;
    final singleDay =
        sel.range == DateRange.today ||
        sel.range == DateRange.yesterday ||
        sel.range == DateRange.custom;
    final calDay = sel.effectiveDay;
    if (state != null) _visibleApps = apps;

    if (state != null) {
      while (_rowKeys.length < apps.length) {
        _rowKeys.add(GlobalKey());
      }
      while (_rowKeys.length > apps.length) {
        _rowKeys.removeLast();
      }
      if (_selected != null && _selected! >= apps.length) {
        _selected = null;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final scheme = Theme.of(context).colorScheme;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // First-launch hint when the current range has no data yet
                  if (state != null && apps.isEmpty)
                    MaterialCard(
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
                  Expanded(
                    child: LayoutBuilder(
                      key: const ValueKey('dashboard_workspace_layout'),
                      builder: (context, con) {
                        final narrow = con.maxWidth < 760;
                        final order = ref.watch(dashboardOrderProvider);
                        final viewportHeight = constraints.hasBoundedHeight
                            ? constraints.maxHeight
                            : 800.0;
                        final carouselH =
                            (viewportHeight * (narrow ? 0.50 : 0.58))
                                .clamp(
                                  narrow ? 320.0 : 360.0,
                                  narrow ? 500.0 : 560.0,
                                )
                                .toDouble();

                        final layoutView = ref.watch(workspaceDocumentProvider);
                        final prefixBudget = dashboardPrefixBudget(
                          document: layoutView.document,
                          width: con.maxWidth,
                          viewportHeight: con.maxHeight,
                          textScale: MediaQuery.textScalerOf(context).scale(1),
                          writable: layoutView.writable,
                          loading: layoutView.loading,
                          dirty: layoutView.dirty,
                          editing: ref.watch(workspaceEditProvider),
                          diaryExpanded: _diaryExpanded,
                          hasError: layoutView.error != null,
                        );
                        return ComponentWorkspace(
                          prefixBudget: prefixBudget,
                          contentHeight: carouselH,
                          viewportHeight: con.maxHeight,
                          builders: {
                            for (final component in defaultDataComponents)
                              component: (context, layout) => Column(
                                children: [
                                  if (state != null &&
                                      (widget.refreshing ||
                                          widget.error != null ||
                                          state.databaseDegraded))
                                    _DashboardDataStatus(
                                      error: state.databaseDegraded
                                          ? '数据库查询异常，当前数据可能不完整；可重试。'
                                          : widget.error,
                                      refreshing: widget.refreshing,
                                      compact: true,
                                    ),
                                  Expanded(
                                    child: WorkspaceBusinessViewport(
                                      constraints: layout.constraints,
                                      childBuilder: () => _buildPage(
                                        component.name,
                                        day: calDay,
                                        order: order,
                                        apps: apps,
                                        singleDay: singleDay,
                                        timezoneAvailable: timezoneAvailable,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            WorkspaceComponent.calendar: (context, layout) =>
                                WorkspaceCalendarContent(
                                  selected: calDay,
                                  rangeLabel: switch (sel.range) {
                                    DateRange.today => '今天',
                                    DateRange.yesterday => '昨天',
                                    DateRange.week => '本周',
                                    DateRange.month => '本月',
                                    DateRange.custom => '所选日',
                                  },
                                  onSelected: (day) {
                                    final current = ref.read(
                                      dashboardRangeProvider,
                                    );
                                    if (current.range == DateRange.custom &&
                                        current.startUtc == null &&
                                        current.endUtc == null &&
                                        current.day?.year == day.year &&
                                        current.day?.month == day.month &&
                                        current.day?.day == day.day)
                                      return;
                                    ref
                                        .read(dashboardRangeProvider.notifier)
                                        .selectDay(day);
                                  },
                                ),
                            WorkspaceComponent.diary: (context, layout) =>
                                _CollapsibleDiary(
                                  onExpandedChanged: (expanded) {
                                    if (mounted && expanded != _diaryExpanded) {
                                      setState(() => _diaryExpanded = expanded);
                                    }
                                  },
                                  date: calDay,
                                  range: _diaryRangeFor(sel),
                                  showQuote: !layout.visibleIds.contains(
                                    WorkspaceComponent.dailyPoetry.name,
                                  ),
                                ),
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Local to accounting components: independent workspace content never unmounts.
class _DashboardDataStatus extends ConsumerWidget {
  const _DashboardDataStatus({
    this.error,
    required this.refreshing,
    this.compact = false,
    this.coldRetry = false,
    this.notice = false,
  });
  final String? error;
  final bool refreshing, compact, coldRetry, notice;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final body = Column(
      key: Key(
        notice ? 'dashboard_query_notice' : 'dashboard_local_data_status',
      ),
      mainAxisSize: MainAxisSize.min,
      children: [
        if ((!compact || coldRetry) && error == null)
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(MaterialTokens.spaceLg),
              child: LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  key: const Key('dashboard_query_structure_preview'),
                  width: constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : 240,
                  height: compact ? 48 : 96,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final fraction in const [.55, .9, .7])
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: MaterialTokens.spaceSm,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: fraction,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: .08),
                                  borderRadius: BorderRadius.circular(
                                    MaterialTokens.spaceSm,
                                  ),
                                ),
                                child: SizedBox(height: compact ? 6 : 16),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        Text(
          error ??
              (compact && !coldRetry
                  ? (notice ? '正在刷新…' : '当前数据更新中…')
                  : '正在加载所选范围…'),
        ),
        if (error != null)
          TextButton(
            key: const Key('dashboard_local_retry'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => ref.read(dashboardProvider.notifier).refresh(),
            child: Text(coldRetry ? '数据暂时无法读取，重试' : '重试'),
          ),
      ],
    );
    return compact ? body : Center(child: body);
  }
}

/// Existing bounded data widgets keep a usable viewport even at large text.
/// Scrolling is local to their span; the workspace never persists that scale.
class WorkspaceBusinessViewport extends StatelessWidget {
  const WorkspaceBusinessViewport({
    required this.constraints,
    required this.childBuilder,
    super.key,
  });
  final BoxConstraints constraints;
  final Widget Function() childBuilder;
  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final width = constraints.maxWidth < 320 * scale
        ? 320 * scale
        : constraints.maxWidth;
    final height =
        constraints.maxHeight.isFinite && constraints.maxHeight > 320 * scale
        ? constraints.maxHeight
        : 320 * scale;
    return SingleChildScrollView(
      primary: false,
      child: SingleChildScrollView(
        primary: false,
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: width, height: height, child: childBuilder()),
      ),
    );
  }
}

/// Fit the complete month to the actual content slot, without internal scrolling.
/// Primary navigation remains full-size; date geometry honors TextScaler before fitting.
class WorkspaceCalendarContent extends StatefulWidget {
  const WorkspaceCalendarContent({
    required this.selected,
    required this.rangeLabel,
    required this.onSelected,
    super.key,
  });
  final DateTime selected;
  final String rangeLabel;
  final ValueChanged<DateTime> onSelected;
  @override
  State<WorkspaceCalendarContent> createState() =>
      _WorkspaceCalendarContentState();
}

class _WorkspaceCalendarContentState extends State<WorkspaceCalendarContent> {
  @override
  Widget build(BuildContext context) => MaterialCard(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceSm),
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '日历',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  widget.rangeLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const ContextHelp(
                  message: '完整月份按格位分配七列六行，日期字形单独适配。可调为2×3增加阅读空间；月份切换按钮保持可操作大小。',
                ),
              ],
            ),
          ),
          Expanded(
            child: CalendarGrid(
              selected: widget.selected,
              onSelected: widget.onSelected,
              boundedFit: true,
            ),
          ),
        ],
      ),
    ),
  );
}

class _CollapsibleDiary extends StatefulWidget {
  const _CollapsibleDiary({
    required this.date,
    required this.range,
    required this.showQuote,
    this.onExpandedChanged,
  });
  final bool showQuote;
  final ValueChanged<bool>? onExpandedChanged;

  final DateTime date;
  final DiaryRange range;

  @override
  State<_CollapsibleDiary> createState() => _CollapsibleDiaryState();
}

class _CollapsibleDiaryState extends State<_CollapsibleDiary> {
  bool _expanded = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final materialPolicy = MaterialScope.of(context).policy;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutQuart,
        decoration: BoxDecoration(
          color: materialPolicy.contentSurface,
          borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
          border: Border.all(
            color: _expanded
                ? scheme.primary.withValues(alpha: 0.24)
                : scheme.outlineVariant.withValues(alpha: 0.62),
          ),
          boxShadow: MaterialTokens.cardShadow(
            dark: dark,
            lifted: _hovered || _expanded,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
          child: MaterialSheen(
            child: Column(
              children: [
                Semantics(
                  button: true,
                  expanded: _expanded,
                  label: _expanded ? '收起日记' : '展开日记',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                      MaterialTokens.contentRadius,
                    ),
                    onTap: () {
                      setState(() => _expanded = !_expanded);
                      widget.onExpandedChanged?.call(_expanded);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MaterialTokens.spaceLg,
                        vertical: MaterialTokens.spaceMd,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.menu_book_outlined, color: scheme.primary),
                          const SizedBox(width: MaterialTokens.spaceMd),
                          Expanded(
                            child: DiaryHeadingContent(
                              date: widget.date,
                              showQuote: widget.showQuote && !_expanded,
                            ),
                          ),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutQuart,
                            child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutQuart,
                  alignment: Alignment.topCenter,
                  child: _expanded
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            MaterialTokens.spaceLg,
                            0,
                            MaterialTokens.spaceLg,
                            MaterialTokens.spaceLg,
                          ),
                          child: DiarySection(
                            date: widget.date,
                            range: widget.range,
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
