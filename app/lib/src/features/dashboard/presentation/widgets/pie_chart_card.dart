import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Original Overview donut — top five apps plus an aggregated "其他" slice.
/// Compact center text and a one-line legend prevent the chart from becoming
/// cramped when the selected range contains many applications.
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = apps
        .fold<int>(0, (sum, app) => sum + app.activeSeconds)
        .clamp(1, 1 << 62);
    final top = apps.take(5).toList(growable: false);
    final restSeconds = apps
        .skip(5)
        .fold<int>(0, (sum, app) => sum + app.activeSeconds);

    return Card(
      key: const ValueKey('dashboard-app-share'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final legendRows = top.length + (restSeconds > 0 ? 1 : 0);
            final legendHeight = legendRows * 18.0;
            final reserved = 12.0 * 2 + 20.0 + 8.0 + 8.0 + legendHeight + 4.0;
            final diameter = (constraints.maxHeight - reserved)
                .clamp(90.0, 160.0)
                .toDouble();
            final centerSpaceRadius = diameter * 0.31;
            final radius = diameter / 2 - centerSpaceRadius;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('占比', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: SizedBox.square(
                      dimension: diameter,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          PieChart(
                            PieChartData(
                              sectionsSpace: 1,
                              centerSpaceRadius: centerSpaceRadius,
                              startDegreeOffset: -90,
                              pieTouchData: PieTouchData(enabled: false),
                              sections: [
                                for (final app in top)
                                  PieChartSectionData(
                                    value: app.activeSeconds.toDouble(),
                                    color: appColor(app.appName),
                                    radius: radius,
                                    title: '',
                                    showTitle: false,
                                  ),
                                if (restSeconds > 0)
                                  PieChartSectionData(
                                    value: restSeconds.toDouble(),
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
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onSurface,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              Text(
                                '活跃',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 8),
                for (final app in top)
                  SizedBox(
                    height: 18,
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: appColor(app.appName),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Tooltip(
                            message: app.appName,
                            child: Text(
                              app.appName,
                              style: const TextStyle(fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        Text(
                          '${(app.activeSeconds / total * 100).round()}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                if (restSeconds > 0)
                  SizedBox(
                    height: 18,
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text('其他', style: TextStyle(fontSize: 11)),
                        ),
                        Text(
                          '${(restSeconds / total * 100).round()}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
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
