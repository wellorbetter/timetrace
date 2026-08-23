import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Expandable app row with real icon; tap reveals per-page breakdown.
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
      final end = ref.read(dashboardRangeBoundsProvider).end;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = appColor(widget.app.appName);
    final l = L10n(ref.watch(localeProvider));

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _toggle,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // Real icon if available
                  if (widget.app.exePath != null)
                    AppIcon(exePath: widget.app.exePath!, size: 32)
                  else
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.apps, size: 18, color: color),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.app.appName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.app.idleSeconds > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        '${l.idle} ${widget.app.idleLabel}',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ),
                  Text(
                    widget.app.activeLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: scheme.outline,
                  ),
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
                  : _PagesList(pages: _pages ?? []),
            ],
          ],
        ),
      ),
    );
  }
}

class _PagesList extends StatelessWidget {
  const _PagesList({required this.pages});

  final List<(String, int)> pages;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (pages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '暂无页面数据',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      );
    }
    final total = pages.fold<int>(0, (s, p) => s + p.$2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (final (title, seconds) in pages)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Row(
                children: [
                  Icon(Icons.web_outlined, size: 14, color: scheme.outline),
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
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
