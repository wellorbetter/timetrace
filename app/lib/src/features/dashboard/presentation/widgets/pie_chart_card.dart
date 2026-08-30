import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart — top five apps plus an aggregated remainder. The chart stays
/// deliberately quiet so the labels and proportions remain the focus.
class PieChartCard extends StatelessWidget {
  const PieChartCard({
    required this.apps,
    this.selectedIndex,
    this.onSelectApp,
    super.key,
  });

  final List<AppUsageItem> apps;
  final int? selectedIndex;
  final ValueChanged<int>? onSelectApp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = apps
        .fold<int>(0, (s, a) => s + a.activeSeconds)
        .clamp(1, 1 << 62);
    final top = apps.take(5).toList();
    final rest = apps.skip(5).toList();
    final restSec = rest.fold<int>(0, (s, a) => s + a.activeSeconds);
    final selectedTop =
        selectedIndex != null &&
            selectedIndex! >= 0 &&
            selectedIndex! < top.length
        ? selectedIndex
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final legendRows = top.length + (restSec > 0 ? 1 : 0);
            final legendH = legendRows * 28.0;
            final reserved = 24.0 + 20.0 + 8.0 + legendH + 8.0;
            final diameter = (constraints.maxHeight - reserved)
                .clamp(90.0, 160.0)
                .toDouble();
            final centerSpaceRadius = diameter * 0.31;
            final radius = diameter / 2 - centerSpaceRadius;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '占比',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: diameter,
                      height: diameter,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          PieChart(
                            PieChartData(
                              sectionsSpace: 1,
                              centerSpaceRadius: centerSpaceRadius,
                              startDegreeOffset: -90,
                              pieTouchData: PieTouchData(
                                enabled: onSelectApp != null,
                                touchCallback: (event, response) {
                                  if (event is! FlTapUpEvent) return;
                                  final index = response
                                      ?.touchedSection
                                      ?.touchedSectionIndex;
                                  if (index == null ||
                                      index < 0 ||
                                      index >= top.length) {
                                    return;
                                  }
                                  onSelectApp?.call(index);
                                },
                              ),
                              sections: [
                                for (var index = 0; index < top.length; index++)
                                  PieChartSectionData(
                                    value: top[index].activeSeconds.toDouble(),
                                    color: appColor(top[index].appName)
                                        .withValues(
                                          alpha:
                                              selectedTop == null ||
                                                  selectedTop == index
                                              ? 1
                                              : 0.38,
                                        ),
                                    radius: selectedTop == index
                                        ? radius + 4
                                        : radius,
                                    title: '',
                                    showTitle: false,
                                  ),
                                if (restSec > 0)
                                  PieChartSectionData(
                                    value: restSec.toDouble(),
                                    color: scheme.surfaceContainerHighest,
                                    radius: radius,
                                    title: '',
                                    showTitle: false,
                                  ),
                              ],
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                formatDuration(total),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              Text(
                                '活跃',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: TimeTraceSpace.xs),
                for (var index = 0; index < top.length; index++)
                  _LegendRow(
                    key: ValueKey('pie-legend-$index'),
                    color: appColor(top[index].appName),
                    label: top[index].appName,
                    percent: (top[index].activeSeconds / total * 100).round(),
                    selected: selectedTop == index,
                    onTap: onSelectApp == null
                        ? null
                        : () => onSelectApp!(index),
                  ),
                if (restSec > 0)
                  _LegendRow(
                    color: scheme.surfaceContainerHighest,
                    label: '其他',
                    percent: (restSec / total * 100).round(),
                    selected: false,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    super.key,
    required this.color,
    required this.label,
    required this.percent,
    required this.selected,
    this.onTap,
  });

  final Color color;
  final String label;
  final int percent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$label，占比 $percent%',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(TimeTraceRadius.small),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TimeTraceRadius.small),
          child: SizedBox(
            height: 28,
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected) ...[
                  Icon(Icons.link_rounded, size: 13, color: scheme.primary),
                  const SizedBox(width: TimeTraceSpace.xxs),
                ],
                Text(
                  '$percent%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
