import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/core/widgets/empty_state.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/stat_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Dashboard with two modes (product flow):
/// 概览 — glanceable stats (stats + chart + app list)
/// 日历日记 — focused calendar + day summary + journal
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('使用统计'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '概览'),
              Tab(text: '日历日记'),
            ],
          ),
        ),
        body: asyncState.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败: $e')),
          data: (state) => TabBarView(
            children: [
              _OverviewBody(state: state),
              const _CalendarBody(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 概览: range chips + stats + bar chart + app distribution.
class _OverviewBody extends ConsumerStatefulWidget {
  const _OverviewBody({required this.state});

  final DashboardState state;

  @override
  ConsumerState<_OverviewBody> createState() => _OverviewBodyState();
}

class _OverviewBodyState extends ConsumerState<_OverviewBody> {
  /// Shared selection: bar chart and app list stay in sync.
  int? _selected;
  List<PageDto>? _pages;
  bool _loadingPages = false;
  final List<GlobalKey> _rowKeys = [];
  final PageController _carouselCtrl = PageController();
  int _carouselIndex = 0;
  DateTime _calSelected = DateTime.now();
  SummaryRange _summaryRange = SummaryRange.day;

  Future<void> _select(int i) async {
    final deselecting = _selected == i;
    setState(() {
      _selected = deselecting ? null : i;
      _pages = null;
      _loadingPages = !deselecting; // cancel deselection stops spinner
    });
    if (deselecting) return;
    try {
      final api = ref.read(apiProvider);
      // Use the dashboard's selected range end date so pages appear
      // for week/month views too.
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
        // Scroll the tapped row into view so the inline detail is visible
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
  void dispose() {
    _carouselCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps =
        state.apps.where((a) => a.totalSeconds > 0).toList(growable: false);

    // Keep row keys in sync with apps
    while (_rowKeys.length < apps.length) {
      _rowKeys.add(GlobalKey());
    }
    while (_rowKeys.length > apps.length) {
      _rowKeys.removeLast();
    }
    if (_selected != null && _selected! >= apps.length) {
      _selected = null;
    }

    if (apps.isEmpty) {
      return const EmptyState(message: '暂无数据，切换应用后回来查看');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = screenSizeOf(constraints);
        final scheme = Theme.of(context).colorScheme;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
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
                            label: Text(label,
                                style: const TextStyle(fontSize: 12)),
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
                // Stats: 活跃 (current range) vs 累计 (since install)
                Row(
                  children: [
                    StatCard(
                        icon: Icons.timer_outlined,
                        label: '活跃',
                        value: state.totalActiveLabel,
                        color: scheme.primary),
                    const SizedBox(width: 10),
                    StatCard(
                        icon: Icons.history,
                        label: '累计',
                        value: _fmt(state.lifetimeSeconds),
                        subtitle: '安装以来',
                        color: scheme.tertiary),
                  ],
                ),
                const SizedBox(height: 12),
                // ── Data carousel: 柱状图 | 饼图 | 日历 | 汇总 ──
                SizedBox(
                  height: size.twoColumn ? 380 : 360,
                  child: Column(
                    children: [
                      Expanded(
                        child: PageView(
                          controller: _carouselCtrl,
                          onPageChanged: (i) =>
                              setState(() => _carouselIndex = i),
                          children: [
                            AppChartSection(
                              apps: apps,
                              selected: _selected,
                              onSelect: _select,
                              tall: true,
                            ),
                            PieChartCard(apps: apps),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: CalendarGrid(
                                    selected: _calSelected,
                                    onSelected: (d) =>
                                        setState(() => _calSelected = d),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: DaySummaryPanel(
                                    date: _calSelected,
                                    range: _summaryRange,
                                    onRangeChanged: (r) => setState(
                                        () => _summaryRange = r),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Carousel dots (clickable)
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < 4; i++)
                            GestureDetector(
                              onTap: () => _carouselCtrl.animateToPage(
                                i,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4),
                                child: AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 200),
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
                ),
                const SizedBox(height: 12),
                // App distribution — sessions expand inline
                AppListSection(
                  apps: apps,
                  selected: _selected,
                  pages: _pages,
                  loading: _loadingPages,
                  onSelect: _select,
                  rowKeys: _rowKeys,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }
}

/// 日历日记: focused calendar + summary + journal (full width).
class _CalendarBody extends StatelessWidget {
  const _CalendarBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: const [
            CalendarCard(),
          ],
        ),
      ),
    );
  }
}
