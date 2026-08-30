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
  diaryEntries: [],
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
  summary: '活跃 4 小时 18 分，最长连续活跃 2 小时 20 分；较上一同长度区间减少约 40.9%。',
  insights: [
    'TFTTencentClient-Win64-Shipping 活跃 3 小时 42 分，占全部活跃时间约 86%。',
    '峰值时段为 00:00–01:00，该小时累计活跃 1 小时 35 分。',
    '记录到 142 个活跃片段与 120 次应用切换。',
    '当前记录区间内活跃占比为 100%。',
  ],
  snapshot: _previewSnapshot,
  origin: RecapOrigin.local,
);

final _previewAiResult = RecapResult(
  headline: '主要在 TFT 客户端活动，零点前后最集中',
  summary: '今天的大部分活跃时间集中在 TFTTencentClient-Win64-Shipping，随后短暂切换到 Edge 与英雄联盟；00:00–01:00 是记录中最活跃的时段。',
  insights: _previewResult.insights,
  snapshot: _previewSnapshot,
  origin: RecapOrigin.ai,
  model: 'deepseek-v4-flash',
);

final _previewDate = DateTime(2026, 8, 30);
