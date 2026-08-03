import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Interactive bar chart: solid gradient bars, value labels, tap to inspect.
/// (Idle segment removed — not needed per product feedback.)
class BarChartCard extends StatefulWidget {
  const BarChartCard({required this.apps, super.key});

  final List<AppUsageItem> apps;

  @override
  State<BarChartCard> createState() => _BarChartCardState();
}

class _BarChartCardState extends State<BarChartCard> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final apps = widget.apps;
    final maxTotal =
        apps.map((a) => a.activeSeconds).fold<int>(1, (m, v) => v > m ? v : m);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('按应用'),
            const SizedBox(height: 6),
            // Baseline gridline + bars
            SizedBox(
              height: 140,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < apps.take(8).length; i++)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(
                            () => _selected = _selected == i ? null : i),
                        child: Tooltip(
                          message: '${apps[i].appName}\n活跃: ${apps[i].activeLabel}',
                          waitDuration: const Duration(milliseconds: 400),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // Value label
                                Text(
                                  apps[i].activeSeconds > 0
                                      ? apps[i].activeLabel
                                      : '',
                                  style: const TextStyle(fontSize: 9),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                // Bar with gradient + rounded top
                                Expanded(
                                  child: FractionallySizedBox(
                                    heightFactor:
                                        (apps[i].activeSeconds / maxTotal)
                                            .clamp(0.02, 1.0),
                                    widthFactor: 1.0,
                                    child: _Bar(
                                      color: appColor(apps[i].appName),
                                      selected: _selected == i,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Name
                                Text(
                                  apps[i].appName.length > 6
                                      ? apps[i].appName.substring(0, 6)
                                      : apps[i].appName,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: _selected == i
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: _selected == i
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Selected detail
            if (_selected != null && _selected! < apps.length)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Container(
                  key: ValueKey(_selected),
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .secondaryContainer
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.touch_app_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${apps[_selected!].appName}: 活跃 ${apps[_selected!].activeLabel}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Single bar with vertical gradient + rounded top.
class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final base = selected ? color : color.withValues(alpha: 0.78);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [base.withValues(alpha: 0.55), base],
        ),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(5)),
      ),
    );
  }
}
