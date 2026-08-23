import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

/// Single-page AI recap detail. There is deliberately no nested settings tab.
class AiRecapScreen extends ConsumerStatefulWidget {
  const AiRecapScreen({super.key});

  @override
  ConsumerState<AiRecapScreen> createState() => _AiRecapScreenState();
}

class _AiRecapScreenState extends ConsumerState<AiRecapScreen> {
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
    final model = ref.watch(
      aiRecapControllerProvider.select((state) => state.model),
    );
    final controller = ref.read(aiRecapControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          },
        ),
        title: const Text('AI 使用回顾'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _IntroCard(rangeLabel: bounds.label, status: status),
                const SizedBox(height: 16),
                _ActionCard(
                  rangeLabel: bounds.label,
                  selectedRange: selection.range,
                  model: model,
                  generating: projection.generating,
                  onRangeChanged: projection.generating
                      ? null
                      : (range) => ref
                            .read(dashboardRangeProvider.notifier)
                            .select(range),
                  onModelChanged: projection.generating
                      ? null
                      : controller.selectModel,
                  onGenerate:
                      !bounds.supportedByAiRecap ||
                          !status.serviceAvailable ||
                          !status.configured ||
                          projection.generating
                      ? null
                      : () => controller.generate(key),
                ),
                if (!bounds.supportedByAiRecap) ...[
                  const SizedBox(height: 12),
                  const _Notice(
                    key: Key('ai-recap-unsupported-range'),
                    icon: Icons.date_range_outlined,
                    message: '当前范围暂不支持 AI 回顾。请返回仪表盘，选择“今天”或“本周”。',
                  ),
                ] else if (!status.serviceAvailable) ...[
                  const SizedBox(height: 12),
                  const _Notice(
                    key: Key('ai-recap-service-unavailable'),
                    icon: Icons.sync_problem_outlined,
                    message: 'AI 回顾本地服务暂不可用，请重启 TimeTrace。时间统计和仪表盘不受影响。',
                  ),
                ] else if (!status.configured) ...[
                  const SizedBox(height: 12),
                  const _Notice(
                    key: Key('ai-recap-not-configured'),
                    icon: Icons.key_off_outlined,
                    message:
                        '未找到 DEEPSEEK_API_KEY。请在 Windows 系统环境变量中配置后重启 TimeTrace；密钥不会在此显示或保存。',
                  ),
                ],
                if (projection.failure case final failure?) ...[
                  const SizedBox(height: 12),
                  _ErrorNotice(
                    failure: failure,
                    onRetry:
                        failure.retryable &&
                            bounds.supportedByAiRecap &&
                            status.serviceAvailable &&
                            status.configured &&
                            !projection.generating
                        ? () => controller.generate(key)
                        : null,
                  ),
                ],
                const SizedBox(height: 20),
                if (projection.result case final result?)
                  _ResultView(result: result, generating: projection.generating)
                else
                  _EmptyState(
                    supported: bounds.supportedByAiRecap,
                    configured: status.configured,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.rangeLabel, required this.status});

  final String rangeLabel;
  final AiRecapProviderStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, color: colors.primary, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '把使用时长变成可执行的回顾',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '当前范围：$rangeLabel。DeepSeek 只解释本地聚合后的数字，不会改动你的时间记录。',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            _StatusBadge(status: status),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.rangeLabel,
    required this.selectedRange,
    required this.model,
    required this.generating,
    required this.onRangeChanged,
    required this.onModelChanged,
    required this.onGenerate,
  });

  final String rangeLabel;
  final DateRange selectedRange;
  final AiRecapModel model;
  final bool generating;
  final ValueChanged<DateRange>? onRangeChanged;
  final ValueChanged<AiRecapModel>? onModelChanged;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 18,
              runSpacing: 14,
              crossAxisAlignment: WrapCrossAlignment.end,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '回顾范围：$rangeLabel',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<DateRange>(
                      key: const Key('ai-recap-range-selector'),
                      showSelectedIcon: false,
                      emptySelectionAllowed: true,
                      segments: const [
                        ButtonSegment(
                          value: DateRange.today,
                          label: Text('今日'),
                        ),
                        ButtonSegment(value: DateRange.week, label: Text('本周')),
                      ],
                      selected: {
                        if (selectedRange == DateRange.today ||
                            selectedRange == DateRange.week)
                          selectedRange,
                      },
                      onSelectionChanged: onRangeChanged == null
                          ? null
                          : (selection) {
                              if (selection.isNotEmpty) {
                                onRangeChanged!(selection.first);
                              }
                            },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('分析模型', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SegmentedButton<AiRecapModel>(
                      key: const Key('ai-recap-model-selector'),
                      showSelectedIcon: false,
                      segments: [
                        for (final value in AiRecapModel.values)
                          ButtonSegment(
                            value: value,
                            label: Text(value.label),
                            tooltip: value.description,
                          ),
                      ],
                      selected: {model},
                      onSelectionChanged: onModelChanged == null
                          ? null
                          : (selection) => onModelChanged!(selection.first),
                    ),
                  ],
                ),
                FilledButton.icon(
                  key: const Key('ai-recap-generate'),
                  onPressed: onGenerate,
                  icon: generating
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(generating ? '正在生成' : '生成回顾'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 19),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '点击生成后，仅发送最多 12 个应用名称和聚合使用时长。'
                    '不会发送窗口标题、按键、文件路径、可执行文件路径或日记正文。'
                    'API Key 仅通过 TLS 用于 DeepSeek 鉴权，不进入提示词，也不会在应用中展示、保存或记录。',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.result, required this.generating});

  final AiRecapResult result;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('ai-recap-result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '回顾结果',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              '${_formatRange(result.rangeKey)} · '
              '${_formatDuration(result.totalActiveSeconds)} · '
              '${result.applicationCount} 个应用 · ${result.model.label}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (generating) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(key: Key('ai-recap-inline-progress')),
          const SizedBox(height: 5),
          const Text('正在更新，当前回顾仍可阅读。'),
        ],
        const SizedBox(height: 14),
        _ContentCard(
          icon: Icons.subject_outlined,
          title: '摘要',
          child: _StatementContent(statement: result.summary),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final highlights = _ContentCard(
              icon: Icons.bolt_outlined,
              title: '亮点',
              child: _BulletList(items: result.highlights),
            );
            final suggestions = _ContentCard(
              icon: Icons.explore_outlined,
              title: '建议',
              child: _BulletList(items: result.suggestions),
            );
            if (constraints.maxWidth < 680) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [highlights, const SizedBox(height: 12), suggestions],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: highlights),
                const SizedBox(width: 12),
                Expanded(child: suggestions),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          '生成于 ${_formatTime(result.generatedAt)}',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ContentCard extends StatelessWidget {
  const _ContentCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DefaultTextStyle.merge(
              style: const TextStyle(height: 1.55),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.items});

  final List<AiRecapStatement> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• '),
                Expanded(child: _StatementContent(statement: item)),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatementContent extends StatelessWidget {
  const _StatementContent({required this.statement});

  final AiRecapStatement statement;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(statement.text),
        const SizedBox(height: 5),
        Text(
          '依据：${statement.evidence.map(_formatEvidence).join('、')}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.supported, required this.configured});

  final bool supported;
  final bool configured;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('ai-recap-empty'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
        child: Column(
          children: [
            Icon(
              Icons.insights_outlined,
              size: 34,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              supported && configured ? '还没有这个范围的回顾' : '完成上方条件后即可生成',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 5),
            const Text('生成由你主动触发，打开页面不会自动联网。'),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.tertiaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: colors.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.failure, required this.onRetry});

  final AiRecapFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('ai-recap-error'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.errorContainer.withValues(alpha: 0.72),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colors.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(_failureMessage(failure.code))),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final AiRecapProviderStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final configured = status.serviceAvailable && status.configured;
    final foreground = configured ? colors.primary : colors.outline;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          !status.serviceAvailable
              ? '服务不可用'
              : configured
              ? 'DeepSeek 已配置'
              : 'DeepSeek 未配置',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String _failureMessage(AiRecapFailureCode code) => switch (code) {
  AiRecapFailureCode.notConfigured => '未找到 DEEPSEEK_API_KEY，配置后重启 TimeTrace。',
  AiRecapFailureCode.invalidRange => '日期范围无效，请返回仪表盘重新选择。',
  AiRecapFailureCode.unsupportedModel => '所选模型暂不受支持。',
  AiRecapFailureCode.noUsageData => '这段时间还没有可用的活动时长。',
  AiRecapFailureCode.requestTooLarge => '聚合数据超出安全上限，本次未发送。',
  AiRecapFailureCode.network => '无法连接 DeepSeek，请检查网络后手动重试。',
  AiRecapFailureCode.timeout => '请求超时，已停止等待。',
  AiRecapFailureCode.authentication => 'DeepSeek 拒绝了当前 API Key。',
  AiRecapFailureCode.rateLimited => 'DeepSeek 请求过于频繁，请稍后手动重试。',
  AiRecapFailureCode.providerUnavailable => 'DeepSeek 暂时不可用，请稍后手动重试。',
  AiRecapFailureCode.invalidResponse => '服务返回的回顾格式不完整，旧结果已保留。',
  AiRecapFailureCode.busy => '已有一个回顾正在生成。',
  AiRecapFailureCode.bridgeUnavailable => 'AI 回顾服务暂不可用，请重启 TimeTrace 后再试。',
};

AiRecapScope _scopeFor(DateRange range) => switch (range) {
  DateRange.today => AiRecapScope.today,
  DateRange.week => AiRecapScope.weekToDate,
  _ => AiRecapScope.unsupported,
};

String _formatDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainingSeconds = seconds % 60;
  final parts = <String>[];
  if (hours > 0) parts.add('$hours 小时');
  if (minutes > 0) parts.add('$minutes 分钟');
  if (remainingSeconds > 0 || parts.isEmpty) {
    parts.add('$remainingSeconds 秒');
  }
  return parts.join(' ');
}

String _formatEvidence(AiRecapEvidence evidence) =>
    '${evidence.appName} ${_formatDuration(evidence.activeSeconds)}';

String _formatRange(AiRecapRangeKey key) {
  String date(DateTime value) => '${value.year}年${value.month}月${value.day}日';
  final scope = switch (key.scope) {
    AiRecapScope.today => '今日',
    AiRecapScope.weekToDate => '本周截至今日',
    AiRecapScope.unsupported => '不支持的范围',
  };
  if (key.startDate == key.endDate) return '$scope · ${date(key.startDate)}';
  return '$scope · ${date(key.startDate)} – ${date(key.endDate)}';
}

String _formatTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
}
