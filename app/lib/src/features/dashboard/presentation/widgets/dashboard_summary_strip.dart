import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_card.dart';

/// The overview summary is intentionally compact. The detailed charts and app
/// views already live directly below, so this strip should only act as a quick
/// glance rather than repeat the dashboard in large cards.
class DashboardSummaryStrip extends StatelessWidget {
  const DashboardSummaryStrip({
    required this.state,
    required this.apps,
    super.key,
  });

  final DashboardState state;
  final List<AppUsageItem> apps;

  @override
  Widget build(BuildContext context) {
    final totalTracked = state.totalActiveSeconds + state.totalIdleSeconds;
    final activeRatio = totalTracked <= 0
        ? 0
        : (state.totalActiveSeconds / totalTracked * 100).round();
    final topApp = apps.isEmpty ? null : apps.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final topAppWidth = constraints.maxWidth >= 760
                ? 420.0
                : (constraints.maxWidth * 0.72).clamp(220.0, 360.0);

            return Wrap(
              spacing: TimeTraceSpace.lg,
              runSpacing: TimeTraceSpace.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _InlineMetric(
                  label: '应用',
                  value: '${apps.length}',
                  onTap: () => _showAppsSheet(context, apps),
                ),
                _InlineMetric(
                  label: '活跃占比',
                  value: '$activeRatio%',
                  onTap: () => _showMetricSheet(
                    context,
                    title: '活跃占比',
                    body:
                        '活跃占比 = 活跃时间 ÷（活跃时间 + 闲置时间）。它只是设备活动事实，不是生产力、效率、健康或努力程度评分。',
                  ),
                ),
                SizedBox(
                  width: topAppWidth,
                  child: _InlineMetric(
                    label: '最常用',
                    value: topApp == null
                        ? '—'
                        : '${topApp.appName} · ${topApp.activeLabel}',
                    onTap: topApp == null
                        ? null
                        : () => _showMetricSheet(
                            context,
                            title: topApp.appName,
                            body:
                                '当前范围内 ${topApp.appName} 的活跃时长为 ${topApp.activeLabel}。更细的窗口/页面会话可以在下面的“应用排行”视图中展开查看。',
                          ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        const RecapPreviewCard(),
      ],
    );
  }
}

Future<void> _showMetricSheet(
  BuildContext context, {
  required String title,
  required String body,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.lg,
        TimeTraceSpace.xs,
        TimeTraceSpace.lg,
        TimeTraceSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(
            body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.55),
          ),
        ],
      ),
    ),
  ),
);

Future<void> _showAppsSheet(
  BuildContext context,
  List<AppUsageItem> apps,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.lg,
        0,
        TimeTraceSpace.lg,
        TimeTraceSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前范围的主要应用',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          if (apps.isEmpty)
            Text('暂无应用数据', style: Theme.of(context).textTheme.bodySmall)
          else
            for (var i = 0; i < apps.take(5).length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Text((i + 1).toString().padLeft(2, '0')),
                title: Text(apps[i].appName),
                trailing: Text(apps[i].activeLabel),
              ),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(
            '关闭此面板后，可在概览的“应用排行”视图中点击应用查看页面会话。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  ),
);

class _InlineMetric extends StatelessWidget {
  const _InlineMetric({
    required this.label,
    required this.value,
    this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TimeTraceSpace.xxs,
            vertical: 3,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$label ',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
