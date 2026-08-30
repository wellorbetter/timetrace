import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

/// Provider-free Recap surface used by the screen, previews and tests.
///
/// Overview owns the numeric dashboard. Recap intentionally keeps only the
/// generated narrative, diary context state and a bounded local usage history.
class RecapReportView extends StatelessWidget {
  const RecapReportView({
    super.key,
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    this.diaryIncludedInAi = false,
    this.aiError,
    this.onOpenSettings,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final bool diaryIncludedInAi;
  final String? aiError;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NarrativeSurface(
          result: result,
          generatedAt: generatedAt,
          aiEnabled: aiEnabled,
          diaryIncludedInAi: diaryIncludedInAi,
          aiError: aiError,
          onOpenSettings: onOpenSettings,
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        _UsageHistoryPanel(snapshot: result.snapshot),
      ],
    );
  }
}

class _NarrativeSurface extends StatelessWidget {
  const _NarrativeSurface({
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    required this.diaryIncludedInAi,
    required this.aiError,
    required this.onOpenSettings,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final bool diaryIncludedInAi;
  final String? aiError;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      key: const ValueKey('recap-summary-surface'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _OriginBadge(result: result, aiEnabled: aiEnabled),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Text(
                  _generatedLabel(generatedAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.headline,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  Text(
                    result.summary,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.65,
                    ),
                  ),
                ],
              ),
            ),
            if (result.snapshot.diaryEntries.isNotEmpty) ...[
              const SizedBox(height: TimeTraceSpace.md),
              _DiaryContextStatus(
                count: result.snapshot.diaryEntries.length,
                isAiResult: result.isAiEnhanced,
                aiEnabled: aiEnabled,
                includedInAi: diaryIncludedInAi,
                onOpenSettings: onOpenSettings,
              ),
            ],
            if (aiError != null) ...[
              const SizedBox(height: TimeTraceSpace.sm),
              _InfoNotice(
                icon: Icons.info_outline_rounded,
                text: aiError!,
                background: scheme.tertiaryContainer,
                foreground: scheme.onTertiaryContainer,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OriginBadge extends StatelessWidget {
  const _OriginBadge({required this.result, required this.aiEnabled});

  final RecapResult result;
  final bool aiEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isAi = result.isAiEnhanced;
    final label = isAi
        ? 'AI 总结 · ${result.model ?? '模型'}'
        : aiEnabled
        ? '本地总结 · AI 已回退'
        : '本地总结';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: isAi ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isAi ? Icons.auto_awesome_outlined : Icons.lock_outline_rounded,
            size: 14,
            color: isAi ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: TimeTraceSpace.xxs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: isAi
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryContextStatus extends StatelessWidget {
  const _DiaryContextStatus({
    required this.count,
    required this.isAiResult,
    required this.aiEnabled,
    required this.includedInAi,
    required this.onOpenSettings,
  });

  final int count;
  final bool isAiResult;
  final bool aiEnabled;
  final bool includedInAi;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (isAiResult && includedInAi) {
      return _InfoNotice(
        icon: Icons.auto_stories_outlined,
        text: '本次总结已结合 $count 篇已发布日记。',
        background: scheme.primaryContainer.withValues(alpha: 0.62),
        foreground: scheme.onPrimaryContainer,
      );
    }

    if (!aiEnabled) {
      return _InfoNotice(
        icon: Icons.menu_book_outlined,
        text: '本地总结已参考 $count 篇日记，日记内容没有上传。',
        background: scheme.surfaceContainerLow,
        foreground: scheme.onSurfaceVariant,
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.sm,
        TimeTraceSpace.xs,
        TimeTraceSpace.xs,
        TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 17,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Text(
              '发现 $count 篇日记；当前未发送给 AI。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (onOpenSettings != null)
            TextButton(onPressed: onOpenSettings, child: const Text('允许结合')),
        ],
      ),
    );
  }
}

class _InfoNotice extends StatelessWidget {
  const _InfoNotice({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageHistoryPanel extends StatelessWidget {
  const _UsageHistoryPanel({required this.snapshot});

  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segments = compactUsageHistory(snapshot.activityFacts);
    final multipleDays = !_sameDay(snapshot.start, snapshot.end);
    final rawCount = snapshot.activityFacts.length;
    final subtitle = rawCount == 0
        ? '本机还没有可展示的逐段使用记录。'
        : rawCount == segments.length
        ? '$rawCount 条本机记录 · 从早到晚'
        : '$rawCount 条本机记录 · 整理为 ${segments.length} 段';

    return Card(
      key: const ValueKey('recap-usage-history'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(
                      TimeTraceRadius.control,
                    ),
                  ),
                  child: Icon(
                    Icons.history_rounded,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('使用历史', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (segments.isNotEmpty)
                  Text(
                    '列表内滚动',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.sm),
            if (segments.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: TimeTraceSpace.md,
                  vertical: TimeTraceSpace.lg,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Text(
                  snapshot.sessionCount > 0
                      ? '当前范围只有汇总记录，暂时没有逐段使用历史。'
                      : '开始使用应用后，这里会按时间记录使用历史。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.separated(
                    key: const ValueKey('recap-usage-history-list'),
                    primary: false,
                    shrinkWrap: true,
                    itemCount: segments.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      indent: multipleDays ? 132 : 116,
                      endIndent: TimeTraceSpace.sm,
                    ),
                    itemBuilder: (context, index) => _UsageHistoryRow(
                      segment: segments[index],
                      showDate: multipleDays,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
List<UsageHistorySegment> compactUsageHistory(List<RecapActivityFact> facts) {
  final sorted =
      facts
          .where(
            (fact) =>
                fact.durationSeconds > 0 && fact.appName.trim().isNotEmpty,
          )
          .map(
            (fact) => UsageHistorySegment(
              appName: fact.appName.trim(),
              start: _historyStart(fact),
              end: _historyStart(
                fact,
              ).add(Duration(seconds: fact.durationSeconds)),
              activeSeconds: fact.durationSeconds,
              sourceCount: 1,
            ),
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  final compacted = <UsageHistorySegment>[];
  for (final item in sorted) {
    if (compacted.isNotEmpty) {
      final previous = compacted.last;
      final gap = item.start.difference(previous.end).inSeconds;
      if (previous.appName == item.appName && gap >= -5 && gap <= 90) {
        compacted[compacted.length - 1] = UsageHistorySegment(
          appName: previous.appName,
          start: previous.start,
          end: item.end.isAfter(previous.end) ? item.end : previous.end,
          activeSeconds: previous.activeSeconds + item.activeSeconds,
          sourceCount: previous.sourceCount + item.sourceCount,
        );
        continue;
      }
    }
    compacted.add(item);
  }
  return compacted;
}

@visibleForTesting
class UsageHistorySegment {
  const UsageHistorySegment({
    required this.appName,
    required this.start,
    required this.end,
    required this.activeSeconds,
    required this.sourceCount,
  });

  final String appName;
  final DateTime start;
  final DateTime end;
  final int activeSeconds;
  final int sourceCount;
}

class _UsageHistoryRow extends StatelessWidget {
  const _UsageHistoryRow({required this.segment, required this.showDate});

  final UsageHistorySegment segment;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = appColor(segment.appName);
    final short = segment.activeSeconds < 60;
    final startLabel = short
        ? _clockWithSeconds(segment.start)
        : _clock(segment.start);
    final endLabel = short
        ? '至 ${_clockWithSeconds(segment.end)}'
        : '至 ${_clock(segment.end)}';
    final dateLabel = showDate
        ? '${segment.start.month.toString().padLeft(2, '0')}/${segment.start.day.toString().padLeft(2, '0')}'
        : null;

    return Semantics(
      label:
          '${dateLabel == null ? '' : '$dateLabel，'}$startLabel，${segment.appName}，${_historyDuration(segment.activeSeconds)}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TimeTraceSpace.sm,
            vertical: TimeTraceSpace.xs,
          ),
          child: Row(
            children: [
              SizedBox(
                width: showDate ? 96 : 80,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (dateLabel != null)
                      Text(
                        dateLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    Text(
                      startLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      endLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: TimeTraceSpace.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: segment.appName,
                      child: Text(
                        segment.appName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    if (segment.sourceCount > 1)
                      Text(
                        '已合并 ${segment.sourceCount} 个相邻记录',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: TimeTraceSpace.sm),
              Text(
                _historyDuration(segment.activeSeconds),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

DateTime _historyStart(RecapActivityFact fact) {
  final parsed = DateTime.tryParse(fact.startedAt);
  if (parsed != null) return parsed.toLocal();

  final match = RegExp(
    r'(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(fact.startedAt);
  if (match != null) {
    return DateTime(
      fact.date.year,
      fact.date.month,
      fact.date.day,
      int.tryParse(match.group(1) ?? '') ?? 0,
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    );
  }
  return fact.date;
}

String _historyDuration(int seconds) {
  final safe = seconds.clamp(0, 24 * 3600);
  if (safe < 60) return '${safe}s';
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  if (hours == 0) return '${minutes}m';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _clockWithSeconds(DateTime value) =>
    '${_clock(value)}:${value.second.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _generatedLabel(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';
