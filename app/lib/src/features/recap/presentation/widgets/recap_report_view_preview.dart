import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';

@Preview(name: '回顾 · 本地总结', size: Size(1180, 820))
Widget recapReportDesktopPreview() => _RecapPreviewPage(
  result: _previewResult,
  aiEnabled: false,
  generatedAt: DateTime(2026, 8, 30, 12, 42),
);

@Preview(name: '回顾 · AI 与日记', size: Size(1180, 820))
Widget recapReportAiDesktopPreview() => _RecapPreviewPage(
  result: _previewAiResult,
  aiEnabled: true,
  diaryIncludedInAi: true,
  generatedAt: DateTime(2026, 8, 30, 13, 19),
);

class _RecapPreviewPage extends StatelessWidget {
  const _RecapPreviewPage({
    required this.result,
    required this.aiEnabled,
    required this.generatedAt,
    this.diaryIncludedInAi = false,
  });

  final RecapResult result;
  final bool aiEnabled;
  final bool diaryIncludedInAi;
  final DateTime generatedAt;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: TimetraceTheme.light(),
    home: Builder(
      builder: (context) => ColoredBox(
        key: const ValueKey('recap-preview-canvas'),
        color: Theme.of(context).colorScheme.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(TimeTraceSpace.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: RecapReportView(
                result: result,
                generatedAt: generatedAt,
                aiEnabled: aiEnabled,
                diaryIncludedInAi: diaryIncludedInAi,
                journal: const _JournalPreview(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Provider-free stand-in for the real diary editor and published diary feed.
class _JournalPreview extends StatelessWidget {
  const _JournalPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: TimeTraceSpace.xs),
            Text('日记', style: theme.textTheme.titleMedium),
            const SizedBox(width: TimeTraceSpace.xs),
            Text(
              '所选日',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              '2026-08-30',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SizedBox(
                height: 34,
                child: Row(
                  children: [
                    const SizedBox(width: TimeTraceSpace.xs),
                    for (final icon in [
                      Icons.format_bold_rounded,
                      Icons.format_list_bulleted_rounded,
                      Icons.format_quote_rounded,
                      Icons.add_photo_alternate_outlined,
                    ])
                      IconButton(
                        onPressed: () {},
                        icon: Icon(icon, size: 16),
                        color: scheme.onSurfaceVariant,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              const TextField(
                minLines: 2,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: '记录今天做了什么，AI 总结会结合已发布内容…',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(TimeTraceSpace.sm),
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: TimeTraceSpace.sm,
                  vertical: TimeTraceSpace.xxs,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_done_outlined,
                      size: 14,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: TimeTraceSpace.xxs),
                    Text(
                      '草稿自动保存',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.arrow_upward_rounded, size: 14),
                      label: const Text('发布'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                '13:04',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            Expanded(
              child: Container(
                padding: const EdgeInsets.only(bottom: TimeTraceSpace.sm),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        '整理了 Recap 的信息层级，把日记和今日总结放到同一个阅读流程里。',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: TimeTraceSpace.sm),
                    Icon(
                      Icons.edit_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

final _previewSnapshot = RecapSnapshot(
  label: '今天',
  start: _previewDate,
  end: _previewDate,
  activeSeconds: 15480,
  idleSeconds: 0,
  previousActiveSeconds: 26160,
  topApps: const [],
  sessionCount: 0,
  contextSwitches: 0,
  longestActiveStreakSeconds: 0,
  peakHour: null,
  peakHourActiveSeconds: 0,
  diaryEntries: const ['整理了 Recap 的信息层级，把日记和今日总结放到同一个阅读流程里。'],
  activityFacts: [
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T09:18:00',
      appName: 'Visual Studio Code',
      durationSeconds: 2640,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T10:02:00',
      appName: 'Microsoft Edge',
      durationSeconds: 812,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T10:19:00',
      appName: 'Figma',
      durationSeconds: 1170,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T11:07:00',
      appName: 'Visual Studio Code',
      durationSeconds: 3215,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T12:14:00',
      appName: 'TimeTrace',
      durationSeconds: 366,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T12:26:00',
      appName: 'QQ',
      durationSeconds: 129,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T12:34:00',
      appName: '资源管理器',
      durationSeconds: 74,
    ),
  ],
);

final _previewResult = RecapResult(
  headline: '今天主要在整理 Recap 的界面与交互',
  summary: '本地记录显示，你先梳理了界面结构，随后在浏览器里核对展示效果；日记仍保留在下方，可继续补充具体进展。',
  insights: const [],
  snapshot: _previewSnapshot,
  origin: RecapOrigin.local,
);

final _previewAiResult = RecapResult(
  headline: '完成了 Recap 信息层级的整理',
  summary:
      '你今天围绕 Recap 界面做了持续调整：先在编辑器里实现结构，再用浏览器和设计工具检查效果。日记补充说明，重点是把总结与记录合并成一条更连贯的阅读流程。',
  insights: const [],
  snapshot: _previewSnapshot,
  origin: RecapOrigin.ai,
  model: 'deepseek-v4-flash',
);

final _previewDate = DateTime(2026, 8, 30);
