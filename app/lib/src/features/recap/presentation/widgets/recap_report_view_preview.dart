import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';

@Preview(name: '回顾 · 本地桌面', size: Size(1180, 760))
Widget recapReportDesktopPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: RecapReportView(
        result: _previewResult,
        generatedAt: DateTime(2026, 8, 30, 12, 42),
        aiEnabled: false,
      ),
    ),
  ),
);

@Preview(name: '回顾 · AI 增强桌面', size: Size(1180, 760))
Widget recapReportAiDesktopPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: RecapReportView(
        result: _previewAiResult,
        generatedAt: DateTime(2026, 8, 30, 13, 19),
        aiEnabled: true,
        diaryIncludedInAi: true,
      ),
    ),
  ),
);

final _previewSnapshot = RecapSnapshot(
  label: '今天',
  start: _previewDate,
  end: _previewDate,
  activeSeconds: 15480,
  idleSeconds: 0,
  previousActiveSeconds: 26160,
  topApps: [
    RecapAppFact(
      name: 'TFTTencentClient-Win64-Shipping',
      activeSeconds: 13320,
      idleSeconds: 0,
    ),
    RecapAppFact(name: 'Edge', activeSeconds: 1041, idleSeconds: 0),
    RecapAppFact(name: '英雄联盟', activeSeconds: 776, idleSeconds: 0),
  ],
  sessionCount: 142,
  contextSwitches: 120,
  longestActiveStreakSeconds: 8400,
  peakHour: 0,
  peakHourActiveSeconds: 5700,
  diaryEntries: [
    '晚上整理了 TimeTrace 的 AI Recap 页面，并检查了 Windows 构建。',
    '轮播图还是更喜欢原来的布局，图表不需要默认展示。',
  ],
  activityFacts: [
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T00:04:00Z',
      appName: 'TFTTencentClient-Win64-Shipping',
      durationSeconds: 5700,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T01:40:00Z',
      appName: 'Microsoft Edge',
      durationSeconds: 1041,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T02:03:00Z',
      appName: '英雄联盟',
      durationSeconds: 776,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T02:18:00Z',
      appName: 'TimeTrace',
      durationSeconds: 253,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T02:24:00Z',
      appName: '资源管理器',
      durationSeconds: 141,
    ),
    RecapActivityFact(
      date: _previewDate,
      startedAt: '2026-08-30T02:28:00Z',
      appName: 'QQ',
      durationSeconds: 131,
    ),
  ],
);

final _previewResult = RecapResult(
  headline: '今天主要活跃时间集中在 TFTTencentClient-Win64-Shipping',
  summary:
      '今天主要使用了 TFTTencentClient-Win64-Shipping，随后短暂切换到 Edge 与英雄联盟。日记里还记录了对 AI Recap 页面和 Windows 构建的整理。',
  insights: const [],
  snapshot: _previewSnapshot,
  origin: RecapOrigin.local,
);

final _previewAiResult = RecapResult(
  headline: '主要整理了 TimeTrace 回顾体验',
  summary:
      '今天先长时间使用 TFT 客户端，之后切换到 Edge、英雄联盟和 TimeTrace。结合日记，主要在调整 AI Recap 页面、恢复原轮播布局，并检查 Windows 构建。',
  insights: _previewResult.insights,
  snapshot: _previewSnapshot,
  origin: RecapOrigin.ai,
  model: 'deepseek-v4-flash',
);

final _previewDate = DateTime(2026, 8, 30);
