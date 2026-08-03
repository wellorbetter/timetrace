import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/responsive.dart';
import 'package:timetrace_app/src/core/widgets/empty_state.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
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
  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final apps =
        state.apps.where((a) => a.totalSeconds > 0).toList(growable: false);

    if (apps.isEmpty) {
      return const EmptyState(message: '暂无数据，切换应用后回来查看');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = screenSizeOf(constraints);
        final scheme = Theme.of(context).colorScheme;

        // ── WIDE: two-column ──
        if (size.twoColumn) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: _leftColumn(context, size, apps, state, scheme),
                ),

              ],
            ),
          );
        }

        // ── MEDIUM / COMPACT: single column ──
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // Stats
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
            // Integrated chart + app list
            const SizedBox(height: 12),
            AppChartSection(apps: apps),
            if (size.showChartsRow) ...[
              const SizedBox(height: 12),
              PieChartCard(apps: apps),
            ],

          ],
        );
      },
    );
  }

  Widget _leftColumn(BuildContext context, ScreenSize size,
      List<AppUsageItem> apps, DashboardState state, ColorScheme scheme) {
    return ListView(
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
        // Charts row: chart natural height, pie FIXED height (no jitter)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 6,
              child: SizedBox(
                height: 360,
                child: AppChartSection(apps: apps, tall: true),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 260,
              height: 360,
              child: PieChartCard(apps: apps),
            ),
          ],
        ),
      ],
    );
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }
}
