import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Interactive stacked bar chart: solid = active, translucent = idle.
/// Tap a bar to see details; hover shows tooltip.
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
        apps.map((a) => a.totalSeconds).fold<int>(1, (m, v) => v > m ? v : m);

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
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < apps.take(8).length; i++)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(
                            () => _selected = _selected == i ? null : i),
                        child: Tooltip(
                          message: _tooltip(apps[i]),
                          waitDuration: const Duration(milliseconds: 400),
                          child: _BarColumn(
                            app: apps[i],
                            maxTotal: maxTotal,
                            highlight: _selected == i,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Selected app detail
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
                          '${apps[_selected!].appName}: '
                          '活跃 ${apps[_selected!].activeLabel}'
                          '${apps[_selected!].idleSeconds > 0 ? ' · 挂机 ${apps[_selected!].idleLabel}' : ''}',
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

  String _tooltip(AppUsageItem app) {
    final h = app.activeSeconds ~/ 3600;
    final m = (app.activeSeconds % 3600) ~/ 60;
    final active = h > 0 ? '${h}h${m}m' : '${m}m';
    final idle = app.idleLabel;
    return '${app.appName}\n活跃: $active\n挂机: $idle';
  }
}

class _BarColumn extends StatelessWidget {
  const _BarColumn({
    required this.app,
    required this.maxTotal,
    required this.highlight,
  });

  final AppUsageItem app;
  final int maxTotal;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final base = appColor(app.appName);
    final color = highlight ? base : base.withValues(alpha: 0.8);

    return Padding(
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
          Expanded(
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                if (app.activeSeconds > 0)
                  FractionallySizedBox(
                    heightFactor:
                        (app.activeSeconds / maxTotal).clamp(0.02, 1.0),
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: app.idleSeconds > 0
                            ? BorderRadius.zero
                            : const BorderRadius.vertical(
                                top: Radius.circular(4)),
                      ),
                    ),
                  ),
                if (app.idleSeconds > 0)
                  FractionallySizedBox(
                    heightFactor:
                        ((app.activeSeconds + app.idleSeconds) / maxTotal)
                            .clamp(0.02, 1.0),
                    widthFactor: 1.0,
                    child: FractionallySizedBox(
                      heightFactor: app.idleSeconds /
                          (app.activeSeconds + app.idleSeconds),
                      alignment: Alignment.topCenter,
                      child: Container(
                        decoration: BoxDecoration(
                          color: appColor(app.appName).withValues(alpha: 0.25),
                          borderRadius:
                              const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            app.appName.length > 6 ? app.appName.substring(0, 6) : app.appName,
            style: TextStyle(fontSize: 9, color: highlight ? Theme.of(context).colorScheme.primary : null),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
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
