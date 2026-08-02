import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Pie chart with legend showing app usage distribution.
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
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
            SizedBox(
              height: 140,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 20,
                  sections: apps.take(8).map((app) {
                    return PieChartSectionData(
                      value: app.activeSeconds.toDouble(),
                      color: appColor(app.appName),
                      radius: 40,
                      title: '',
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
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
                    Text('${app.appName} $pct%',
                        style: const TextStyle(fontSize: 11)),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
