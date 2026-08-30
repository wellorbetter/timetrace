import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_body.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapPreviewCard extends ConsumerWidget {
  const RecapPreviewCard({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRecap = ref.watch(recapProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: compact ? TimeTraceSpace.xs : TimeTraceSpace.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: asyncRecap.when(
        skipLoadingOnReload: true,
        loading: () => SizedBox(
          height: compact ? 44 : 72,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (_, _) => RecapPreviewBody(
          eyebrow: 'AI RECAP',
          title: '回顾暂时不可用',
          summary: '使用记录仍会正常保存，可以稍后重试。',
          aiEnhanced: false,
          compact: compact,
          onOpen: () => context.go('/recap'),
        ),
        data: (state) => RecapPreviewBody(
          eyebrow: state.result.isAiEnhanced
              ? 'AI RECAP · ${state.result.model ?? 'AI'}'
              : 'RECAP · LOCAL',
          title: state.result.headline,
          summary: state.result.summary,
          aiEnhanced: state.result.isAiEnhanced,
          compact: compact,
          onOpen: () => context.go('/recap'),
        ),
      ),
    );
  }
}
