import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/core/widgets/empty_state.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/stat_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('使用统计'),
        actions: [
          for (final (label, range) in [
            ('今天', DateRange.today),
            ('昨天', DateRange.yesterday),
            ('本周', DateRange.week),
            ('本月', DateRange.month),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Consumer(
                builder: (context, ref, _) {
                  final selected = ref.watch(dashboardRangeProvider) == range;
                  return ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: selected,
                    onSelected: (_) =>
                        ref.read(dashboardRangeProvider.notifier).select(range),
                  );
                },
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
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
  /// Shared selection: bar chart and app list stay in sync.
  int? _selected;
  List<PageDto>? _pages;
  bool _loadingPages = false;
  final List<GlobalKey> _rowKeys = [];

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
      final pages = api.getWindowTitles(appName: widget.state.apps[i].appName, date: end);
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

        // ── WIDE: charts on top, app list fills the rest below ──
        if (size.twoColumn) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                        label: '总时长',
                        value: _fmt(state.lifetimeSeconds),
                        color: scheme.tertiary),
                  ],
                ),
                const SizedBox(height: 12),
                // Charts: bar (flex) + pie (fixed 260×360, no jitter)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 6,
                      child: SizedBox(
                        height: 300,
                        child: AppChartSection(
                          apps: apps,
                          selected: _selected,
                          onSelect: _select,
                          tall: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 260,
                      height: 300,
                      child: PieChartCard(apps: apps),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
        }

        // ── MEDIUM / COMPACT: single column ──
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(
              children: [
                StatCard(
                    icon: Icons.timer_outlined,
                    label: '活跃',
                    value: state.totalActiveLabel,
                    color: scheme.primary),
                const SizedBox(width: 10),
                if (size.threeStats) ...[
                  const SizedBox(width: 10),
                  StatCard(
                      icon: Icons.history,
                      label: '总时长',
                      value: _fmt(state.lifetimeSeconds),
                      color: scheme.tertiary),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // Charts: bar + pie side by side (fixed heights)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: SizedBox(
                    height: 300,
                    child: AppChartSection(
                      apps: apps,
                      selected: _selected,
                      onSelect: _select,
                      tall: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 260,
                  height: 300,
                  child: PieChartCard(apps: apps),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AppListSection(
              apps: apps,
              selected: _selected,
              pages: _pages,
              loading: _loadingPages,
              onSelect: _select,
              rowKeys: _rowKeys,
            ),
          ],
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
