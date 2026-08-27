import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapPreviewCard extends ConsumerWidget {
  const RecapPreviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRecap = ref.watch(recapProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: asyncRecap.when(
        skipLoadingOnReload: true,
        loading: () => const SizedBox(
          height: 72,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (_, _) => _PreviewBody(
          eyebrow: 'AI RECAP',
          title: '回顾暂时不可用',
          summary: '使用记录仍会正常保存，可以稍后重试。',
          aiEnhanced: false,
          onOpen: () => context.go('/recap'),
        ),
        data: (state) => _PreviewBody(
          eyebrow: state.result.isAiEnhanced ? 'AI RECAP · ${state.result.model ?? 'AI'}' : 'RECAP · LOCAL',
          title: state.result.headline,
          summary: state.result.summary,
          aiEnhanced: state.result.isAiEnhanced,
          onOpen: () => context.go('/recap'),
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.eyebrow,
    required this.title,
    required this.summary,
    required this.aiEnhanced,
    required this.onOpen,
  });

  final String eyebrow;
  final String title;
  final String summary;
  final bool aiEnhanced;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          ),
          child: Icon(
            aiEnhanced ? Icons.auto_awesome_outlined : Icons.notes_rounded,
            size: 18,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: TimeTraceSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: TimeTraceSpace.sm),
        TextButton.icon(
          onPressed: onOpen,
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_forward_rounded, size: 15),
          label: const Text('完整回顾'),
        ),
      ],
    );
  }
}
