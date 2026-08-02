import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Stacked bar chart: solid color = active, translucent same-hue = idle.
class BarChartCard extends StatelessWidget {
  const BarChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    // Scale to the max TOTAL (active + idle) so stacked bars stay comparable.
    final maxTotal = apps
        .map((a) => a.totalSeconds)
        .fold<int>(1, (m, v) => v > m ? v : m);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('按应用'),
            const SizedBox(height: 12),
            // Legend: active / idle
            Row(
              children: [
                _LegendDot(color: appColor('x'), label: '活跃'),
                const SizedBox(width: 12),
                _LegendDot(
                  color: appColor('x').withValues(alpha: 0.25),
                  label: '挂机',
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final app in apps.take(8))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              app.activeSeconds > 0 ? app.activeLabel : '',
                              style: const TextStyle(fontSize: 10),
                            ),
                            // Stacked column: active (bottom) + idle (top)
                            SizedBox(
                              height: 120,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (app.idleSeconds > 0)
                                    Container(
                                      height: (app.idleSeconds / maxTotal) *
                                          120,
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: appColor(app.appName)
                                            .withValues(alpha: 0.25),
                                        borderRadius: app.activeSeconds > 0
                                            ? BorderRadius.zero
                                            : const BorderRadius.vertical(
                                                top: Radius.circular(4)),
                                      ),
                                    ),
                                  if (app.activeSeconds > 0)
                                    Expanded(
                                      child: Container(
                                        width: double.infinity,
                                        decoration: BoxDecoration(
                                          color: appColor(app.appName),
                                          borderRadius: app.idleSeconds > 0
                                              ? BorderRadius.zero
                                              : const BorderRadius.vertical(
                                                  top: Radius.circular(4)),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              app.appName.length > 6
                                  ? app.appName.substring(0, 6)
                                  : app.appName,
                              style: const TextStyle(fontSize: 9),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
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
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
