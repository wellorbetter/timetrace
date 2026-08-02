import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Expandable app row; tapping reveals per-page breakdown.
class AppListTile extends ConsumerStatefulWidget {
  const AppListTile({required this.app, super.key});

  final AppUsageItem app;

  @override
  ConsumerState<AppListTile> createState() => _AppListTileState();
}

class _AppListTileState extends ConsumerState<AppListTile> {
  bool _expanded = false;
  List<(String, int)>? _pages;
  bool _loading = false;

  Future<void> _toggle() async {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) _loading = true;
    });
    if (_expanded) {
      final api = ref.read(apiProvider);
      final range = ref.read(dashboardRangeProvider);
      final end = _rangeEnd(range);
      final pages = api
          .getWindowTitles(appName: widget.app.appName, date: end)
          .map((p) => (p.title, p.seconds.toInt()))
          .toList();
      if (mounted) {
        setState(() {
          _pages = pages;
          _loading = false;
        });
      }
    }
  }

  String _rangeEnd(DateRange range) {
    final now = DateTime.now();
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    switch (range) {
      case DateRange.today:
        return fmt(now);
      case DateRange.yesterday:
        return fmt(now.subtract(const Duration(days: 1)));
      case DateRange.week:
        return fmt(now);
      case DateRange.month:
        return fmt(now);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = appColor(widget.app.appName);
    final activeLabel = widget.app.activeLabel;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: _toggle,
        child: Column(
          children: [
            ListTile(
              leading: widget.app.exePath != null
                  ? AppIcon(exePath: widget.app.exePath!, size: 32)
                  : Icon(Icons.apps, color: color),
              title: Text(widget.app.appName, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.app.idleSeconds > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('挂机 ${widget.app.idleLabel}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ),
                  Text(activeLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                ],
              ),
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              _loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  : _PagesList(pages: _pages ?? [], appColor: color),
            ],
          ],
        ),
      ),
    );
  }
}

class _PagesList extends StatelessWidget {
  const _PagesList({required this.pages, required this.appColor});

  final List<(String, int)> pages;
  final Color appColor;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('暂无页面数据', style: TextStyle(color: Colors.grey)),
      );
    }
    final total = pages.fold<int>(0, (s, p) => s + p.$2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (final (title, seconds) in pages)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.web_outlined, size: 14, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title.isEmpty ? '(主窗口)' : title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${seconds ~/ 60}分 (${(seconds / total * 100).round()}%)',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
