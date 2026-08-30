import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_section.dart'
    as diary;
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapScreen extends ConsumerStatefulWidget {
  const RecapScreen({super.key});

  @override
  ConsumerState<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends ConsumerState<RecapScreen> {
  final GlobalKey _diaryKey = GlobalKey();
  bool _diaryChangedSinceGeneration = false;

  Future<void> _refresh() async {
    setState(() => _diaryChangedSinceGeneration = false);
    await ref.read(recapProvider.notifier).refresh();
  }

  void _selectRange(DateRange range) {
    if (ref.read(dashboardRangeProvider).range == range) return;
    setState(() => _diaryChangedSinceGeneration = false);
    ref.read(dashboardRangeProvider.notifier).select(range);
  }

  Widget _diaryWorkspace(DateRangeSelection selection) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      diary.DiarySection(
        key: _diaryKey,
        date: selection.effectiveDay,
        range: _diaryRangeFor(selection),
        onContentChanged: () =>
            setState(() => _diaryChangedSinceGeneration = true),
      ),
      if (_diaryChangedSinceGeneration) ...[
        const SizedBox(height: TimeTraceSpace.xs),
        _DiaryRefreshNotice(onRefresh: _refresh),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final asyncRecap = ref.watch(recapProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final aiSettings =
        ref.watch(recapAiSettingsProvider).value ?? const RecapAiSettings();

    return Scaffold(
      appBar: AppBar(
        title: const Text('回顾'),
        actions: [
          IconButton(
            tooltip: '重新生成',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TimeTraceLayout.dashboardWidth,
            ),
            child: ListView(
              padding: TimeTraceLayout.pagePadding(constraints.maxWidth),
              children: [
                _RangeSelector(selection: selection, onSelected: _selectRange),
                const SizedBox(height: TimeTraceSpace.sm),
                asyncRecap.when(
                  skipLoadingOnReload: true,
                  loading: () => _RecapWorkspacePlaceholder(
                    status: const _RecapLoading(),
                    journal: _diaryWorkspace(selection),
                  ),
                  error: (error, _) => _RecapWorkspacePlaceholder(
                    status: _RecapError(onRetry: _refresh),
                    journal: _diaryWorkspace(selection),
                  ),
                  data: (state) => RecapSummaryView(
                    result: state.result,
                    generatedAt: state.generatedAt,
                    aiEnabled: aiSettings.enabled,
                    diaryIncludedInAi: aiSettings.includeDiaryEntries,
                    aiError: state.aiError,
                    journal: _diaryWorkspace(selection),
                  ),
                ),
                asyncRecap.when(
                  skipLoadingOnReload: true,
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (state) => Padding(
                    padding: const EdgeInsets.only(top: TimeTraceSpace.sm),
                    child: RecapHistoryView(
                      snapshot: state.result.snapshot,
                      emptyMessage: selection.range == DateRange.month
                          ? '本月暂不展示逐条历史，请切换到今天或本周查看。'
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

diary.DiaryRange _diaryRangeFor(DateRangeSelection selection) =>
    switch (selection.range) {
      DateRange.today ||
      DateRange.yesterday ||
      DateRange.custom => diary.DiaryRange.day,
      DateRange.week => diary.DiaryRange.week,
      DateRange.month => diary.DiaryRange.month,
    };

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selection, required this.onSelected});

  final DateRangeSelection selection;
  final ValueChanged<DateRange> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: TimeTraceSpace.xs,
    runSpacing: TimeTraceSpace.xs,
    children: [
      for (final item in const [
        ('今天', DateRange.today),
        ('昨天', DateRange.yesterday),
        ('本周', DateRange.week),
        ('本月', DateRange.month),
      ])
        ChoiceChip(
          label: Text(item.$1),
          selected: selection.range == item.$2,
          onSelected: (_) => onSelected(item.$2),
        ),
    ],
  );
}

class _RecapError extends StatelessWidget {
  const _RecapError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 112,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded),
          const SizedBox(height: TimeTraceSpace.xs),
          const Text('生成回顾失败，日记仍可正常使用'),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _RecapLoading extends StatelessWidget {
  const _RecapLoading();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 112,
    child: Center(
      child: SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

class _RecapWorkspacePlaceholder extends StatelessWidget {
  const _RecapWorkspacePlaceholder({
    required this.status,
    required this.journal,
  });

  final Widget status;
  final Widget journal;

  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('recap-journal-surface'),
    child: Padding(
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          status,
          const Divider(height: TimeTraceSpace.xl),
          journal,
        ],
      ),
    ),
  );
}

class _DiaryRefreshNotice extends StatelessWidget {
  const _DiaryRefreshNotice({required this.onRefresh});

  final VoidCallback onRefresh;

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
        color: scheme.primaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: TimeTraceSpace.xs),
          const Expanded(child: Text('日记已更新，可重新生成总结。')),
          TextButton(onPressed: onRefresh, child: const Text('重新生成')),
        ],
      ),
    );
  }
}
