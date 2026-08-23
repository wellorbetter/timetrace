import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Compact Dashboard projection of the current range's local AI recap state.
///
/// The card never generates or fetches cloud data. Its only action opens the
/// detail route, where generation requires another explicit user click.
class AiRecapCard extends ConsumerStatefulWidget {
  const AiRecapCard({super.key});

  @override
  ConsumerState<AiRecapCard> createState() => _AiRecapCardState();
}

class _AiRecapCardState extends ConsumerState<AiRecapCard> {
  AiRecapRangeKey? _synchronizedKey;

  @override
  Widget build(BuildContext context) {
    final bounds = ref.watch(dashboardRangeBoundsProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final key = AiRecapRangeKey.fromIsoDates(
      bounds.start,
      bounds.end,
      scope: _scopeFor(selection.range),
    );
    if (bounds.supportedByAiRecap && key != _synchronizedKey) {
      _synchronizedKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(aiRecapControllerProvider.notifier).synchronize(key);
        }
      });
    }

    final projection = ref.watch(
      aiRecapControllerProvider.select((state) => state.projection(key)),
    );
    final status = ref.watch(
      aiRecapControllerProvider.select((state) => state.status),
    );
    final colors = Theme.of(context).colorScheme;
    final summary = switch ((bounds.supportedByAiRecap, projection.result)) {
      (false, _) => '当前范围暂不支持 AI 回顾，请切换到今日或本周。',
      (true, final result?) => result.summary.text,
      (true, null) when !status.serviceAvailable => 'AI 回顾本地服务暂不可用；时间统计不会受到影响。',
      (true, null) when !status.configured =>
        '配置 DEEPSEEK_API_KEY 后，可将聚合使用时长整理成中文回顾。',
      _ => '还没有${bounds.label}回顾。打开详情后可由你手动生成。',
    };

    return Semantics(
      button: true,
      label: 'AI 使用回顾，${bounds.label}。$summary',
      child: Card(
        key: const Key('ai-recap-dashboard-card'),
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 112),
          child: InkWell(
            onTap: () => context.push('/ai-recap'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
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
                      Icons.auto_awesome_outlined,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'AI 使用回顾',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            _RangeBadge(label: bounds.label),
                            if (projection.generating) ...[
                              const SizedBox(width: 8),
                              const SizedBox.square(
                                key: Key('ai-recap-card-progress'),
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.35,
                              ),
                        ),
                        if (projection.result case final result?) ...[
                          const SizedBox(height: 3),
                          Text(
                            '${result.model.label} · ${_formatGeneratedAt(result.generatedAt)}',
                            key: const Key('ai-recap-card-metadata'),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('ai-recap-open-detail'),
                    onPressed: () => context.push('/ai-recap'),
                    child: const Text('查看详情'),
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

String _formatGeneratedAt(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '生成于 ${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}

AiRecapScope _scopeFor(DateRange range) => switch (range) {
  DateRange.today => AiRecapScope.today,
  DateRange.week => AiRecapScope.weekToDate,
  _ => AiRecapScope.unsupported,
};

class _RangeBadge extends StatelessWidget {
  const _RangeBadge({required this.label});

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
