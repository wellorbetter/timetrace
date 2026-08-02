import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Stacked bar chart showing active + idle time per app.
class BarChartCard extends StatelessWidget {
  const BarChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
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
                            Text(app.activeLabel,
                                style: const TextStyle(fontSize: 10)),
                            if (app.idleSeconds > 0)
                              Container(
                                height: (app.idleSeconds / maxTotal) * 100,
                                decoration: BoxDecoration(
                                  color: Colors.grey.withValues(alpha: 0.35),
                                  borderRadius: const BorderRadius.vertical(
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
