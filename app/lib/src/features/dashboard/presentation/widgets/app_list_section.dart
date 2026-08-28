import 'package:flutter/material.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Dense app ranking with inline page details.
///
/// Deliberately does not attach [rowKeys] to rows. The old implementation fed
/// those keys into Scrollable.ensureVisible from the parent, which caused the
/// outer Overview ListView to jump upward/downward when expanding an app. A
/// clicked row is already visible, so details now expand in place without
/// moving the whole dashboard.
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxActive = apps.fold<int>(1, (max, app) => app.activeSeconds > max ? app.activeSeconds : max);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('应用排行', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${apps.length} 个应用 · 点击原地展开页面会话', style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            for (var i = 0; i < apps.length; i++) ...[
              _AppRow(
                rank: i + 1,
                app: apps[i],
                maxActiveSeconds: maxActive,
                isSelected: selected == i,
                onTap: () => onSelect(i),
              ),
              AnimatedSize(
                duration: TimeTraceMotion.normal,
                curve: TimeTraceMotion.standard,
                alignment: Alignment.topCenter,
                child: selected == i ? _PageDetail(pages: pages, loading: loading) : const SizedBox.shrink(),
              ),
              if (i < apps.length - 1) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.65)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.rank, required this.app, required this.maxActiveSeconds, required this.isSelected, required this.onTap});
  final int rank;
  final AppUsageItem app;
  final int maxActiveSeconds;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = appColor(app.appName);
    final ratio = (app.activeSeconds / maxActiveSeconds).clamp(0.0, 1.0);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      child: AnimatedContainer(
        duration: TimeTraceMotion.fast,
        padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xs, vertical: TimeTraceSpace.xs),
        decoration: BoxDecoration(color: isSelected ? scheme.primaryContainer.withValues(alpha: 0.46) : Colors.transparent, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
        child: Row(
          children: [
            SizedBox(width: 24, child: Text(rank.toString().padLeft(2, '0'), style: theme.textTheme.labelSmall)),
            const SizedBox(width: TimeTraceSpace.xxs),
            if (app.exePath != null && app.exePath!.isNotEmpty)
              AppIcon(exePath: app.exePath!, size: 24)
            else
              Container(width: 24, height: 24, alignment: Alignment.center, decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(TimeTraceRadius.control)), child: Icon(Icons.apps_rounded, size: 14, color: color)),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(child: Text(app.appName, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500))),
            SizedBox(width: 90, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: ratio, minHeight: 4, backgroundColor: scheme.surfaceContainerHighest, color: color.withValues(alpha: 0.82)))),
            const SizedBox(width: TimeTraceSpace.xs),
            SizedBox(width: 60, child: Text(app.activeLabel, textAlign: TextAlign.right, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600))),
            const SizedBox(width: TimeTraceSpace.xxs),
            AnimatedRotation(turns: isSelected ? 0.5 : 0, duration: TimeTraceMotion.fast, child: Icon(Icons.keyboard_arrow_down_rounded, size: 17, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _PageDetail extends StatefulWidget {
  const _PageDetail({required this.pages, required this.loading});
  final List<PageDto>? pages;
  final bool loading;

  @override
  State<_PageDetail> createState() => _PageDetailState();
}

class _PageDetailState extends State<_PageDetail> {
  bool _showAll = false;

  @override
  void didUpdateWidget(covariant _PageDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pages != widget.pages) _showAll = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pages = widget.pages;
    if (widget.loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: TimeTraceSpace.sm), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.8))));
    }
    if (pages == null) return const SizedBox.shrink();
    if (pages.isEmpty) return Padding(padding: const EdgeInsets.fromLTRB(TimeTraceSpace.xl, TimeTraceSpace.xxs, TimeTraceSpace.xs, TimeTraceSpace.xs), child: Text('该应用无页面数据', style: theme.textTheme.labelSmall));

    final maxSeconds = pages.map((page) => page.seconds).fold<int>(1, (max, value) => value > max ? value : max);
    final shown = (_showAll ? pages : pages.take(5)).toList();
    final more = pages.length - shown.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(TimeTraceSpace.xl, TimeTraceSpace.xxs, TimeTraceSpace.xs, TimeTraceSpace.xs),
      padding: const EdgeInsets.fromLTRB(TimeTraceSpace.sm, TimeTraceSpace.xs, TimeTraceSpace.xs, TimeTraceSpace.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.62), width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('页面会话', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: TimeTraceSpace.xs),
          for (final page in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xxs),
              child: Row(
                children: [
                  Icon(Icons.web_outlined, size: 12, color: scheme.onSurfaceVariant),
                  const SizedBox(width: TimeTraceSpace.xxs),
                  Expanded(child: Text(page.title.isEmpty ? '(主窗口)' : page.title, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface))),
                  const SizedBox(width: TimeTraceSpace.xs),
                  SizedBox(width: 48, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: (page.seconds / maxSeconds).clamp(0.02, 1.0), minHeight: 3, backgroundColor: scheme.outlineVariant, color: scheme.primary.withValues(alpha: 0.62)))),
                  const SizedBox(width: TimeTraceSpace.xs),
                  SizedBox(width: 48, child: Text(formatDuration(page.seconds.toInt()), textAlign: TextAlign.right, style: theme.textTheme.labelSmall)),
                ],
              ),
            ),
          if (more > 0 || _showAll)
            TextButton.icon(
              onPressed: () => setState(() => _showAll = !_showAll),
              icon: Icon(_showAll ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 14),
              label: Text(_showAll ? '收起' : '展开全部 $more 个页面'),
            ),
        ],
      ),
    );
  }
}
