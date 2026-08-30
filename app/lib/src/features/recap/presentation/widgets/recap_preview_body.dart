import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Provider-free recap summary content used by the dashboard and previews.
class RecapPreviewBody extends StatelessWidget {
  const RecapPreviewBody({
    required this.eyebrow,
    required this.title,
    required this.summary,
    required this.aiEnhanced,
    required this.compact,
    required this.onOpen,
    super.key,
  });

  final String eyebrow;
  final String title;
  final String summary;
  final bool aiEnhanced;
  final bool compact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: compact ? 30 : 34,
          height: compact ? 30 : 34,
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          ),
          child: Icon(
            aiEnhanced ? Icons.auto_awesome_outlined : Icons.notes_rounded,
            size: compact ? 16 : 18,
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
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.7,
                ),
              ),
              SizedBox(height: compact ? 1 : 3),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              SizedBox(height: compact ? 1 : 3),
              Text(
                summary,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: compact ? 1.25 : 1.35,
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
