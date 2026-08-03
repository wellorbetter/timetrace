import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart with legend-only labels — handles small slices cleanly
/// (no inline label overlap, no touch-animation glitches).
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        apps.fold<int>(0, (s, a) => s + a.activeSeconds).clamp(1, 1 << 62);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比'),
            const SizedBox(height: 8),
            // Donut with center total
            SizedBox(
              height: 150,
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PieChart(
                    PieChartData(
                      sectionsSpace: 1,
                      centerSpaceRadius: 38,
                      startDegreeOffset: -90,
                      // Disable touch animation (avoids small-slice jank)
                      pieTouchData: PieTouchData(enabled: false),
                      sections: apps.take(8).map((app) {
                        return PieChartSectionData(
                          value: app.activeSeconds.toDouble(),
                          color: appColor(app.appName),
                          radius: 52,
                          title: '',
                          showTitle: false,
                        );
                      }).toList(),
                    ),
                  ),
                  // Center: total active
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _fmt(total),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        '活跃',
                        style:
                            TextStyle(fontSize: 10, color: scheme.outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Legend (primary label source — works for tiny slices)
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: apps.take(8).map((app) {
                final pct = (app.activeSeconds / total * 100).round();
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: appColor(app.appName),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${app.appName} $pct%',
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                );
              }).toList(),
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
