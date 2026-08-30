import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Compact aggregate summary used only for Week and Month selections.
///
/// The single-day summary remains the original main-branch panel. This panel
/// avoids presenting today's heatmap and first-use times as if they represented
/// an entire multi-day selection.
class RangeSummaryPanel extends StatelessWidget {
  const RangeSummaryPanel({
    required this.start,
    required this.end,
    required this.state,
    super.key,
  });

  final DateTime start;
  final DateTime end;
  final DashboardState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final apps = state.apps
        .where((app) => app.activeSeconds > 0)
        .toList(growable: false);
    final maxActive = apps.isEmpty
        ? 1
        : apps.first.activeSeconds.clamp(1, 1 << 62);

    return Column(
      key: const ValueKey('dashboard-range-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _rangeLabel(start, end),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '范围汇总',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.xs),
        Wrap(
          spacing: TimeTraceSpace.xs,
          runSpacing: TimeTraceSpace.xxs,
          children: [
            _SummaryChip(
              label: '活跃 ${formatDuration(state.totalActiveSeconds)}',
              color: scheme.primary,
            ),
            _SummaryChip(label: '${apps.length} 应用', color: scheme.tertiary),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        Row(
          children: [
            Text(
              '应用记录',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '所选范围累计',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.xxs),
        if (apps.isEmpty)
          Expanded(
            child: Center(
              child: Text('该范围暂无记录', style: theme.textTheme.bodySmall),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              primary: false,
              padding: EdgeInsets.zero,
              itemCount: apps.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: scheme.outlineVariant),
              itemBuilder: (context, index) {
                final app = apps[index];
                return SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: appColor(app.appName),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.xs),
                      Expanded(
                        child: Tooltip(
                          message: app.appName,
                          child: Text(
                            app.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.sm),
                      SizedBox(
                        width: 72,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: (app.activeSeconds / maxActive)
                                .clamp(0.02, 1.0)
                                .toDouble(),
                            minHeight: 4,
                            backgroundColor: scheme.surfaceContainerHighest,
                            color: appColor(app.appName),
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.xs),
                      SizedBox(
                        width: 58,
                        child: Text(
                          app.activeLabel,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: TimeTraceSpace.xs,
      vertical: TimeTraceSpace.xxs,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      border: Border.all(color: color.withValues(alpha: 0.18)),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}

String _rangeLabel(DateTime start, DateTime end) {
  String short(DateTime value) => '${value.month}月${value.day}日';
  if (start.year == end.year &&
      start.month == end.month &&
      start.day == end.day) {
    return short(start);
  }
  return '${short(start)} – ${short(end)}';
}
