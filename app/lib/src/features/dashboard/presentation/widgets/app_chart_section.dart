import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Combined chart + app list:
/// - Tall bars (tap to select)
/// - Selected app's page breakdown (Edge → bilibili/github) shown inline
/// - Compact app rows below as the interactive list
class AppChartSection extends ConsumerStatefulWidget {
  const AppChartSection({required this.apps, this.tall = false, super.key});

  final List<AppUsageItem> apps;
  final bool tall;

  @override
  ConsumerState<AppChartSection> createState() => _AppChartSectionState();
}

class _AppChartSectionState extends ConsumerState<AppChartSection> {
  int? _selected;
  List<PageDto>? _pages;
  bool _loadingPages = false;

  Future<void> _select(int i) async {
    final deselecting = _selected == i;
    setState(() {
      _selected = deselecting ? null : i;
      _pages = null;
      _loadingPages = !deselecting; // cancel deselection stops spinner
    });
    if (deselecting) return;
    try {
      final api = ref.read(apiProvider);
      // Use the dashboard's selected range end date, not just today,
      // so pages appear for week/month views too.
      final range = ref.read(dashboardRangeProvider);
      final now = DateTime.now();
      String end;
      switch (range) {
        case DateRange.today:
        case DateRange.week:
        case DateRange.month:
          end = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        case DateRange.yesterday:
          final y = now.subtract(const Duration(days: 1));
          end = '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
      }
      final pages = api.getWindowTitles(appName: widget.apps[i].appName, date: end);
      if (mounted) {
        setState(() {
          _pages = pages;
          _loadingPages = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.apps;
    final maxTotal =
        apps.map((a) => a.activeSeconds).fold<int>(1, (m, v) => v > m ? v : m);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('按应用'),
                const Spacer(),
                Text('${apps.length} 应用 · 点击柱查看页面',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              ],
            ),
            const SizedBox(height: 6),
            // ── Tall bars ──
            SizedBox(
              height: widget.tall ? 130 : 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < apps.take(8).length; i++)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _select(i),
                        child: Tooltip(
                          message:
                              '${apps[i].appName}\n活跃: ${apps[i].activeLabel}',
                          waitDuration: const Duration(milliseconds: 400),
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  apps[i].activeSeconds > 0
                                      ? apps[i].activeLabel
                                      : '',
                                  style: const TextStyle(fontSize: 9),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Expanded(
                                  child: FractionallySizedBox(
                                    alignment: Alignment.bottomCenter,
                                    heightFactor: (apps[i].activeSeconds /
                                            maxTotal)
                                        .clamp(0.02, 1.0),
                                    widthFactor: 1.0,
                                    child: _Bar(
                                      color: appColor(apps[i].appName),
                                      selected: _selected == i,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  apps[i].appName.length > 5
                                      ? apps[i].appName.substring(0, 5)
                                      : apps[i].appName,
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: _selected == i
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: _selected == i
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
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
            // ── Scrollable detail + rows ──
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            // ── Page breakdown for selected app (Edge → bilibili) ──
            if (_loadingPages)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (_selected != null && _pages != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _pages!.isEmpty
                    ? Text('该应用无页面数据',
                        style:
                            TextStyle(fontSize: 11, color: scheme.outline))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${apps[_selected!].appName} 页面',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.primary)),
                          const SizedBox(height: 4),
                          for (final p in _pages!.take(6))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: Row(
                                children: [
                                  Icon(Icons.web_outlined,
                                      size: 12, color: scheme.outline),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      p.title.isEmpty
                                          ? '(主窗口)'
                                          : p.title,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  Text('${p.seconds.toInt() ~/ 60}分',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: scheme.outline)),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 4),
            // ── Interactive app rows (click → highlight bar + show pages) ──
            for (var i = 0; i < apps.take(8).length; i++)
              InkWell(
                onTap: () => _select(i),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _selected == i
                        ? scheme.secondaryContainer.withValues(alpha: 0.5)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      if (widget.apps[i].exePath != null)
                        AppIcon(exePath: widget.apps[i].exePath!, size: 22)
                      else
                        Icon(Icons.apps, size: 18, color: appColor(apps[i].appName)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          apps[i].appName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Text(
                        apps[i].activeLabel,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _selected == i
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: scheme.outline,
                      ),
                    ],
                  ),
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
