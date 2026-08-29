import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_ai_settings_dialog.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapScreen extends ConsumerWidget {
  const RecapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRecap = ref.watch(recapProvider);
    final selection = ref.watch(dashboardRangeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Recap'),
        actions: [
          IconButton(
            tooltip: 'AI Recap 设置',
            onPressed: () => _showAiSettings(context, ref),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '重新生成',
            onPressed: () => ref.read(recapProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: TimeTraceLayout.dashboardWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.xl,
              TimeTraceSpace.md,
              TimeTraceSpace.xl,
              TimeTraceSpace.xxl,
            ),
            children: [
              _RangeSelector(selection: selection),
              const SizedBox(height: TimeTraceSpace.md),
              asyncRecap.when(
                skipLoadingOnReload: true,
                loading: () => const SizedBox(
                  height: 220,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                error: (error, _) => _RecapError(
                  onRetry: () => ref.read(recapProvider.notifier).refresh(),
                ),
                data: (state) => _RecapContent(state: state),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeSelector extends ConsumerWidget {
  const _RangeSelector({required this.selection});

  final DateRangeSelection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: TimeTraceSpace.xs,
      runSpacing: TimeTraceSpace.xs,
      children: [
        for (final item in const [
          ('今天', DateRange.today),
          ('昨天', DateRange.yesterday),
          ('本周', DateRange.week),
          ('本月', DateRange.month),
        ])
          ChoiceChip(
            label: Text(item.$1),
            selected: selection.range == item.$2,
            onSelected: (_) =>
                ref.read(dashboardRangeProvider.notifier).select(item.$2),
          ),
      ],
    );
  }
}

class _RecapContent extends StatelessWidget {
  const _RecapContent({required this.state});

  final RecapState state;

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    final snapshot = result.snapshot;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(TimeTraceSpace.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    result.isAiEnhanced
                        ? Icons.auto_awesome_outlined
                        : Icons.notes_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: TimeTraceSpace.xs),
                  Text(
                    result.isAiEnhanced
                        ? 'AI ENHANCED · ${result.model ?? 'MODEL'}'
                        : 'LOCAL FACTUAL RECAP',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _generatedLabel(state.generatedAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: TimeTraceSpace.sm),
              Text(
                result.headline,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: TimeTraceSpace.xs),
              Text(
                result.summary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
              if (state.aiError != null) ...[
                const SizedBox(height: TimeTraceSpace.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: TimeTraceSpace.xs),
                    Expanded(
                      child: Text(
                        state.aiError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.md),
        _MetricGrid(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.lg),
        _Section(
          title: '洞察',
          subtitle: '来自 TimeTrace 事实快照；AI 只能总结，不能修改这些事实。',
          child: Column(
            children: [
              for (var i = 0; i < result.insights.length; i++) ...[
                _InsightRow(index: i + 1, text: result.insights[i]),
                if (i != result.insights.length - 1) const Divider(height: 24),
              ],
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.lg),
        _TopApps(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.lg),
        _Section(
          title: '事实快照',
          subtitle: '展开查看实际提交给 AI 的结构化数据。',
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: TimeTraceSpace.xs),
            title: const Text('查看原始 Recap JSON'),
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
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final metrics = [
      ('活跃时长', formatRecapDuration(snapshot.activeSeconds), '记录范围内'),
      (
        '最长连续段',
        snapshot.longestActiveStreakSeconds > 0
            ? formatRecapDuration(snapshot.longestActiveStreakSeconds)
            : '—',
        snapshot.longestActiveStreakSeconds > 0 ? '连续非 Idle' : '月视图暂不计算',
      ),
      (
        '应用切换',
        snapshot.sessionCount > 0 ? '${snapshot.contextSwitches}' : '—',
        snapshot.sessionCount > 0
            ? '${snapshot.sessionCount} 个活跃 Session'
            : '月视图暂不计算',
      ),
      (
        '最常用',
        top?.name ?? '—',
        top == null ? '暂无数据' : formatRecapDuration(top.activeSeconds),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 520
            ? 2
            : 1;
        final width =
            (constraints.maxWidth - (columns - 1) * TimeTraceSpace.sm) /
            columns;
        return Wrap(
          spacing: TimeTraceSpace.sm,
          runSpacing: TimeTraceSpace.sm,
          children: [
            for (final item in metrics)
              SizedBox(
                width: width,
                child: _MetricCard(
                  title: item.$1,
                  value: item.$2,
                  detail: item.$3,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.detail,
  });

  final String title;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 96,
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
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

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        child,
      ],
    );
  }
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
        SizedBox(
          width: 28,
          child: Text(
            index.toString().padLeft(2, '0'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
      ],
    );
  }
}

class _TopApps extends StatelessWidget {
  const _TopApps({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final apps = snapshot.topApps;
    return _Section(
      title: '时间分配',
      subtitle: '按活跃时长排序的主要应用。',
      child: apps.isEmpty
          ? const Text('暂无应用数据')
          : Column(
              children: [
                for (var i = 0; i < apps.length; i++)
                  _AppRow(
                    app: apps[i],
                    maxSeconds: apps.first.activeSeconds,
                    rank: i + 1,
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
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              rank.toString().padLeft(2, '0'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: TimeTraceSpace.sm),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: TimeTraceSpace.sm),
          SizedBox(
            width: 72,
            child: Text(
              formatRecapDuration(app.activeSeconds),
              textAlign: TextAlign.right,
              style: theme.textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecapError extends StatelessWidget {
  const _RecapError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded),
        const SizedBox(height: TimeTraceSpace.xs),
        const Text('生成回顾失败'),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

String _generatedLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';

Future<void> _showAiSettings(BuildContext context, WidgetRef ref) async {
  final current =
      ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
  final saved = await RecapAiSettingsDialog.show(
    context,
    initial: current,
    onTestConnection: const RecapAiClient().testConnection,
  );
  if (saved != null) {
    await ref.read(recapAiSettingsProvider.notifier).save(saved);
  }
}
