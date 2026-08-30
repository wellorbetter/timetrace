import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

/// Provider-free Recap report surface used by the screen, previews and tests.
class RecapReportView extends StatelessWidget {
  const RecapReportView({
    super.key,
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    this.aiError,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final String? aiError;

  @override
  Widget build(BuildContext context) {
    final snapshot = result.snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummarySurface(
          result: result,
          generatedAt: generatedAt,
          aiEnabled: aiEnabled,
          aiError: aiError,
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            final insights = _InsightsPanel(result: result);
            final apps = _TopAppsPanel(snapshot: snapshot);
            if (constraints.maxWidth >= 840) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: insights),
                  const SizedBox(width: TimeTraceSpace.sm),
                  Expanded(flex: 5, child: apps),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                insights,
                const SizedBox(height: TimeTraceSpace.sm),
                apps,
              ],
            );
          },
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        _SnapshotDisclosure(snapshot: snapshot, aiEnabled: aiEnabled),
      ],
    );
  }
}

class _SummarySurface extends StatelessWidget {
  const _SummarySurface({
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    required this.aiError,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final String? aiError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const ValueKey('recap-summary-surface'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: TimeTraceSpace.xs,
              runSpacing: TimeTraceSpace.xxs,
              children: [
                _OriginBadge(result: result, aiEnabled: aiEnabled),
                Text(
                  _generatedLabel(generatedAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.sm),
            Text(result.headline, style: theme.textTheme.titleLarge),
            const SizedBox(height: TimeTraceSpace.xs),
            Text(
              result.summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (aiError != null) ...[
              const SizedBox(height: TimeTraceSpace.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: TimeTraceSpace.xs,
                  vertical: TimeTraceSpace.xxs,
                ),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: scheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: TimeTraceSpace.xs),
                    Expanded(
                      child: Text(
                        aiError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: TimeTraceSpace.lg),
            _MetricStrip(snapshot: result.snapshot),
          ],
        ),
      ),
    );
  }
}

class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.result, required this.aiEnabled});

  final RecapResult result;
  final bool aiEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isAi = result.isAiEnhanced;
    final label = isAi
        ? 'AI 增强 · ${result.model ?? '模型'}'
        : aiEnabled
        ? '本地回顾 · AI 已回退'
        : '本地回顾';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: isAi ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isAi ? Icons.auto_awesome_outlined : Icons.lock_outline_rounded,
            size: 14,
            color: isAi ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: TimeTraceSpace.xxs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: isAi
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final metrics = <(String, String, String)>[
      ('活跃时长', formatRecapDuration(snapshot.activeSeconds), '当前范围'),
      (
        '最长连续段',
        snapshot.longestActiveStreakSeconds > 0
            ? formatRecapDuration(snapshot.longestActiveStreakSeconds)
            : '—',
        snapshot.longestActiveStreakSeconds > 0 ? '连续活跃' : '暂无数据',
      ),
      (
        '应用切换',
        snapshot.sessionCount > 0 ? '${snapshot.contextSwitches}' : '—',
        snapshot.sessionCount > 0 ? '${snapshot.sessionCount} 个片段' : '暂无数据',
      ),
      (
        '最常用',
        top?.name ?? '—',
        top == null ? '暂无数据' : formatRecapDuration(top.activeSeconds),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final scheme = Theme.of(context).colorScheme;
        if (wide) {
          return Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  for (var index = 0; index < metrics.length; index++) ...[
                    Expanded(child: _MetricCell(value: metrics[index])),
                    if (index != metrics.length - 1)
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: scheme.outlineVariant,
                      ),
                  ],
                ],
              ),
            ),
          );
        }

        final width = (constraints.maxWidth - TimeTraceSpace.xs) / 2;
        return Wrap(
          spacing: TimeTraceSpace.xs,
          runSpacing: TimeTraceSpace.xs,
          children: [
            for (final metric in metrics)
              Container(
                width: width,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: _MetricCell(value: metric),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.value});

  final (String, String, String) value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: TimeTraceSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.$1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: TimeTraceSpace.xxs),
          Tooltip(
            message: value.$2,
            child: Text(
              value.$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          Text(
            value.$3,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightsPanel extends StatelessWidget {
  const _InsightsPanel({required this.result});

  final RecapResult result;

  @override
  Widget build(BuildContext context) => _ReportPanel(
    icon: Icons.fact_check_outlined,
    title: '关键事实',
    subtitle: result.isAiEnhanced
        ? 'AI 只整理文字，以下数字仍来自本机记录。'
        : '根据本机记录生成，不上传数据。',
    child: result.insights.isEmpty
        ? const Text('当前范围暂无足够数据。')
        : Column(
            children: [
              for (var index = 0; index < result.insights.length; index++) ...[
                _InsightRow(index: index + 1, text: result.insights[index]),
                if (index != result.insights.length - 1)
                  const Divider(height: TimeTraceSpace.md),
              ],
            ],
          ),
  );
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          ),
          child: Text(
            index.toString().padLeft(2, '0'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: TimeTraceSpace.sm),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

class _TopAppsPanel extends StatelessWidget {
  const _TopAppsPanel({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final apps = snapshot.topApps;
    return _ReportPanel(
      icon: Icons.stacked_bar_chart_rounded,
      title: '时间分配',
      subtitle: '按活跃时长排序的主要应用。',
      child: apps.isEmpty
          ? const Text('当前范围暂无应用数据。')
          : Column(
              children: [
                for (var index = 0; index < apps.length; index++)
                  _AppRow(
                    app: apps[index],
                    maxSeconds: apps.first.activeSeconds,
                    rank: index + 1,
                  ),
              ],
            ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.maxSeconds,
    required this.rank,
  });

  final RecapAppFact app;
  final int maxSeconds;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ratio = maxSeconds <= 0 ? 0.0 : app.activeSeconds / maxSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  rank.toString().padLeft(2, '0'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Tooltip(
                  message: app.name,
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: TimeTraceSpace.xs),
              Text(
                formatRecapDuration(app.activeSeconds),
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.xxs),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0).toDouble(),
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportPanel extends StatelessWidget {
  const _ReportPanel({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: TimeTraceSpace.xs),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.xxs),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: TimeTraceSpace.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _SnapshotDisclosure extends StatelessWidget {
  const _SnapshotDisclosure({required this.snapshot, required this.aiEnabled});

  final RecapSnapshot snapshot;
  final bool aiEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const ValueKey('recap-snapshot-disclosure'),
      child: ExpansionTile(
        leading: Icon(Icons.data_object_rounded, color: scheme.primary),
        title: const Text('事实快照'),
        subtitle: Text(
          aiEnabled
              ? '查看用于生成回顾的结构化数据。'
              : '查看本地规则使用的结构化数据。',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          TimeTraceSpace.md,
          0,
          TimeTraceSpace.md,
          TimeTraceSpace.md,
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: SelectableText(
              snapshot.toPrettyJson(),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _generatedLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';
