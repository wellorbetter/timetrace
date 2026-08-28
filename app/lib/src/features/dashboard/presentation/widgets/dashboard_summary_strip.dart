import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_card.dart';

/// Overview metrics are shortcuts, not dead tiles. Clicking a card opens a
/// lightweight explanation/detail sheet without forcing the user away from the
/// current date and carousel state.
class DashboardSummaryStrip extends StatelessWidget {
  const DashboardSummaryStrip({required this.state, required this.apps, super.key});

  final DashboardState state;
  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final totalTracked = state.totalActiveSeconds + state.totalIdleSeconds;
    final activeRatio = totalTracked <= 0 ? 0 : (state.totalActiveSeconds / totalTracked * 100).round();
    final topApp = apps.isEmpty ? null : apps.first;

    final items = <_SummaryMetric>[
      _SummaryMetric(
        label: '活跃时长',
        value: state.totalActiveLabel,
        detail: state.totalIdleSeconds > 0 ? '闲置 ${formatDuration(state.totalIdleSeconds)} · 点击查看' : '点击查看统计说明',
        icon: Icons.timelapse_rounded,
        onTap: () => _showMetricSheet(
          context,
          title: '活跃时长',
          icon: Icons.timelapse_rounded,
          body: '当前范围记录到 ${state.totalActiveLabel} 活跃时间${state.totalIdleSeconds > 0 ? '，另有 ${formatDuration(state.totalIdleSeconds)} 闲置时间' : ''}。TimeTrace 只在前台活动且未进入 Idle/锁屏/睡眠状态时累计活跃时间。',
        ),
      ),
      _SummaryMetric(
        label: '应用数量',
        value: '${apps.length}',
        detail: '点击快速查看排行',
        icon: Icons.apps_rounded,
        onTap: () => _showAppsSheet(context, apps),
      ),
      _SummaryMetric(
        label: '活跃占比',
        value: '$activeRatio%',
        detail: '活跃 / 总追踪 · 点击说明',
        icon: Icons.center_focus_strong_rounded,
        onTap: () => _showMetricSheet(
          context,
          title: '活跃占比',
          icon: Icons.center_focus_strong_rounded,
          body: '活跃占比 = 活跃时间 ÷（活跃时间 + 闲置时间）。它只是设备活动事实，不是生产力、效率、健康或努力程度评分。',
        ),
      ),
      _SummaryMetric(
        label: '最常用',
        value: topApp?.appName ?? '—',
        detail: topApp == null ? '暂无数据' : '${topApp.activeLabel} · 点击查看',
        icon: Icons.trending_up_rounded,
        accent: topApp == null ? null : appColor(topApp.appName),
        onTap: topApp == null
            ? null
            : () => _showMetricSheet(
                  context,
                  title: topApp.appName,
                  icon: Icons.trending_up_rounded,
                  body: '当前范围内 ${topApp.appName} 的活跃时长为 ${topApp.activeLabel}。更细的窗口/页面会话可以在下面的“应用排行”视图中展开查看。',
                ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (constraints.maxWidth) { >= 900 => 4, >= 520 => 2, _ => 1 };
        final gap = TimeTraceSpace.sm;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final item in items) SizedBox(width: width, height: 108, child: _SummaryCard(metric: item))],
            ),
            const SizedBox(height: TimeTraceSpace.sm),
            const RecapPreviewCard(),
          ],
        );
      },
    );
  }
}

Future<void> _showMetricSheet(BuildContext context, {required String title, required IconData icon, required String body}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(TimeTraceSpace.lg, TimeTraceSpace.xs, TimeTraceSpace.lg, TimeTraceSpace.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: TimeTraceSpace.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: TimeTraceSpace.xs),
                Text(body, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.55)),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
);

Future<void> _showAppsSheet(BuildContext context, List<AppUsageItem> apps) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(TimeTraceSpace.lg, 0, TimeTraceSpace.lg, TimeTraceSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('当前范围的主要应用', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: TimeTraceSpace.sm),
          if (apps.isEmpty)
            Text('暂无应用数据', style: Theme.of(context).textTheme.bodySmall)
          else
            for (var i = 0; i < apps.take(5).length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text((i + 1).toString().padLeft(2, '0')),
                title: Text(apps[i].appName),
                trailing: Text(apps[i].activeLabel),
              ),
          const SizedBox(height: TimeTraceSpace.xs),
          Text('关闭此面板后，可在概览的“应用排行”视图中点击应用查看页面会话。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  ),
);

class _SummaryMetric {
  const _SummaryMetric({required this.label, required this.value, required this.detail, required this.icon, this.accent, this.onTap});
  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final Color? accent;
  final VoidCallback? onTap;
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.metric});
  final _SummaryMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = metric.accent ?? scheme.primary;
    return Card(
      child: InkWell(
        onTap: metric.onTap,
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(TimeTraceSpace.sm, TimeTraceSpace.sm, TimeTraceSpace.sm, TimeTraceSpace.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [Text(metric.label, style: theme.textTheme.labelMedium), const Spacer(), Icon(metric.icon, size: 15, color: accent)]),
              const Spacer(),
              Text(metric.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.45, fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: TimeTraceSpace.xxs),
              Row(
                children: [
                  Container(width: 14, height: 3, decoration: BoxDecoration(color: accent.withValues(alpha: 0.68), borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: TimeTraceSpace.xxs),
                  Expanded(child: Text(metric.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall)),
                  if (metric.onTap != null) Icon(Icons.chevron_right_rounded, size: 14, color: scheme.onSurfaceVariant),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
