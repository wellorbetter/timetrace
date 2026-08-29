import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapPreviewCard extends ConsumerStatefulWidget {
  const RecapPreviewCard({super.key});

  @override
  ConsumerState<RecapPreviewCard> createState() => _RecapPreviewCardState();
}

class _RecapPreviewCardState extends ConsumerState<RecapPreviewCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final asyncRecap = ref.watch(recapProvider);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.96),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: asyncRecap.when(
        skipLoadingOnReload: true,
        loading: () => const SizedBox(
          height: 76,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.all(TimeTraceSpace.sm),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        ),
        error: (_, _) => _body(
          context,
          eyebrow: 'RECAP',
          title: '回顾暂时不可用',
          summary: '使用记录仍会正常保存，可以稍后重试。',
          insights: const [],
          recommendations: const [],
          aiEnhanced: false,
        ),
        data: (state) => _body(
          context,
          eyebrow: state.result.isAiEnhanced ? 'AI RECAP · ${state.result.model ?? 'AI'}' : 'RECAP · LOCAL · 免费',
          title: state.result.headline,
          summary: state.result.summary,
          insights: state.result.insights,
          recommendations: state.result.recommendations,
          aiEnhanced: state.result.isAiEnhanced,
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context, {
    required String eyebrow,
    required String title,
    required String summary,
    required List<String> insights,
    required List<String> recommendations,
    required bool aiEnhanced,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                  ),
                  child: Icon(aiEnhanced ? Icons.auto_awesome_outlined : Icons.notes_rounded, size: 18, color: scheme.primary),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(eyebrow, style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700, letterSpacing: 0.55)),
                      const SizedBox(height: 3),
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(summary, maxLines: _expanded ? 4 : 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(height: 1.42)),
                    ],
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Tooltip(
                  message: _expanded ? '收起摘要' : '展开摘要',
                  child: Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: TimeTraceMotion.normal,
          curve: TimeTraceMotion.standard,
          child: !_expanded
              ? const SizedBox.shrink()
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(TimeTraceSpace.lg, 0, TimeTraceSpace.sm, TimeTraceSpace.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (insights.isNotEmpty) ...[
                        Text('关键观察', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: TimeTraceSpace.xxs),
                        for (final text in insights.take(2)) _bullet(context, text, Icons.insights_outlined),
                      ],
                      if (recommendations.isNotEmpty) ...[
                        const SizedBox(height: TimeTraceSpace.xs),
                        Text('可以尝试', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: TimeTraceSpace.xxs),
                        _bullet(context, recommendations.first, Icons.lightbulb_outline_rounded),
                      ],
                      const SizedBox(height: TimeTraceSpace.xs),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () => context.go('/recap'),
                            icon: const Icon(Icons.open_in_new_rounded, size: 15),
                            label: const Text('完整回顾'),
                          ),
                          const SizedBox(width: TimeTraceSpace.xxs),
                          TextButton.icon(
                            onPressed: () => ref.read(recapProvider.notifier).refresh(),
                            icon: const Icon(Icons.refresh_rounded, size: 15),
                            label: const Text('重新生成'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _bullet(BuildContext context, String text, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: scheme.primary),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4))),
        ],
      ),
    );
  }
}
