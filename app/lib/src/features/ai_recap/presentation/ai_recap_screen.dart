import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_report_period.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

/// Manual daily, weekly and monthly time reports.
///
/// Opening the page, changing report type and navigating periods are local.
/// DeepSeek is contacted only after the user presses the generate button.
class AiRecapScreen extends ConsumerStatefulWidget {
  const AiRecapScreen({super.key, this.now});

  /// Test seam for deterministic local-calendar periods.
  final DateTime? now;

  @override
  ConsumerState<AiRecapScreen> createState() => _AiRecapScreenState();
}

class _AiRecapScreenState extends ConsumerState<AiRecapScreen> {
  late AiReportPeriod _period;
  Timer? _midnightTimer;

  @override
  void initState() {
    super.initState();
    _period = AiReportPeriod.current(AiRecapScope.daily, now: widget.now);
    _scheduleMidnightRefresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(aiRecapControllerProvider.notifier).synchronize();
    });
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  void _scheduleMidnightRefresh() {
    if (widget.now != null) return;
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      if (!mounted) return;
      setState(() {
        final wasCurrent = _period.isCurrent;
        final newToday = DateTime.now();
        _period = wasCurrent
            ? AiReportPeriod.current(_period.scope, now: newToday)
            : _period.withToday(newToday);
      });
      _scheduleMidnightRefresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiRecapControllerProvider);
    final selectedKey = _period.range;
    final projection = state.projection(selectedKey);
    final latestOfType = state.latestReportFor(_period.scope);
    final canShowLatestOfType =
        projection.result == null &&
        (projection.generating || projection.failure != null);
    final displayedResult =
        projection.result ?? (canShowLatestOfType ? latestOfType : null);
    final showingSavedReport =
        displayedResult != null && displayedResult.rangeKey != selectedKey;
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
        title: const Text('AI 时间报告'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ReportControls(
                  period: _period,
                  generating: projection.generating,
                  busy: state.pendingKey != null,
                  configured: state.status.configured,
                  serviceAvailable: state.status.serviceAvailable,
                  hasReport: projection.result != null,
                  onScopeChanged: (scope) => setState(() {
                    _period = AiReportPeriod.current(scope, now: widget.now);
                  }),
                  onPrevious: () => setState(() {
                    _period = _period.previous();
                  }),
                  onNext: _period.canGoNext
                      ? () => setState(() {
                          _period = _period.next();
                        })
                      : null,
                  onGenerate:
                      state.status.configured &&
                          state.status.serviceAvailable &&
                          state.pendingKey == null
                      ? () => controller.generate(selectedKey)
                      : null,
                ),
                if (!state.status.serviceAvailable) ...[
                  const SizedBox(height: 12),
                  const _Notice(
                    key: Key('ai-recap-service-unavailable'),
                    icon: Icons.sync_problem_outlined,
                    message: 'AI 报告本地服务暂不可用，请重启 TimeTrace。时间统计不受影响。',
                  ),
                ] else if (!state.status.configured) ...[
                  const SizedBox(height: 12),
                  _Notice(
                    key: const Key('ai-recap-not-configured'),
                    icon: Icons.key_off_outlined,
                    message: '还未配置 DeepSeek API Key，配置后才能生成报告。',
                    actionLabel: '去设置',
                    onAction: () => context.push('/settings'),
                  ),
                ],
                if (projection.failure case final failure?) ...[
                  const SizedBox(height: 12),
                  _ErrorNotice(
                    failure: failure,
                    onRetry:
                        failure.retryable &&
                            state.status.configured &&
                            state.status.serviceAvailable &&
                            state.pendingKey == null
                        ? () => controller.generate(selectedKey)
                        : null,
                  ),
                ],
                if (showingSavedReport) ...[
                  const SizedBox(height: 12),
                  _Notice(
                    key: const Key('ai-report-saved-fallback'),
                    icon: Icons.history_outlined,
                    message: projection.generating
                        ? '正在生成所选${_period.scope.label}，下方继续显示上一份已保存报告。'
                        : '所选周期尚无报告，下方显示最近保存的${_period.scope.label}：'
                              '${_formatRange(displayedResult.rangeKey)}。',
                  ),
                ],
                const SizedBox(height: 20),
                if (displayedResult case final result?)
                  _ReportResult(
                    result: result,
                    generating: projection.generating,
                  )
                else
                  _EmptyReport(
                    period: _period,
                    generating: projection.generating,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportControls extends StatelessWidget {
  const _ReportControls({
    required this.period,
    required this.generating,
    required this.busy,
    required this.configured,
    required this.serviceAvailable,
    required this.hasReport,
    required this.onScopeChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onGenerate,
  });

  final AiReportPeriod period;
  final bool generating;
  final bool busy;
  final bool configured;
  final bool serviceAvailable;
  final bool hasReport;
  final ValueChanged<AiRecapScope> onScopeChanged;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selector = SegmentedButton<AiRecapScope>(
      key: const Key('ai-recap-range-selector'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: AiRecapScope.daily, label: Text('日报')),
        ButtonSegment(value: AiRecapScope.weekly, label: Text('周报')),
        ButtonSegment(value: AiRecapScope.monthly, label: Text('月报')),
      ],
      selected: {period.scope},
      onSelectionChanged: (selection) => onScopeChanged(selection.first),
    );
    final generateButton = FilledButton.icon(
      key: const Key('ai-recap-generate'),
      onPressed: onGenerate,
      icon: busy
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome, size: 18),
      label: Text(
        generating
            ? '正在生成${period.scope.label}…'
            : busy
            ? '其他报告正在生成…'
            : '${hasReport ? '重新生成' : '生成'}${period.scope.label}',
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '按周期回看时间投入',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '选择日报、周报或月报。只有点击生成时才会连接 DeepSeek。',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      selector,
                      const SizedBox(height: 12),
                      generateButton,
                    ],
                  );
                }
                return Row(
                  children: [
                    selector,
                    const Spacer(),
                    const SizedBox(width: 16),
                    generateButton,
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('ai-report-previous-period'),
                    tooltip: '上一周期',
                    onPressed: onPrevious,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      label: '${period.scope.label}周期：${period.label}',
                      child: Text(
                        period.label,
                        key: const Key('ai-report-period-label'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('ai-report-next-period'),
                    tooltip: onNext == null ? '已经是当前周期' : '下一周期',
                    onPressed: onNext,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
            const Divider(height: 25),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 19, color: colors.primary),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    '仅发送应用名称与聚合时长；不会发送窗口标题、按键、文件路径、'
                    '可执行路径或日记。打开页面、切换周期都不会联网。',
                  ),
                ),
              ],
            ),
            if (!configured || !serviceAvailable) ...[
              const SizedBox(height: 8),
              Text(
                !serviceAvailable ? '本地 AI 服务不可用。' : '请先在设置中配置 AI 服务。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReportResult extends StatelessWidget {
  const _ReportResult({required this.result, required this.generating});

  final AiRecapResult result;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    final topApps = _topApplications(result);
    return SelectionArea(
      key: const Key('ai-recap-result'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (generating) ...[
            Semantics(
              liveRegion: true,
              label: '正在生成新的 AI 时间报告，已保存内容仍可阅读',
              child: const LinearProgressIndicator(
                key: Key('ai-recap-inline-progress'),
              ),
            ),
            const SizedBox(height: 6),
            const Text('正在生成新报告，已保存内容仍可阅读。'),
            const SizedBox(height: 12),
          ],
          _SectionCard(
            icon: Icons.subject_outlined,
            title: '本期概览',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_formatDuration(result.totalActiveSeconds)} · '
                  '${result.applicationCount} 个应用',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _StatementContent(statement: result.summary),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final investments = _SectionCard(
                icon: Icons.bar_chart_outlined,
                title: '主要投入',
                child: _TopApplications(
                  items: topApps,
                  totalSeconds: result.totalActiveSeconds,
                ),
              );
              final observations = _SectionCard(
                icon: Icons.visibility_outlined,
                title: '使用观察',
                child: _BulletList(items: result.highlights),
              );
              if (constraints.maxWidth < 700) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    investments,
                    const SizedBox(height: 12),
                    observations,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: investments),
                  const SizedBox(width: 12),
                  Expanded(child: observations),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          _SectionCard(
            icon: Icons.explore_outlined,
            title: '下期建议',
            child: _BulletList(items: result.suggestions),
          ),
          const SizedBox(height: 14),
          _CapabilityBoundary(result: result),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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

class _TopApplications extends StatelessWidget {
  const _TopApplications({required this.items, required this.totalSeconds});

  final List<AiRecapEvidence> items;
  final int totalSeconds;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('暂无可展示的应用明细。');
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var index = 0; index < items.length; index++)
          Padding(
            padding: EdgeInsets.only(
              bottom: index == items.length - 1 ? 0 : 12,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(width: 24, child: Text('${index + 1}.')),
                    Expanded(
                      child: Text(
                        items[index].appName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_formatDuration(items[index].activeSeconds)),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${_share(items[index].activeSeconds, totalSeconds)}%',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: totalSeconds <= 0
                        ? 0
                        : (items[index].activeSeconds / totalSeconds).clamp(
                            0.0,
                            1.0,
                          ),
                    color: colors.primary,
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.items});

  final List<AiRecapStatement> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Text('暂无可展示内容。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(statement.text),
      const SizedBox(height: 5),
      Text(
        '数据依据：${statement.evidence.map(_formatEvidence).join('、')}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.35,
        ),
      ),
    ],
  );
}

class _CapabilityBoundary extends StatelessWidget {
  const _CapabilityBoundary({required this.result});

  final AiRecapResult result;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '报告只解释应用使用时长，不代表工作成果或绩效评价。\n'
                '${result.rangeKey.scope.label} · '
                '${_formatRange(result.rangeKey)} · ${result.model.label} · '
                '${_formatTime(result.generatedAt)} 生成',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyReport extends StatelessWidget {
  const _EmptyReport({required this.period, required this.generating});

  final AiReportPeriod period;
  final bool generating;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('ai-recap-empty'),
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Column(
        children: [
          if (generating)
            const SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          else
            Icon(
              Icons.summarize_outlined,
              size: 36,
              color: Theme.of(context).colorScheme.primary,
            ),
          const SizedBox(height: 12),
          Text(
            generating
                ? '正在生成${period.scope.label}'
                : '还没有这份${period.scope.label}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 5),
          Text(
            generating
                ? '可以继续查看其他周期；完成后会自动显示并保存。'
                : '选择报告类型和周期，然后手动生成。打开页面不会自动联网。',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.tertiaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(icon, color: colors.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
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

List<AiRecapEvidence> _topApplications(AiRecapResult result) {
  if (result.topApplications.isNotEmpty) {
    final values = result.topApplications.toList()
      ..sort(
        (left, right) => right.activeSeconds.compareTo(left.activeSeconds),
      );
    return values.take(5).toList(growable: false);
  }
  final byName = <String, AiRecapEvidence>{};
  for (final statement in [
    result.summary,
    ...result.highlights,
    ...result.suggestions,
  ]) {
    for (final item in statement.evidence) {
      final existing = byName[item.appName];
      if (existing == null || item.activeSeconds > existing.activeSeconds) {
        byName[item.appName] = item;
      }
    }
  }
  final values = byName.values.toList()
    ..sort((left, right) => right.activeSeconds.compareTo(left.activeSeconds));
  return values.take(5).toList(growable: false);
}

String _failureMessage(AiRecapFailureCode code) => switch (code) {
  AiRecapFailureCode.notConfigured => '还未配置 DeepSeek API Key，请前往设置。',
  AiRecapFailureCode.invalidRange => '报告周期无效，请重新选择。',
  AiRecapFailureCode.unsupportedModel => '设置中的默认模型暂不受支持。',
  AiRecapFailureCode.noUsageData => '这个周期还没有可用的活动时长。',
  AiRecapFailureCode.requestTooLarge => '聚合数据超出安全上限，本次未发送。',
  AiRecapFailureCode.network => '暂时无法连接 DeepSeek，请检查网络后重试。',
  AiRecapFailureCode.timeout => '请求超时，已有报告已保留。',
  AiRecapFailureCode.authentication => 'DeepSeek 未接受当前 API Key，请在设置中更新。',
  AiRecapFailureCode.rateLimited => 'DeepSeek 请求过于频繁，请稍后手动重试。',
  AiRecapFailureCode.providerUnavailable => 'DeepSeek 暂时不可用，请稍后手动重试。',
  AiRecapFailureCode.credentialStoreUnavailable =>
    '系统凭据服务暂不可用，请检查 Windows 凭据服务后重试。',
  AiRecapFailureCode.localStorageUnavailable => '无法安全保存报告，已有报告已保留，请检查本机存储。',
  AiRecapFailureCode.invalidResponse => '返回的报告格式不完整，已有报告已保留。',
  AiRecapFailureCode.busy => '已有一份报告正在生成。',
  AiRecapFailureCode.bridgeUnavailable => 'AI 报告服务暂不可用，请重启 TimeTrace。',
};

String _formatRange(AiRecapRangeKey key) {
  String date(DateTime value) => '${value.year}年${value.month}月${value.day}日';
  if (key.startDate == key.endDate) return date(key.startDate);
  return '${date(key.startDate)}—${date(key.endDate)}';
}

String _formatDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainingSeconds = seconds % 60;
  final parts = <String>[];
  if (hours > 0) parts.add('$hours 小时');
  if (minutes > 0) parts.add('$minutes 分钟');
  if (remainingSeconds > 0 || parts.isEmpty) parts.add('$remainingSeconds 秒');
  return parts.join(' ');
}

int _share(int seconds, int totalSeconds) => totalSeconds <= 0
    ? 0
    : (seconds * 100 / totalSeconds).round().clamp(0, 100).toInt();

String _formatEvidence(AiRecapEvidence evidence) =>
    '${evidence.appName} ${_formatDuration(evidence.activeSeconds)}';

String _formatTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '${local.year}年${local.month}月${local.day}日 '
      '${two(local.hour)}:${two(local.minute)}';
}
