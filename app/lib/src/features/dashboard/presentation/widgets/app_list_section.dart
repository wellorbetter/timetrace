import 'package:flutter/material.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Desktop app distribution list. Rows stay dense and aligned; details expand
/// inline without introducing another nested card surface.
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
    final maxActive = apps.fold<int>(
      1,
      (max, app) => app.activeSeconds > max ? app.activeSeconds : max,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '应用排行',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${apps.length} 个应用 · 点击查看页面会话',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            for (var i = 0; i < apps.length; i++)
              Column(
                key: rowKeys[i],
                children: [
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
                    child: selected == i
                        ? _PageDetail(
                            pages: pages,
                            loading: loading,
                            scheme: scheme,
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (i < apps.length - 1)
                    Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.65),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.rank,
    required this.app,
    required this.maxActiveSeconds,
    required this.isSelected,
    required this.onTap,
  });

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
    final rankingRatio = (app.activeSeconds / maxActiveSeconds).clamp(0.0, 1.0);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      child: AnimatedContainer(
        duration: TimeTraceMotion.fast,
        curve: TimeTraceMotion.standard,
        padding: const EdgeInsets.symmetric(
          horizontal: TimeTraceSpace.xs,
          vertical: TimeTraceSpace.xs,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? scheme.primaryContainer.withValues(alpha: 0.46)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                rank.toString().padLeft(2, '0'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xxs),
            if (app.exePath != null && app.exePath!.isNotEmpty)
              AppIcon(exePath: app.exePath!, size: 24)
            else
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Icon(Icons.apps_rounded, size: 14, color: color),
              ),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(
              child: Text(
                app.appName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            SizedBox(
              width: 90,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: rankingRatio,
                  minHeight: 4,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: color.withValues(alpha: 0.82),
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            SizedBox(
              width: 60,
              child: Text(
                app.activeLabel,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xxs),
            AnimatedRotation(
              turns: isSelected ? 0.5 : 0,
              duration: TimeTraceMotion.fast,
              curve: TimeTraceMotion.standard,
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline page breakdown for the selected app. A narrow accent rail carries the
/// hierarchy instead of another card nested inside the app list card.
class _PageDetail extends StatelessWidget {
  const _PageDetail({
    required this.pages,
    required this.loading,
    required this.scheme,
  });

  final List<PageDto>? pages;
  final bool loading;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = this.scheme;
    final detailPages = pages;

    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: TimeTraceSpace.sm),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        ),
      );
    }
    if (detailPages == null) return const SizedBox.shrink();
    if (detailPages.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          TimeTraceSpace.xl,
          TimeTraceSpace.xxs,
          TimeTraceSpace.xs,
          TimeTraceSpace.xs,
        ),
        child: Text(
          '该应用无页面数据',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final maxSeconds = detailPages
        .map((page) => page.seconds)
        .fold<int>(1, (max, value) => value > max ? value : max);
    final visibleRows = detailPages.length.clamp(1, 4).toInt();
    final listHeight = visibleRows * 30.0;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        TimeTraceSpace.xl,
        TimeTraceSpace.xxs,
        TimeTraceSpace.xs,
        TimeTraceSpace.xs,
      ),
      padding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.sm,
        TimeTraceSpace.xs,
        TimeTraceSpace.xs,
        TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
        border: Border(
          left: BorderSide(
            color: scheme.primary.withValues(alpha: 0.52),
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '页面会话',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${detailPages.length} 项 · 区域内滚动',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.xs),
          SizedBox(
            key: const ValueKey('app-page-detail-list'),
            height: listHeight,
            child: ListView.builder(
              primary: false,
              padding: EdgeInsets.zero,
              itemCount: detailPages.length,
              itemBuilder: (context, index) {
                final page = detailPages[index];
                final label = page.title.isEmpty ? '(主窗口)' : page.title;
                return SizedBox(
                  height: 30,
                  child: Row(
                    children: [
                      Icon(
                        Icons.web_outlined,
                        size: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: TimeTraceSpace.xxs),
                      Expanded(
                        child: Tooltip(
                          message: label,
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.xs),
                      SizedBox(
                        width: 48,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: (page.seconds / maxSeconds).clamp(0.02, 1.0),
                            minHeight: 3,
                            backgroundColor: scheme.outlineVariant,
                            color: scheme.primary.withValues(alpha: 0.52),
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.xs),
                      SizedBox(
                        width: 48,
                        child: Text(
                          formatDuration(page.seconds.toInt()),
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
