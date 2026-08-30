import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_card.dart';

/// Quiet overview metrics used above the main dashboard canvas.
///
/// These are intentionally factual values already present in DashboardState;
/// no synthetic "productivity score" is invented just to fill the UI.
class DashboardSummaryStrip extends StatelessWidget {
  const DashboardSummaryStrip({
    required this.state,
    required this.apps,
    this.compact = false,
    super.key,
  });

  final DashboardState state;
  final List<AppUsageItem> apps;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final totalTracked = state.totalActiveSeconds + state.totalIdleSeconds;
    final focusRate = totalTracked <= 0
        ? 0
        : (state.totalActiveSeconds / totalTracked * 100).round();
    final topApp = apps.isEmpty ? null : apps.first;

    final items = <_SummaryMetric>[
      _SummaryMetric(
        label: '活跃时长',
        value: state.totalActiveLabel,
        detail: state.totalIdleSeconds > 0
            ? '闲置 ${formatDuration(state.totalIdleSeconds)}'
            : '当前范围',
        icon: Icons.timelapse_rounded,
      ),
      _SummaryMetric(
        label: '应用数量',
        value: '${apps.length}',
        detail: '当前范围有记录',
        icon: Icons.apps_rounded,
      ),
      _SummaryMetric(
        label: '专注率',
        value: '$focusRate%',
        detail: '活跃时间 / 总追踪时间',
        icon: Icons.center_focus_strong_rounded,
      ),
      _SummaryMetric(
        label: '最常用',
        value: topApp?.appName ?? '—',
        detail: topApp?.activeLabel ?? '暂无数据',
        icon: Icons.trending_up_rounded,
        accent: topApp == null ? null : appColor(topApp.appName),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (constraints.maxWidth) {
          >= 900 => 4,
          >= 520 => 2,
          _ => 1,
        };
        final gap = TimeTraceSpace.sm;
        final width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final item in items)
                  SizedBox(
                    width: width,
                    height: compact ? 88 : 108,
                    child: _SummaryCard(metric: item, compact: compact),
                  ),
              ],
            ),
            SizedBox(
              height: compact ? TimeTraceSpace.xs : TimeTraceSpace.sm,
            ),
            RecapPreviewCard(compact: compact),
          ],
        );
      },
    );
  }
}

class _SummaryMetric {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    this.accent,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final Color? accent;
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.metric, required this.compact});

  final _SummaryMetric metric;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = metric.accent ?? scheme.primary;

    return Card(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          TimeTraceSpace.sm,
          compact ? TimeTraceSpace.xs : TimeTraceSpace.sm,
          TimeTraceSpace.sm,
          TimeTraceSpace.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  metric.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Icon(metric.icon, size: 15, color: accent),
              ],
            ),
            const Spacer(),
            Text(
              metric.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: compact ? 18 : 20,
                letterSpacing: -0.45,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xxs),
            Row(
              children: [
                Container(
                  width: 14,
                  height: 3,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xxs),
                Expanded(
                  child: Text(
                    metric.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
