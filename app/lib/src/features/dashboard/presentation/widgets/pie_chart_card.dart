import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart — top 5 apps + aggregated 其他 (no tiny-slice seams).
/// Compact center text, legend matches slices exactly.
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        apps.fold<int>(0, (s, a) => s + a.activeSeconds).clamp(1, 1 << 62);
    final top = apps.take(5).toList();
    final rest = apps.skip(5).toList();
    final restSec = rest.fold<int>(0, (s, a) => s + a.activeSeconds);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 1,
                          centerSpaceRadius: 50,
                          startDegreeOffset: -90,
                          pieTouchData: PieTouchData(enabled: false),
                          sections: [
                            for (final app in top)
                              PieChartSectionData(
                                value: app.activeSeconds.toDouble(),
                                color: appColor(app.appName),
                                radius: 80 - 50,
                                title: '',
                                showTitle: false,
                              ),
                            if (restSec > 0)
                              PieChartSectionData(
                                value: restSec.toDouble(),
                                color: scheme.surfaceContainerHighest,
                                radius: 80 - 50,
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
                                  FontFeature.tabularFigures()
                                ]),
                          ),
                          Text('活跃',
                              style: TextStyle(
                                  fontSize: 10, color: scheme.outline)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 12),
            // Legend — top 5 + 其他
            for (final app in top)
              SizedBox(
                height: 22,
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
                      child: Text(app.appName,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${(app.activeSeconds / total * 100).round()}%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
            if (restSec > 0)
              SizedBox(
                height: 22,
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
                      child: Text('其他',
                          style: TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${(restSec / total * 100).round()}%',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
