import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

/// Provider-free Recap surface used by the screen, previews and widget tests.
///
/// The Recap page deliberately contains only one narrative surface and one
/// usage-history surface. Dashboard metrics remain on the Overview page.
class RecapReportView extends StatelessWidget {
  const RecapReportView({
    super.key,
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    this.diaryIncludedInAi = false,
    this.aiError,
    this.journal,
    this.historyEmptyMessage,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final bool diaryIncludedInAi;
  final String? aiError;

  /// Optional diary editor/feed placed in the same narrative surface.
  final Widget? journal;

  /// Optional range-specific copy when detailed usage history is unavailable.
  final String? historyEmptyMessage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RecapSummaryView(
        result: result,
        generatedAt: generatedAt,
        aiEnabled: aiEnabled,
        diaryIncludedInAi: diaryIncludedInAi,
        aiError: aiError,
        journal: journal,
      ),
      const SizedBox(height: TimeTraceSpace.sm),
      RecapHistoryView(
        snapshot: result.snapshot,
        emptyMessage: historyEmptyMessage,
      ),
    ],
  );
}

/// The narrative part of Recap, optionally followed by the diary editor/feed.
class RecapSummaryView extends StatelessWidget {
  const RecapSummaryView({
    super.key,
    required this.result,
    required this.generatedAt,
    required this.aiEnabled,
    this.diaryIncludedInAi = false,
    this.aiError,
    this.journal,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final bool aiEnabled;
  final bool diaryIncludedInAi;
  final String? aiError;
  final Widget? journal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final diaryStatus = _diaryStatus(
      result: result,
      aiEnabled: aiEnabled,
      diaryIncludedInAi: diaryIncludedInAi,
    );

    return Card(
      key: const ValueKey('recap-journal-surface'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeyedSubtree(
              key: const ValueKey('recap-summary-surface'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _OriginBadge(
                            result: result,
                            aiEnabled: aiEnabled,
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.xs),
                      Text(
                        _generatedLabel(generatedAt),
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  Text(
                    result.headline,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  Text(
                    result.summary,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.55,
                    ),
                  ),
                  if (diaryStatus != null) ...[
                    const SizedBox(height: TimeTraceSpace.sm),
                    Row(
                      children: [
                        Icon(
                          Icons.menu_book_outlined,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: TimeTraceSpace.xxs),
                        Expanded(
                          child: Text(
                            diaryStatus,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (aiError != null && aiError!.trim().isNotEmpty) ...[
                    const SizedBox(height: TimeTraceSpace.sm),
                    _AiErrorMessage(message: aiError!.trim()),
                  ],
                ],
              ),
            ),
            if (journal != null) ...[
              const Divider(height: TimeTraceSpace.xl),
              journal!,
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
        ? 'AI 总结 · ${result.model?.trim().isNotEmpty == true ? result.model : '模型'}'
        : aiEnabled
        ? '本地总结 · AI 已回退'
        : '本地总结';

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
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
            isAi ? Icons.auto_awesome_outlined : Icons.subject_rounded,
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

class _AiErrorMessage extends StatelessWidget {
  const _AiErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single bounded list of when applications were used.
class RecapHistoryView extends StatefulWidget {
  const RecapHistoryView({
    super.key,
    required this.snapshot,
    this.emptyMessage,
  });

  final RecapSnapshot snapshot;
  final String? emptyMessage;

  @override
  State<RecapHistoryView> createState() => _RecapHistoryViewState();
}

class _RecapHistoryViewState extends State<RecapHistoryView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segments = compactUsageHistory(widget.snapshot.activityFacts);
    final showsDate = !_sameDay(widget.snapshot.start, widget.snapshot.end);

    return Card(
      key: const ValueKey('recap-history'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 19, color: scheme.primary),
                const SizedBox(width: TimeTraceSpace.xs),
                Text(
                  '历史记录',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (segments.isNotEmpty)
                  Text(
                    '${segments.length} 条',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.sm),
            if (segments.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: TimeTraceSpace.lg,
                ),
                child: Text(
                  widget.emptyMessage ?? _defaultEmptyMessage(widget.snapshot),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Container(
                key: const ValueKey('recap-history-list'),
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                clipBehavior: Clip.antiAlias,
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: segments.length > 5,
                  child: ListView.separated(
                    controller: _scrollController,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: segments.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      indent: TimeTraceSpace.sm,
                      endIndent: TimeTraceSpace.sm,
                    ),
                    itemBuilder: (context, index) => _HistoryRow(
                      segment: segments[index],
                      showDate: showsDate,
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

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.segment, required this.showDate});

  final UsageHistorySegment segment;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = _historyTimeLabel(segment, showDate: showDate);

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TimeTraceSpace.sm,
          vertical: TimeTraceSpace.xs,
        ),
        child: Row(
          children: [
            SizedBox(
              width: showDate ? 92 : 48,
              child: Tooltip(
                message: time,
                child: Text(
                  time,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Tooltip(
                      message: segment.appName,
                      child: Text(
                        segment.appName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  if (segment.sourceCount > 1) ...[
                    const SizedBox(width: TimeTraceSpace.xs),
                    Text(
                      '${segment.sourceCount} 段',
                      maxLines: 1,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            Text(
              _historyDuration(segment.activeSeconds),
              maxLines: 1,
              style: theme.textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class UsageHistorySegment {
  const UsageHistorySegment({
    required this.appName,
    required this.start,
    required this.end,
    required this.activeSeconds,
    required this.sourceCount,
    required this.timeKnown,
    required this.sourceIndex,
  });

  final String appName;
  final DateTime start;
  final DateTime end;
  final int activeSeconds;
  final int sourceCount;
  final bool timeKnown;
  final int sourceIndex;

  UsageHistorySegment copyWith({
    DateTime? end,
    int? activeSeconds,
    int? sourceCount,
  }) => UsageHistorySegment(
    appName: appName,
    start: start,
    end: end ?? this.end,
    activeSeconds: activeSeconds ?? this.activeSeconds,
    sourceCount: sourceCount ?? this.sourceCount,
    timeKnown: timeKnown,
    sourceIndex: sourceIndex,
  );
}

/// Compacts raw sessions into a readable history without altering totals.
///
/// Adjacent sessions for the same application are merged when their gap is at
/// most 90 seconds. Unknown timestamps stay as separate rows to avoid implying
/// an order or continuity the source data does not establish.
@visibleForTesting
List<UsageHistorySegment> compactUsageHistory(List<RecapActivityFact> facts) {
  final parsed = <UsageHistorySegment>[];
  for (var index = 0; index < facts.length; index++) {
    final fact = facts[index];
    final appName = fact.appName.trim();
    final activeSeconds = fact.durationSeconds;
    if (appName.isEmpty || activeSeconds <= 0) continue;

    final parsedStart = _parseStartedAt(fact);
    final fallbackStart = DateTime(
      fact.date.year,
      fact.date.month,
      fact.date.day,
    ).add(Duration(microseconds: index));
    final start = parsedStart ?? fallbackStart;
    parsed.add(
      UsageHistorySegment(
        appName: appName,
        start: start,
        end: start.add(Duration(seconds: activeSeconds)),
        activeSeconds: activeSeconds,
        sourceCount: 1,
        timeKnown: parsedStart != null,
        sourceIndex: index,
      ),
    );
  }

  parsed.sort((a, b) {
    if (a.timeKnown != b.timeKnown) return a.timeKnown ? -1 : 1;
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.sourceIndex.compareTo(b.sourceIndex);
  });

  final compacted = <UsageHistorySegment>[];
  for (final next in parsed) {
    if (compacted.isNotEmpty) {
      final current = compacted.last;
      final gapSeconds = next.start.difference(current.end).inSeconds;
      if (current.timeKnown &&
          next.timeKnown &&
          current.appName == next.appName &&
          gapSeconds <= 90) {
        compacted[compacted.length - 1] = current.copyWith(
          end: next.end.isAfter(current.end) ? next.end : current.end,
          activeSeconds: current.activeSeconds + next.activeSeconds,
          sourceCount: current.sourceCount + next.sourceCount,
        );
        continue;
      }
    }
    compacted.add(next);
  }
  return List.unmodifiable(compacted);
}

DateTime? _parseStartedAt(RecapActivityFact fact) {
  final raw = fact.startedAt.trim();
  if (raw.isEmpty) return null;

  final iso = DateTime.tryParse(raw);
  if (iso != null && (raw.contains('-') || raw.contains('T'))) return iso;

  final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
  if (match == null) return null;
  final hour = int.tryParse(match.group(1)!);
  final minute = int.tryParse(match.group(2)!);
  final second = int.tryParse(match.group(3) ?? '0');
  if (hour == null ||
      minute == null ||
      second == null ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  return DateTime(
    fact.date.year,
    fact.date.month,
    fact.date.day,
    hour,
    minute,
    second,
  );
}

String? _diaryStatus({
  required RecapResult result,
  required bool aiEnabled,
  required bool diaryIncludedInAi,
}) {
  if (!aiEnabled) return null;
  if (!diaryIncludedInAi) return '日记未发送给 AI';
  if (result.snapshot.diaryEntries.isEmpty) return '当前范围没有已发布日记';
  if (result.isAiEnhanced) return '已结合已发布日记';
  return '已允许 AI 使用已发布日记';
}

String _defaultEmptyMessage(RecapSnapshot snapshot) {
  final coveredDays = snapshot.end.difference(snapshot.start).inDays + 1;
  if (coveredDays > 7) return '当前范围暂不提供逐条使用历史';
  if (snapshot.activeSeconds > 0) return '当前范围有使用时长，但没有可展示的逐条历史记录';
  return '当前范围暂无使用历史';
}

String _historyTimeLabel(
  UsageHistorySegment segment, {
  required bool showDate,
}) {
  if (!segment.timeKnown) return showDate ? _shortDate(segment.start) : '—';
  final time =
      '${segment.start.hour.toString().padLeft(2, '0')}:${segment.start.minute.toString().padLeft(2, '0')}';
  return showDate ? '${_shortDate(segment.start)} · $time' : time;
}

String _shortDate(DateTime value) => '${value.month}月${value.day}日';

String _historyDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  if (safe < 60) return '${safe}s';
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final remainingSeconds = safe % 60;
  if (hours > 0) {
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }
  if (remainingSeconds == 0) return '${minutes}m';
  return '${minutes}m ${remainingSeconds}s';
}

String _generatedLabel(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')} 生成';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
