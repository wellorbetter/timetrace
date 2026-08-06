import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Bar chart only — tap a bar to select that app.
/// The selected app's page breakdown appears in the AppListSection below,
/// so there's no need to scroll up to see the detail.
class AppChartSection extends StatelessWidget {
  const AppChartSection({
    required this.apps,
    required this.selected,
    required this.onSelect,
    this.tall = false,
    super.key,
  });

  final List<AppUsageItem> apps;
  final int? selected;
  final ValueChanged<int> onSelect;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final maxTotal = apps
        .map((a) => a.activeSeconds)
        .fold<int>(1, (m, v) => v > m ? v : m);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Narrow cards or too many apps cap at 6 bars so each bar stays
            // wide enough; wide cards keep the previous 8-bar layout.
            final maxBars = constraints.maxWidth < 480 || apps.length > 6
                ? 6
                : 8;
            final count = apps.length > maxBars ? maxBars : apps.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '按应用',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text(
                      '${apps.length} 应用 · 点击柱查看会话',
                      style: TextStyle(fontSize: 10, color: scheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // ── Bars ──
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < count; i++)
                        Expanded(
                          child: GestureDetector(
                            onTap: () => onSelect(i),
                            child: Tooltip(
                              message:
                                  '${apps[i].appName}\n活跃: ${apps[i].activeLabel}',
                              waitDuration: const Duration(milliseconds: 400),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(
                                      apps[i].activeSeconds > 0
                                          ? apps[i].activeLabel
                                          : '',
                                      style: const TextStyle(fontSize: 10),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Expanded(
                                      child: FractionallySizedBox(
                                        alignment: Alignment.bottomCenter,
                                        heightFactor:
                                            (apps[i].activeSeconds / maxTotal)
                                                .clamp(0.02, 1.0),
                                        widthFactor: 1.0,
                                        child: _Bar(
                                          color: appColor(apps[i].appName),
                                          selected: selected == i,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    // Full app name, scaled down to fit;
                                    // ellipsis stays as a fallback.
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        apps[i].appName,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: selected == i
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: selected == i
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

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
        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
      ),
    );
  }
}
