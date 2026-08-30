import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Ranked horizontal bars for application usage.
///
/// App names vary far more than their durations. A horizontal layout reserves
/// a stable text line for every name, avoids tiny fitted text, and keeps every
/// bar on the same baseline even when the source contains many applications.
class AppChartSection extends StatelessWidget {
  const AppChartSection({
    required this.apps,
    required this.selected,
    required this.onSelect,
    this.tall = false,
    super.key,
  });

  final List<AppUsageItem> apps;
  final int? selected;
  final ValueChanged<int> onSelect;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxTotal = apps.fold<int>(
      1,
      (max, app) => app.activeSeconds > max ? app.activeSeconds : max,
    );

    return Card(
      key: const ValueKey('dashboard-app-bars'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxRows = constraints.maxHeight < 320 ? 5 : 6;
            final count = apps.length.clamp(0, maxRows).toInt();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('应用排行', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      apps.length > count
                          ? '前 $count / ${apps.length} 个 · 点击查看会话'
                          : '${apps.length} 个应用 · 点击查看会话',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                Expanded(
                  child: Column(
                    children: [
                      for (var index = 0; index < count; index++)
                        Expanded(
                          child: _UsageBarRow(
                            rank: index + 1,
                            app: apps[index],
                            ratio: apps[index].activeSeconds / maxTotal,
                            selected: selected == index,
                            onTap: () => onSelect(index),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({
    required this.rank,
    required this.app,
    required this.ratio,
    required this.selected,
    required this.onTap,
  });

  final int rank;
  final AppUsageItem app;
  final double ratio;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = appColor(app.appName);

    return Semantics(
      button: true,
      selected: selected,
      label: '第 $rank 名，${app.appName}，活跃 ${app.activeLabel}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          child: AnimatedContainer(
            duration: TimeTraceMotion.fast,
            curve: TimeTraceMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: TimeTraceSpace.xs,
              vertical: TimeTraceSpace.xxs,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.42)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        rank.toString().padLeft(2, '0'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Tooltip(
                        message: app.appName,
                        child: Text(
                          app.appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: TimeTraceSpace.sm),
                    Text(
                      app.activeLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TimeTraceSpace.xxs),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      key: ValueKey('app-bar-$rank'),
                      value: ratio.clamp(0.0, 1.0).toDouble(),
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: color.withValues(alpha: selected ? 0.96 : 0.72),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
