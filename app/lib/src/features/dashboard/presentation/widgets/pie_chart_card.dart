import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart — top 5 apps + aggregated "其他" (no tiny-slice seams).
/// Clean center text, compact legend, no lines/overlap on the ring.
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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比'),
            // Donut centered in available space
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 150,
                  height: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 1,
                          centerSpaceRadius: 48,
                          startDegreeOffset: -90,
                          pieTouchData: PieTouchData(enabled: false),
                          sections: [
                            for (final app in top)
                              PieChartSectionData(
                                value: app.activeSeconds.toDouble(),
                                color: appColor(app.appName),
                                radius: 75 - 48,
                                title: '',
                                showTitle: false,
                              ),
                            if (restSec > 0)
                              PieChartSectionData(
                                value: restSec.toDouble(),
                                color: scheme.surfaceContainerHighest,
                                radius: 75 - 48,
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
                            _fmt(total),
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: scheme.onSurface),
                          ),
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
            // Legend — top 5 + 其他, compact rows
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final app in top)
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
                  if (restSec > 0)
                    SizedBox(
                      height: 20,
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
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
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
    return h > 0 ? '${h}时${m}分' : '${m}分';
  }
}
