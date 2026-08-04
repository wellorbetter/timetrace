import 'package:flutter/material.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// App distribution list — every row fully expanded (no internal scroll),
/// tap a row to expand its page breakdown INLINE below the row.
class AppListSection extends StatelessWidget {
  const AppListSection({
    required this.apps,
    required this.selected,
    required this.pages,
    required this.loading,
    required this.onSelect,
    required this.rowKeys,
    super.key,
  });

  final List<AppUsageItem> apps;
  final int? selected;
  final List<PageDto>? pages;
  final bool loading;
  final ValueChanged<int> onSelect;
  final List<GlobalKey> rowKeys;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('应用分布', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${apps.length} 个应用 · 点击行查看页面会话',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              ],
            ),
            const SizedBox(height: 4),
            // All rows, fully expanded — no scrolling needed
            for (var i = 0; i < apps.length; i++)
              Column(
                key: rowKeys[i],
                children: [
                  _AppRow(
                    app: apps[i],
                    isSel: selected == i,
                    onTap: () => onSelect(i),
                  ),
                  // Inline page breakdown — right below the tapped row
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: selected == i
                        ? _PageDetail(pages: pages, loading: loading, scheme: scheme)
                        : const SizedBox.shrink(),
                  ),
                  if (i < apps.length - 1) const Divider(height: 1),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.isSel, required this.onTap});

  final AppUsageItem app;
  final bool isSel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSel ? scheme.secondaryContainer.withValues(alpha: 0.5) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            if (app.exePath != null)
              AppIcon(exePath: app.exePath!, size: 22)
            else
              Icon(Icons.apps, size: 18, color: appColor(app.appName)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                app.appName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            // Mini progress bar
            SizedBox(
              width: 90,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: app.activeSeconds /
                      (app.activeSeconds +
                          (app.totalSeconds > app.activeSeconds
                              ? app.totalSeconds - app.activeSeconds
                              : 1)),
                  minHeight: 5,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: appColor(app.appName),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              app.activeLabel,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 4),
            Icon(
              isSel ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 16,
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline page breakdown for the selected app (Edge → bilibili/github).
class _PageDetail extends StatefulWidget {
  const _PageDetail({
    required this.pages,
    required this.loading,
    required this.scheme,
  });

  final List<PageDto>? pages;
  final bool loading;
  final ColorScheme scheme;

  @override
  State<_PageDetail> createState() => _PageDetailState();
}

class _PageDetailState extends State<_PageDetail> {
  bool _showAll = false;

  @override
  void didUpdateWidget(covariant _PageDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset expansion when the selection changes to another app.
    if (oldWidget.pages != widget.pages) _showAll = false;
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.pages;
    final loading = widget.loading;
    final scheme = widget.scheme;
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final list = pages;
    if (list == null) return const SizedBox.shrink();
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 4, 8, 4),
        child: Text('该应用无页面数据',
            style: TextStyle(fontSize: 11, color: scheme.outline)),
      );
    }
    final maxSec = list.map((p) => p.seconds).fold<int>(1, (m, v) => v > m ? v : m);
    final shown = (_showAll ? list : list.take(5)).toList();
    final more = list.length - shown.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 4, 8, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('页面会话',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary)),
          const SizedBox(height: 6),
          for (final p in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.web_outlined, size: 12, color: scheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      p.title.isEmpty ? '(主窗口)' : p.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 50,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (p.seconds / maxSec).clamp(0.02, 1.0),
                        minHeight: 4,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: scheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(formatDuration(p.seconds.toInt()),
                      style:
                          TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => setState(() => _showAll = !_showAll),
                borderRadius: BorderRadius.circular(6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                        _showAll
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 14,
                        color: scheme.primary),
                    const SizedBox(width: 2),
                    Text(
                      _showAll ? '收起' : '展开全部 $more 个页面',
                      style: TextStyle(
                          fontSize: 10,
                          color: scheme.primary,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
