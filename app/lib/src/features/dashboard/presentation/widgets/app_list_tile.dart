import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Expandable app row. Rows use alignment and separators rather than a card
/// around every item, keeping dense desktop lists calm and scannable.
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
      final pages = api
          .getWindowTitles(appName: widget.app.appName, date: _rangeEnd(range))
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

  String _rangeEnd(DateRangeSelection sel) {
    final d = sel.effectiveDay;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = appColor(widget.app.appName);
    final l = L10n(ref.watch(localeProvider));

    return Material(
      color: _expanded
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.28)
          : Colors.transparent,
      child: InkWell(
        onTap: _toggle,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  if (widget.app.exePath != null)
                    AppIcon(exePath: widget.app.exePath!, size: 30)
                  else
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.apps_rounded, size: 16, color: color),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.app.appName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.app.idleSeconds > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: Text(
                        '${l.idle} ${widget.app.idleLabel}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Text(
                    widget.app.activeLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              _loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        ),
                      ),
                    )
                  : _PagesList(pages: _pages ?? []),
            ],
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.65)),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (pages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text('暂无页面数据', style: theme.textTheme.bodySmall),
      );
    }
    final total = pages.fold<int>(0, (sum, page) => sum + page.$2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (final (title, seconds) in pages)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.outline,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title.isEmpty ? '(主窗口)' : title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${seconds ~/ 60}分 · ${(seconds / total * 100).round()}%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
