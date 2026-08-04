import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

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

  /// Carousel state + shared calendar day.
  final PageController _carouselCtrl = PageController();
  int _carouselIndex = 0;
  DateTime _calSelected = DateTime.now();
  SummaryRange _summaryRange = SummaryRange.day;
  DiaryRange _diaryRange = DiaryRange.day;
  DateTime? _diaryCustomStart;

  @override
  void dispose() {
    _carouselCtrl.dispose();
    super.dispose();
  }

  Future<void> _select(int i) async {
    final deselecting = _selected == i;
    setState(() {
      _selected = deselecting ? null : i;
      _pages = null;
      _loadingPages = !deselecting;
    });
    if (deselecting) return;
    try {
      final api = ref.read(apiProvider);
      final range = ref.read(dashboardRangeProvider);
      final now = DateTime.now();
      String end;
      switch (range) {
        case DateRange.today:
        case DateRange.week:
        case DateRange.month:
          end = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        case DateRange.yesterday:
          final y = now.subtract(const Duration(days: 1));
          end = '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
      }
      final pages = api.getWindowTitles(
          appName: widget.state.apps[i].appName, date: end);
      if (mounted) {
        setState(() {
          _pages = pages;
          _loadingPages = false;
        });
        if (i < _rowKeys.length) {
          final ctx = _rowKeys[i].currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              alignment: 0.2,
            );
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps =
        state.apps.where((a) => a.totalSeconds > 0).toList(growable: false);

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
                              ref.watch(dashboardRangeProvider) == range;
                          return ChoiceChip(
                            label:
                                Text(label, style: const TextStyle(fontSize: 12)),
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
                          Icon(Icons.info_outline,
                              size: 18, color: scheme.primary),
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

                    // Friendly placeholder for empty data pages
                    Widget placeholder(String icon, String text) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.insights_outlined,
                                  size: 40, color: scheme.outlineVariant),
                              const SizedBox(height: 10),
                              Text(text,
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline)),
                            ],
                          ),
                        );

                    Widget carousel = SizedBox(
                      height: carouselH,
                      child: Column(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                // ◀ prev
                                IconButton(
                                  icon: Icon(Icons.chevron_left,
                                      size: 22, color: scheme.primary),
                                  tooltip: '上一个视图',
                                  // Wrap-around: first page goes to last
                                  onPressed: () {
                                    if (_carouselIndex > 0) {
                                      _carouselCtrl.previousPage(
                                        duration: const Duration(
                                            milliseconds: 250),
                                        curve: Curves.easeOut,
                                      );
                                    } else {
                                      _carouselCtrl.animateToPage(
                                        pageCount - 1,
                                        duration: const Duration(
                                            milliseconds: 300),
                                        curve: Curves.easeOut,
                                      );
                                    }
                                  },
                                ),
                                Expanded(
                                  child: PageView(
                                    controller: _carouselCtrl,
                                    onPageChanged: (i) => setState(
                                        () => _carouselIndex = i),
                                    children: [
                                      for (final key in order)
                                        switch (key) {
                                          'bar' => apps.isEmpty
                                              ? placeholder('bar', '暂无使用数据')
                                              : SizedBox(
                                                  height: carouselH - 8,
                                                  child: AppChartSection(
                                                    apps: apps,
                                                    selected: _selected,
                                                    // Clicking a bar also jumps
                                                    // to the apps page (sessions).
                                                    onSelect: (i) {
                                                      _select(i);
                                                      final appsIdx =
                                                          order.indexOf('apps');
                                                      if (appsIdx >= 0) {
                                                        _carouselCtrl
                                                            .animateToPage(
                                                          appsIdx,
                                                          duration: const Duration(
                                                              milliseconds:
                                                                  300),
                                                          curve: Curves.easeOut,
                                                        );
                                                      }
                                                    },
                                                    tall: true,
                                                  ),
                                                ),
                                          'pie' => apps.isEmpty
                                              ? placeholder('pie', '暂无使用数据')
                                              : SizedBox(
                                                  height: carouselH - 8,
                                                  child: PieChartCard(
                                                      apps: apps),
                                                ),
                                          'summary' => SingleChildScrollView(
                                              child: Padding(
                                                padding: const EdgeInsets
                                                    .symmetric(horizontal: 12),
                                                child: Card(
                                                  child: Padding(
                                                    padding: const EdgeInsets
                                                        .all(12),
                                                    child: DaySummaryPanel(
                                                      date: _calSelected,
                                                      range: _summaryRange,
                                                      onRangeChanged: (r) =>
                                                          setState(() =>
                                                              _summaryRange =
                                                                  r),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          'apps' => apps.isEmpty
                                              ? placeholder('apps', '暂无使用数据')
                                              : Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(horizontal: 4),
                                                  child: SingleChildScrollView(
                                                    child: AppListSection(
                                                      apps: apps,
                                                      selected: _selected,
                                                      pages: _pages,
                                                      loading: _loadingPages,
                                                      onSelect: _select,
                                                      rowKeys: _rowKeys,
                                                    ),
                                                  ),
                                                ),
                                          _ => const SizedBox.shrink(),
                                        },
                                    ],
                                  ),
                                ),
                                // ▶ next
                                IconButton(
                                  icon: Icon(Icons.chevron_right,
                                      size: 22, color: scheme.primary),
                                  tooltip: '下一个视图',
                                  // Wrap-around: last page goes to first
                                  onPressed: () {
                                    if (_carouselIndex < pageCount - 1) {
                                      _carouselCtrl.nextPage(
                                        duration: const Duration(
                                            milliseconds: 250),
                                        curve: Curves.easeOut,
                                      );
                                    } else {
                                      _carouselCtrl.animateToPage(
                                        0,
                                        duration: const Duration(
                                            milliseconds: 300),
                                        curve: Curves.easeOut,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Carousel dots (clickable)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < pageCount; i++)
                                GestureDetector(
                                  onTap: () => _carouselCtrl.animateToPage(
                                    i,
                                    duration: const Duration(
                                        milliseconds: 250),
                                    curve: Curves.easeOut,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                          milliseconds: 200),
                                      width: _carouselIndex == i ? 18 : 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: _carouselIndex == i
                                            ? scheme.primary
                                            : scheme.outlineVariant,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );

                    // Calendar block (left column / top on narrow)
                    Widget calendar = Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.calendar_month,
                                    size: 18, color: scheme.primary),
                                const SizedBox(width: 6),
                                Text('日历',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.primary)),
                                const Spacer(),
                                // Diary range (linked to the journal below)
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: SegmentedButton<DiaryRange>(
                                    segments: const [
                                      ButtonSegment(value: DiaryRange.day, label: Text('当天', style: TextStyle(fontSize: 10))),
                                      ButtonSegment(value: DiaryRange.week, label: Text('一周', style: TextStyle(fontSize: 10))),
                                      ButtonSegment(value: DiaryRange.month, label: Text('一月', style: TextStyle(fontSize: 10))),
                                      ButtonSegment(value: DiaryRange.custom, label: Text('自定义', style: TextStyle(fontSize: 10))),
                                    ],
                                    selected: {_diaryRange},
                                    onSelectionChanged: (s) => setState(
                                        () => _diaryRange = s.first),
                                    showSelectedIcon: false,
                                    style: ButtonStyle(
                                      visualDensity: VisualDensity.compact,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      padding: WidgetStatePropertyAll(
                                          const EdgeInsets.symmetric(
                                              horizontal: 6)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_diaryRange == DiaryRange.custom) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                      _diaryCustomStart == null
                                          ? '未选起始日'
                                          : '从 ${calFmt(_diaryCustomStart!)} 起',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: scheme.outline)),
                                  const SizedBox(width: 8),
                                  TextButton(
                                    onPressed: () async {
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: _calSelected,
                                        firstDate: DateTime(2020),
                                        lastDate: DateTime.now(),
                                        helpText: '选择起始日期（到所选日）',
                                      );
                                      if (picked != null) {
                                        setState(() =>
                                            _diaryCustomStart = picked);
                                      }
                                    },
                                    child: const Text('选起始日',
                                        style: TextStyle(fontSize: 11)),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 8),
                            CalendarGrid(
                              selected: _calSelected,
                              onSelected: (d) =>
                                  setState(() => _calSelected = d),
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
                          carousel,
                          const SizedBox(height: 12),
                          calendar,
                        ],
                      );
                    }
                    // Wide: calendar LEFT, carousel RIGHT
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: calendar),
                        const SizedBox(width: 12),
                        Expanded(flex: 7, child: carousel),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                // ── Journal (selected day) ──
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DiarySection(
                      date: _calSelected,
                      range: _diaryRange,
                      customStart: _diaryCustomStart,
                    ),
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
