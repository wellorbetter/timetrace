import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart that fills its card height — donut centered, legend below.
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        apps.fold<int>(0, (s, a) => s + a.activeSeconds).clamp(1, 1 << 62);
    final slices = apps.take(8).toList();
    final legend = slices.take(6).toList();
    final more = slices.length - legend.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比'),
            // Donut centered in available space (fills card height)
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 140,
                  height: 140,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 44,
                          startDegreeOffset: -90,
                          pieTouchData: PieTouchData(enabled: false),
                          sections: slices.map((app) {
                            return PieChartSectionData(
                              value: app.activeSeconds.toDouble(),
                              color: appColor(app.appName),
                              radius: 70 - 44, // ring 44→70
                              title: '',
                              showTitle: false,
                            );
                          }).toList(),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_fmt(total),
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: scheme.onSurface)),
                          Text('活跃',
                              style: TextStyle(
                                  fontSize: 9, color: scheme.outline)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 10),
            // Legend — capped at 6 rows + "+N more" (no overlap / overflow)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final app in legend)
                    SizedBox(
                      height: 20,
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
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  if (more > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('+$more 个应用（见下方列表）',
                          style: TextStyle(
                              fontSize: 10, color: scheme.outline)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}h${m}m' : '${m}m';
  }
}
