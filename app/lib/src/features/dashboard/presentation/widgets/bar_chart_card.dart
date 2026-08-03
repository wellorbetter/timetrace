import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Stacked bar chart: solid color = active, translucent same-hue = idle.
class BarChartCard extends StatelessWidget {
  const BarChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    // Scale to the max TOTAL so stacked bars stay comparable.
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
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            // Fixed height; labels are fixed-size, bar area is Expanded →
            // no RenderFlex overflow regardless of font metrics.
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Bar area — Expanded absorbs all remaining height.
                            Expanded(
                              child: Stack(
                                alignment: Alignment.bottomCenter,
                                children: [
                                  // Active segment: solid color from bottom
                                  if (app.activeSeconds > 0)
                                    FractionallySizedBox(
                                      heightFactor:
                                          (app.activeSeconds / maxTotal)
                                              .clamp(0.02, 1.0),
                                      widthFactor: 1.0,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: appColor(app.appName),
                                          borderRadius:
                                              app.idleSeconds > 0
                                                  ? BorderRadius.zero
                                                  : const BorderRadius.vertical(
                                                      top: Radius.circular(4)),
                                        ),
                                      ),
                                    ),
                                  // Idle segment: translucent, on TOP of active
                                  if (app.idleSeconds > 0)
                                    FractionallySizedBox(
                                      heightFactor:
                                          ((app.activeSeconds + app.idleSeconds) /
                                                  maxTotal)
                                              .clamp(0.02, 1.0),
                                      widthFactor: 1.0,
                                      child: FractionallySizedBox(
                                        heightFactor: app.idleSeconds /
                                            (app.activeSeconds + app.idleSeconds),
                                        alignment: Alignment.topCenter,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: appColor(app.appName)
                                                .withValues(alpha: 0.25),
                                            borderRadius:
                                                const BorderRadius.vertical(
                                                    top: Radius.circular(4)),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              app.appName.length > 6
                                  ? app.appName.substring(0, 6)
                                  : app.appName,
                              style: const TextStyle(fontSize: 9),
                              maxLines: 1,
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
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
