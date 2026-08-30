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
            final facts = _InsightsPanel(result: result);
            final apps = _TopAppsPanel(snapshot: snapshot);
            if (constraints.maxWidth >= 900) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: facts),
                    const SizedBox(width: TimeTraceSpace.sm),
                    Expanded(child: apps),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                facts,
                const SizedBox(height: TimeTraceSpace.sm),
                apps,
              ],
            );
          },
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        _ActivityTimelinePanel(snapshot: snapshot),
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
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _OriginBadge(result: result, aiEnabled: aiEnabled),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Text(
                  _generatedLabel(generatedAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const Divider(height: TimeTraceSpace.lg),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrative = _Narrative(result: result);
                final metrics = _MetricGrid(snapshot: result.snapshot);
                if (constraints.maxWidth >= 780) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: narrative),
                      Container(
                        width: 1,
                        height: 176,
                        margin: const EdgeInsets.symmetric(
                          horizontal: TimeTraceSpace.sm,
                        ),
                        color: scheme.outlineVariant,
                      ),
                      SizedBox(width: 380, child: metrics),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    narrative,
                    const SizedBox(height: TimeTraceSpace.md),
                    metrics,
                  ],
                );
              },
            ),
            if (aiError != null) ...[
              const SizedBox(height: TimeTraceSpace.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: TimeTraceSpace.sm,
                  vertical: TimeTraceSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
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
          ],
        ),
      ),
    );
  }
}

class _Narrative extends StatelessWidget {
  const _Narrative({required this.result});

  final RecapResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Icon(
              result.isAiEnhanced
                  ? Icons.auto_awesome_outlined
                  : Icons.subject_rounded,
              size: 16,
              color: scheme.primary,
            ),
            const SizedBox(width: TimeTraceSpace.xxs),
            Text(
              result.isAiEnhanced ? 'AI 总结' : '本地总结',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.xs),
        Text(result.headline, style: theme.textTheme.titleLarge),
        const SizedBox(height: TimeTraceSpace.xs),
        Text(
          result.summary,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
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
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: isAi
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final metrics = <_MetricValue>[
      _MetricValue(
        label: '活跃时长',
        value: formatRecapDuration(snapshot.activeSeconds),
        detail: '当前范围',
      ),
      _MetricValue(
        label: '最长连续段',
        value: snapshot.longestActiveStreakSeconds > 0
            ? formatRecapDuration(snapshot.longestActiveStreakSeconds)
            : '—',
        detail: snapshot.longestActiveStreakSeconds > 0 ? '连续活跃' : '暂无数据',
      ),
      _MetricValue(
        label: '应用切换',
        value: snapshot.sessionCount > 0 ? '${snapshot.contextSwitches}' : '—',
        detail: snapshot.sessionCount > 0
            ? '${snapshot.sessionCount} 个片段'
            : '暂无数据',
      ),
      _MetricValue(
        label: '最常用',
        value: top?.name ?? '—',
        detail: top == null ? '暂无数据' : formatRecapDuration(top.activeSeconds),
        longValue: true,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final scheme = Theme.of(context).colorScheme;
        final width = (constraints.maxWidth - TimeTraceSpace.xs) / 2;
        return Wrap(
          spacing: TimeTraceSpace.xs,
          runSpacing: TimeTraceSpace.xs,
          children: [
            for (final metric in metrics)
              Container(
                width: width,
                height: 84,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  border: Border.all(color: scheme.outlineVariant),
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

class _MetricValue {
  const _MetricValue({
    required this.label,
    required this.value,
    required this.detail,
    this.longValue = false,
  });

  final String label;
  final String value;
  final String detail;
  final bool longValue;
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.value});

  final _MetricValue value;

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
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  value.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                value.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.xxs),
          Tooltip(
            message: value.value,
            child: Text(
              value.value,
              maxLines: value.longValue ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: value.longValue
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
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
    title: '事实依据',
    subtitle: result.isAiEnhanced ? 'AI 只整理文字，数字仍来自本机记录。' : '根据本机记录生成，不上传数据。',
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
              fontFeatures: const [FontFeature.tabularFigures()],
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
                    fontFeatures: const [FontFeature.tabularFigures()],
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
                style: theme.textTheme.labelMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
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

class _ActivityTimelinePanel extends StatelessWidget {
  const _ActivityTimelinePanel({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final facts = snapshot.activityFacts;
    final multipleDays = !_sameDay(snapshot.start, snapshot.end);
    final countLabel = facts.isEmpty
        ? '当前范围暂无逐段记录。'
        : '${facts.length} 个本地活动片段 · 列表内滚动';

    return _ReportPanel(
      key: const ValueKey('recap-activity-timeline'),
      icon: Icons.schedule_rounded,
      title: '活动时间线',
      subtitle: countLabel,
      child: facts.isEmpty
          ? Text(
              snapshot.sessionCount > 0
                  ? '当前范围只提供汇总数据，暂时没有可展示的逐段时间。'
                  : '开始产生使用记录后，这里会显示“什么时候用了什么”。',
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.separated(
                key: const ValueKey('recap-activity-list'),
                primary: false,
                shrinkWrap: true,
                itemCount: facts.length,
                separatorBuilder: (context, index) =>
                    Divider(height: 1, indent: multipleDays ? 150 : 116),
                itemBuilder: (context, index) =>
                    _ActivityRow(fact: facts[index], showDate: multipleDays),
              ),
            ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.fact, required this.showDate});

  final RecapActivityFact fact;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final timeLabel = _activityTimeLabel(fact, showDate: showDate);

    return Semantics(
      label:
          '$timeLabel，${fact.appName}，${formatRecapDuration(fact.durationSeconds)}',
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: showDate ? 128 : 94,
              child: Text(
                timeLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            Expanded(
              child: Tooltip(
                message: fact.appName,
                child: Text(
                  fact.appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            Text(
              formatRecapDuration(fact.durationSeconds),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportPanel extends StatelessWidget {
  const _ReportPanel({
    super.key,
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
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
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
        subtitle: Text(aiEnabled ? '查看用于生成回顾的结构化数据。' : '查看本地规则使用的结构化数据。'),
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
              border: Border.all(color: scheme.outlineVariant),
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

String _activityTimeLabel(RecapActivityFact fact, {required bool showDate}) {
  final parsed = DateTime.tryParse(fact.startedAt)?.toLocal();
  final start = parsed ?? fact.date;
  final end = start.add(Duration(seconds: fact.durationSeconds));
  final datePrefix = showDate
      ? '${start.month.toString().padLeft(2, '0')}/${start.day.toString().padLeft(2, '0')} '
      : '';
  return '$datePrefix${_clock(start)}–${_clock(end)}';
}

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _generatedLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';
