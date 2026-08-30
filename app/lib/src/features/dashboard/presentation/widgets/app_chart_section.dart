import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Compact app-usage bars. Color distinguishes data series; selection is
/// expressed with opacity and typography rather than decorative gradients.
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
    final maxTotal = apps
        .map((a) => a.activeSeconds)
        .fold<int>(1, (m, v) => v > m ? v : m);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxBars = constraints.maxWidth < 480 || apps.length > 6
                ? 6
                : 8;
            final count = apps.length > maxBars ? maxBars : apps.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '按应用',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${apps.length} 个应用 · 点击查看会话',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => onSelect(i),
                              behavior: HitTestBehavior.opaque,
                              child: Tooltip(
                                message:
                                    '${apps[i].appName}\n活跃 ${apps[i].activeLabel}',
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: TimeTraceSpace.xxs,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text(
                                        apps[i].activeSeconds > 0
                                            ? apps[i].activeLabel
                                            : '',
                                        style: theme.textTheme.labelSmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Expanded(
                                        child: FractionallySizedBox(
                                          alignment: Alignment.bottomCenter,
                                          heightFactor:
                                              (apps[i].activeSeconds / maxTotal)
                                                  .clamp(0.02, 1.0),
                                          widthFactor: 1,
                                          child: _Bar(
                                            color: appColor(apps[i].appName),
                                            selected: selected == i,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(
                                        height: TimeTraceSpace.xxs,
                                      ),
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          apps[i].appName,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                fontWeight: selected == i
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                color: selected == i
                                                    ? scheme.onSurface
                                                    : scheme.onSurfaceVariant,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
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

class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TimeTraceMotion.fast,
      curve: TimeTraceMotion.standard,
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.96 : 0.66),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      ),
    );
  }
}
