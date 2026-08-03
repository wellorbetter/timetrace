import 'dart:developer';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Donut chart with clean legend (fixed rows, no overlap).
class PieChartCard extends StatelessWidget {
  const PieChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        apps.fold<int>(0, (s, a) => s + a.activeSeconds).clamp(1, 1 << 62);

    // ── Debug: log the exact slice values fed to fl_chart ──
    final slices = apps.take(8).toList();
    log('[PieChart] total=$total slices=${slices.length} '
        'values=${slices.map((a) => a.activeSeconds).join(',')} '
        'pcts=${slices.map((a) => (a.activeSeconds / total * 100).round()).join(',')}');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比'),
            const SizedBox(height: 6),
            // Donut — fixed 120px box, ring fits exactly, center text sized.
            Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 38,
                        startDegreeOffset: -90,
                        pieTouchData: PieTouchData(enabled: false),
                        sections: slices.map((app) {
                          return PieChartSectionData(
                            value: app.activeSeconds.toDouble(),
                            color: appColor(app.appName),
                            radius: 60 - 38, // ring from 38 to 60
                            title: '',
                            showTitle: false,
                          );
                        }).toList(),
                      ),
                    ),
                    // Center total — sized to fit inside 38px radius (76px circle)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _fmt(total),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          '活跃',
                          style: TextStyle(fontSize: 8, color: scheme.outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            // Legend — plain Column with fixed 20px rows (no GridView overlap)
            for (final app in slices)
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
                      child: Text(
                        app.appName,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
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
