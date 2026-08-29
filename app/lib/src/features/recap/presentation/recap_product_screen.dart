import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapProductScreen extends ConsumerWidget {
  const RecapProductScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recap = ref.watch(recapProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final settings = ref.watch(recapAiSettingsProvider).value ?? const RecapAiSettings();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: const Text('AI Recap'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/ai-setup'),
            icon: Icon(settings.enabled ? Icons.auto_awesome_rounded : Icons.add_link_rounded, size: 17),
            label: Text(settings.enabled ? '${settings.displayProvider} · AI 接入' : '接入 AI'),
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
          constraints: const BoxConstraints(maxWidth: TimeTraceLayout.readingWidth + 180),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(TimeTraceSpace.xl, TimeTraceSpace.md, TimeTraceSpace.xl, TimeTraceSpace.xxl),
            children: [
              _RangeSelector(selection: selection),
              const SizedBox(height: TimeTraceSpace.md),
              recap.when(
                skipLoadingOnReload: true,
                loading: () => const SizedBox(height: 260, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                error: (_, _) => Center(
                  child: FilledButton.icon(
                    onPressed: () => ref.read(recapProvider.notifier).refresh(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新生成'),
                  ),
                ),
                data: (state) => _Report(state: state, settings: settings),
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
        for (final (text, range) in const [
          ('今天', DateRange.today),
          ('昨天', DateRange.yesterday),
          ('本周', DateRange.week),
          ('本月', DateRange.month),
        ])
          ChoiceChip(
            label: Text(text),
            selected: selection.range == range,
            onSelected: (_) => ref.read(dashboardRangeProvider.notifier).select(range),
          ),
      ],
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({required this.state, required this.settings});
  final RecapState state;
  final RecapAiSettings settings;

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
          padding: const EdgeInsets.fromLTRB(TimeTraceSpace.lg, TimeTraceSpace.lg, TimeTraceSpace.lg, TimeTraceSpace.md),
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
                  Icon(result.isAiEnhanced ? Icons.auto_awesome_rounded : Icons.lock_outline_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: TimeTraceSpace.xs),
                  Text(
                    result.isAiEnhanced ? 'AI ENHANCED · ${result.model ?? settings.model}' : 'LOCAL FACTUAL RECAP · 免费',
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700, letterSpacing: 0.55),
                  ),
                  const Spacer(),
                  Text(_time(state.generatedAt), style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: TimeTraceSpace.sm),
              Text(result.headline, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4)),
              const SizedBox(height: TimeTraceSpace.xs),
              Text(result.summary, style: theme.textTheme.bodyMedium?.copyWith(height: 1.58)),
              if (state.aiError != null) ...[
                const SizedBox(height: TimeTraceSpace.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
                    const SizedBox(width: TimeTraceSpace.xs),
                    Expanded(child: Text(state.aiError!, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.lg),
        _SectionTitle(icon: Icons.fact_check_outlined, title: '事实', subtitle: '来自本地记录，AI 不允许修改这些数字。'),
        const SizedBox(height: TimeTraceSpace.sm),
        _Facts(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.xl),
        _SectionTitle(icon: Icons.visibility_outlined, title: '观察', subtitle: '描述数据中实际出现的模式。'),
        const SizedBox(height: TimeTraceSpace.sm),
        _NumberedRows(items: result.insights, empty: '当前数据还不足以形成稳定观察。'),
        const SizedBox(height: TimeTraceSpace.xl),
        _SectionTitle(icon: Icons.lightbulb_outline_rounded, title: '建议', subtitle: '基于观察给出可尝试的调整，不把建议包装成事实。'),
        const SizedBox(height: TimeTraceSpace.sm),
        _AdviceRows(items: result.recommendations),
        const SizedBox(height: TimeTraceSpace.xl),
        _SectionTitle(icon: Icons.bar_chart_rounded, title: '时间分配', subtitle: '按活跃时长排序的主要应用。'),
        const SizedBox(height: TimeTraceSpace.sm),
        _AppDistribution(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.xl),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('查看事实快照 JSON'),
          subtitle: const Text('用于检查真正提交给 AI 的结构化输入。'),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(TimeTraceSpace.sm),
              decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
              child: SelectableText(
                snapshot.toPrettyJson(includeDiaryEntries: settings.includeDiaryEntries),
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
          child: Icon(icon, size: 16, color: scheme.primary),
        ),
        const SizedBox(width: TimeTraceSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.snapshot});
  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final facts = [
      ('活跃时长', formatRecapDuration(snapshot.activeSeconds), '记录范围内'),
      ('应用切换', snapshot.sessionCount > 0 ? '${snapshot.contextSwitches}' : '—', snapshot.sessionCount > 0 ? '${snapshot.sessionCount} 个活跃 Session' : '暂无细分'),
      ('最长连续', snapshot.longestActiveStreakSeconds > 0 ? formatRecapDuration(snapshot.longestActiveStreakSeconds) : '—', '连续非 Idle'),
      ('最常用', top?.name ?? '—', top == null ? '暂无数据' : formatRecapDuration(top.activeSeconds)),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 4 : constraints.maxWidth >= 420 ? 2 : 1;
        final gap = TimeTraceSpace.sm;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final fact in facts) SizedBox(width: width, child: _FactTile(label: fact.$1, value: fact.$2, detail: fact.$3))],
        );
      },
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({required this.label, required this.value, required this.detail});
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
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
          Text(label, style: theme.textTheme.labelMedium),
          const Spacer(),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _NumberedRows extends StatelessWidget {
  const _NumberedRows({required this.items, required this.empty});
  final List<String> items;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Text(empty, style: Theme.of(context).textTheme.bodySmall);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 36, child: Text((i + 1).toString().padLeft(2, '0'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700))),
                Expanded(child: Text(items[i], style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5))),
              ],
            ),
          ),
          if (i != items.length - 1) Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.75)),
        ],
      ],
    );
  }
}

class _AdviceRows extends StatelessWidget {
  const _AdviceRows({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Text('当前没有足够数据形成建议。', style: Theme.of(context).textTheme.bodySmall);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final text in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
                  child: Icon(Icons.arrow_forward_rounded, size: 14, color: scheme.primary),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5))),
              ],
            ),
          ),
      ],
    );
  }
}

class _AppDistribution extends StatelessWidget {
  const _AppDistribution({required this.snapshot});
  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final apps = snapshot.topApps;
    if (apps.isEmpty) return const Text('暂无应用数据');
    final max = apps.first.activeSeconds <= 0 ? 1 : apps.first.activeSeconds;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < apps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
            child: Row(
              children: [
                SizedBox(width: 34, child: Text((i + 1).toString().padLeft(2, '0'), style: Theme.of(context).textTheme.labelSmall)),
                SizedBox(width: 160, child: Text(apps[i].name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: (apps[i].activeSeconds / max).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                SizedBox(width: 72, child: Text(formatRecapDuration(apps[i].activeSeconds), textAlign: TextAlign.right, style: Theme.of(context).textTheme.labelMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

String _time(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';
