import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// A single compact overview rail.
///
/// The four values belong to the same range, so they share one surface instead
/// of competing as four equal cards. The most-used application gets extra room
/// and can wrap to two lines without shrinking into unreadable text.
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
    final activeRatio = totalTracked <= 0
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
        flex: 12,
      ),
      _SummaryMetric(
        label: '使用应用',
        value: '${apps.length}',
        detail: '当前范围有记录',
        icon: Icons.apps_rounded,
        flex: 9,
      ),
      _SummaryMetric(
        label: '活跃占比',
        value: '$activeRatio%',
        detail: '活跃 / 总追踪',
        icon: Icons.donut_small_rounded,
        flex: 10,
      ),
      _SummaryMetric(
        label: '最常用',
        value: topApp?.appName ?? '—',
        detail: topApp?.activeLabel ?? '暂无数据',
        icon: Icons.trending_up_rounded,
        accent: topApp == null ? null : appColor(topApp.appName),
        flex: 15,
        longValue: true,
      ),
    ];

    return Card(
      key: const ValueKey('dashboard-summary-rail'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scheme = Theme.of(context).colorScheme;
          final columns = constraints.maxWidth >= 860 ? 4 : 2;
          final cellHeight = compact ? 88.0 : 92.0;

          if (columns == 4) {
            return SizedBox(
              height: cellHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    Expanded(
                      flex: items[index].flex,
                      child: _SummaryCell(metric: items[index]),
                    ),
                    if (index != items.length - 1)
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: scheme.outlineVariant,
                      ),
                  ],
                ],
              ),
            );
          }

          final width = (constraints.maxWidth - 1) / 2;
          return Wrap(
            children: [
              for (var index = 0; index < items.length; index++)
                Container(
                  width: width,
                  height: cellHeight,
                  decoration: BoxDecoration(
                    border: Border(
                      right: index.isEven
                          ? BorderSide(color: scheme.outlineVariant)
                          : BorderSide.none,
                      bottom: index < 2
                          ? BorderSide(color: scheme.outlineVariant)
                          : BorderSide.none,
                    ),
                  ),
                  child: _SummaryCell(metric: items[index]),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SummaryMetric {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.flex,
    this.accent,
    this.longValue = false,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final int flex;
  final Color? accent;
  final bool longValue;
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.metric});

  final _SummaryMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = metric.accent ?? scheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: TimeTraceSpace.xs,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: Icon(metric.icon, size: 16, color: accent),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (metric.longValue)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          metric.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Text(
                        metric.detail,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    metric.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: TimeTraceSpace.xxs),
                Tooltip(
                  message: metric.value,
                  child: Text(
                    metric.value,
                    maxLines: metric.longValue ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: metric.longValue
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.titleLarge?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                  ),
                ),
                if (!metric.longValue)
                  Text(
                    metric.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
