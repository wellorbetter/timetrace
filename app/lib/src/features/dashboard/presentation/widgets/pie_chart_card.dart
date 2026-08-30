import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart with a side legend on desktop.
///
/// Only four applications are drawn individually; every remaining application
/// is grouped as "其他". This keeps the chart to five readable categories and
/// leaves enough room for direct labels instead of squeezing the donut above a
/// tall legend.
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
        .fold<int>(0, (sum, app) => sum + app.activeSeconds)
        .clamp(1, 1 << 62);
    final top = apps.take(4).toList(growable: false);
    final remainderSeconds = apps
        .skip(4)
        .fold<int>(0, (sum, app) => sum + app.activeSeconds);
    final selectedTop =
        selectedIndex != null &&
            selectedIndex! >= 0 &&
            selectedIndex! < top.length
        ? selectedIndex
        : null;

    return Card(
      key: const ValueKey('dashboard-app-share'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final sideBySide = constraints.maxWidth >= 520;
            final legend = _Legend(
              apps: top,
              total: total,
              remainderSeconds: remainderSeconds,
              selectedIndex: selectedTop,
              onSelectApp: onSelectApp,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('应用占比', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      apps.length > 4 ? '前 4 项 + 其他' : '${apps.length} 项',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                Expanded(
                  child: sideBySide
                      ? Row(
                          children: [
                            Expanded(
                              flex: 5,
                              child: _Donut(
                                apps: top,
                                total: total,
                                remainderSeconds: remainderSeconds,
                                selectedIndex: selectedTop,
                                onSelectApp: onSelectApp,
                              ),
                            ),
                            VerticalDivider(
                              width: TimeTraceSpace.lg,
                              thickness: 1,
                              color: scheme.outlineVariant,
                            ),
                            Expanded(flex: 7, child: legend),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(
                              flex: 5,
                              child: _Donut(
                                apps: top,
                                total: total,
                                remainderSeconds: remainderSeconds,
                                selectedIndex: selectedTop,
                                onSelectApp: onSelectApp,
                              ),
                            ),
                            const SizedBox(height: TimeTraceSpace.xs),
                            Expanded(flex: 6, child: legend),
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

class _Donut extends StatelessWidget {
  const _Donut({
    required this.apps,
    required this.total,
    required this.remainderSeconds,
    required this.selectedIndex,
    required this.onSelectApp,
  });

  final List<AppUsageItem> apps;
  final int total;
  final int remainderSeconds;
  final int? selectedIndex;
  final ValueChanged<int>? onSelectApp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = constraints.biggest.shortestSide
            .clamp(112.0, 190.0)
            .toDouble();
        final centerRadius = diameter * 0.29;
        final ringRadius = diameter / 2 - centerRadius - 3;

        return Center(
          child: SizedBox.square(
            dimension: diameter,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Semantics(
                  label: '应用占比图，总活跃时长 ${formatDuration(total)}',
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: centerRadius,
                      startDegreeOffset: -90,
                      pieTouchData: PieTouchData(
                        enabled: onSelectApp != null,
                        touchCallback: (event, response) {
                          if (event is! FlTapUpEvent) return;
                          final index =
                              response?.touchedSection?.touchedSectionIndex;
                          if (index == null ||
                              index < 0 ||
                              index >= apps.length) {
                            return;
                          }
                          onSelectApp?.call(index);
                        },
                      ),
                      sections: [
                        for (var index = 0; index < apps.length; index++)
                          PieChartSectionData(
                            value: apps[index].activeSeconds.toDouble(),
                            color: appColor(apps[index].appName).withValues(
                              alpha:
                                  selectedIndex == null ||
                                      selectedIndex == index
                                  ? 0.92
                                  : 0.35,
                            ),
                            radius: selectedIndex == index
                                ? ringRadius + 3
                                : ringRadius,
                            title: '',
                            showTitle: false,
                          ),
                        if (remainderSeconds > 0)
                          PieChartSectionData(
                            value: remainderSeconds.toDouble(),
                            color: scheme.outline.withValues(alpha: 0.62),
                            radius: ringRadius,
                            title: '',
                            showTitle: false,
                          ),
                      ],
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatDuration(total),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '总活跃',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.apps,
    required this.total,
    required this.remainderSeconds,
    required this.selectedIndex,
    required this.onSelectApp,
  });

  final List<AppUsageItem> apps;
  final int total;
  final int remainderSeconds;
  final int? selectedIndex;
  final ValueChanged<int>? onSelectApp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[
      for (var index = 0; index < apps.length; index++)
        _LegendRow(
          key: ValueKey('pie-legend-$index'),
          color: appColor(apps[index].appName),
          label: apps[index].appName,
          duration: apps[index].activeLabel,
          percent: (apps[index].activeSeconds / total * 100).round(),
          selected: selectedIndex == index,
          onTap: onSelectApp == null ? null : () => onSelectApp!(index),
        ),
      if (remainderSeconds > 0)
        _LegendRow(
          color: scheme.outline.withValues(alpha: 0.62),
          label: '其他',
          duration: formatDuration(remainderSeconds),
          percent: (remainderSeconds / total * 100).round(),
          selected: false,
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const rowHeight = 42.0;
        final desiredHeight =
            rows.length * rowHeight + (rows.length - 1).clamp(0, 99);
        final height = desiredHeight
            .clamp(0.0, constraints.maxHeight)
            .toDouble();
        return Center(
          child: SizedBox(
            height: height,
            child: ListView.separated(
              primary: false,
              padding: EdgeInsets.zero,
              physics: desiredHeight <= constraints.maxHeight
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemCount: rows.length,
              itemBuilder: (context, index) =>
                  SizedBox(height: rowHeight, child: rows[index]),
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: scheme.outlineVariant),
            ),
          ),
        );
      },
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    super.key,
    required this.color,
    required this.label,
    required this.duration,
    required this.percent,
    required this.selected,
    this.onTap,
  });

  final Color color;
  final String label;
  final String duration;
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
      label: '$label，占比 $percent%，活跃 $duration',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xs),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Expanded(
                  child: Tooltip(
                    message: label,
                    child: Text(
                      label,
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
                if (selected) ...[
                  Icon(Icons.link_rounded, size: 14, color: scheme.primary),
                  const SizedBox(width: TimeTraceSpace.xs),
                ],
                Text(
                  duration,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                SizedBox(
                  width: 34,
                  child: Text(
                    '$percent%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
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
