import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

/// Dashboard projection of the most recently generated time report.
///
/// It is independent from Dashboard date filters and never performs network
/// I/O. Report generation remains an explicit action on the report page.
class AiRecapCard extends ConsumerWidget {
  const AiRecapCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(
      aiRecapControllerProvider.select((state) => state.latestReport),
    );
    final colors = Theme.of(context).colorScheme;
    final summary = report?.summary.text ?? '打开报告页，选择日报、周报或月报并手动生成。';

    return Semantics(
      button: true,
      label: 'AI 时间报告。$summary',
      excludeSemantics: true,
      child: Card(
        key: const Key('ai-recap-dashboard-card'),
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 116),
          child: InkWell(
            key: const Key('ai-recap-open-detail'),
            onTap: () => context.go('/reports'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.summarize_outlined,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                'AI 时间报告',
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (report != null) ...[
                              const SizedBox(width: 8),
                              _ReportTypeBadge(
                                label: report.rangeKey.scope.label,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (report != null)
                          Text(
                            _formatRange(report.rangeKey),
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        const SizedBox(height: 3),
                        Text(
                          report == null ? '还没有报告。$summary' : summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.35,
                              ),
                        ),
                        if (report != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            '${report.model.label} · '
                            '${_formatGeneratedAt(report.generatedAt)}',
                            key: const Key('ai-recap-card-metadata'),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: report == null ? '生成报告' : '查看报告',
                    child: Icon(
                      Icons.chevron_right,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportTypeBadge extends StatelessWidget {
  const _ReportTypeBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colors.onSecondaryContainer),
        ),
      ),
    );
  }
}

String _formatRange(AiRecapRangeKey key) {
  String date(DateTime value) => '${value.year}年${value.month}月${value.day}日';
  if (key.startDate == key.endDate) return date(key.startDate);
  return '${date(key.startDate)}—${date(key.endDate)}';
}

String _formatGeneratedAt(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)} 生成';
}
