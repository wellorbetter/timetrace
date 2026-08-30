import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';

void main() {
  testWidgets('Recap keeps only narrative, diary and one history surface', (
    tester,
  ) async {
    await _setView(tester, const Size(1000, 760));
    await _pumpReport(
      tester,
      result: _result(snapshot: _snapshot()),
      journal: const Text('日记内容区域', key: ValueKey('journal-slot')),
    );

    expect(find.byKey(const ValueKey('recap-journal-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-summary-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('journal-slot')), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-history')), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);

    final summaryTop = tester
        .getTopLeft(find.byKey(const ValueKey('recap-summary-surface')))
        .dy;
    final journalTop = tester
        .getTopLeft(find.byKey(const ValueKey('journal-slot')))
        .dy;
    final historyTop = tester
        .getTopLeft(find.byKey(const ValueKey('recap-history')))
        .dy;
    expect(summaryTop, lessThan(journalTop));
    expect(journalTop, lessThan(historyTop));

    for (final removedLabel in const [
      '事实依据',
      '时间分配',
      '活动时间线',
      '事实快照',
      '活跃时长',
      '最长连续段',
      '应用切换',
      '最常用',
    ]) {
      expect(find.text(removedLabel), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('history stays bounded and scrolls internally', (tester) async {
    await _setView(tester, const Size(1000, 760));
    final facts = List.generate(
      12,
      (index) => RecapActivityFact(
        date: _date,
        startedAt: '2026-08-30T${index.toString().padLeft(2, '0')}:00:00',
        appName: '应用 ${index.toString().padLeft(2, '0')}',
        durationSeconds: 900,
      ),
    );
    await _pumpReport(
      tester,
      result: _result(snapshot: _snapshot(activityFacts: facts)),
    );

    final historyList = find.byKey(const ValueKey('recap-history-list'));
    await tester.ensureVisible(historyList);
    await tester.pumpAndSettle();

    expect(tester.getSize(historyList).height, lessThanOrEqualTo(280));
    expect(find.text('应用 00'), findsOneWidget);

    final scrollable = find.descendant(
      of: historyList,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('应用 10'),
      120,
      scrollable: scrollable,
    );

    expect(find.text('应用 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history sorts, merges nearby fragments and preserves seconds', (
    tester,
  ) async {
    await _setView(tester, const Size(900, 700));
    final facts = [
      RecapActivityFact(
        date: _date,
        startedAt: '09:10:00',
        appName: 'Edge',
        durationSeconds: 12,
      ),
      RecapActivityFact(
        date: _date,
        startedAt: '09:01:00',
        appName: 'TimeTrace',
        durationSeconds: 20,
      ),
      RecapActivityFact(
        date: _date,
        startedAt: '09:00:00',
        appName: 'TimeTrace',
        durationSeconds: 30,
      ),
      RecapActivityFact(
        date: _date,
        startedAt: '09:03:00',
        appName: 'TimeTrace',
        durationSeconds: 8,
      ),
    ];
    await _pumpReport(
      tester,
      result: _result(snapshot: _snapshot(activityFacts: facts)),
    );

    expect(find.text('2 段'), findsOneWidget);
    expect(find.text('50s'), findsOneWidget);
    expect(find.text('12s'), findsOneWidget);
    expect(find.text('0m'), findsNothing);
    expect(find.text('TimeTrace'), findsNWidgets(2));

    final compacted = compactUsageHistory(facts);
    expect(compacted.map((item) => item.appName), [
      'TimeTrace',
      'TimeTrace',
      'Edge',
    ]);
    expect(compacted.first.sourceCount, 2);
    expect(compacted.first.activeSeconds, 50);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long AI and app names do not overflow a narrow window', (
    tester,
  ) async {
    await _setView(tester, const Size(320, 760));
    final snapshot = _snapshot(
      diaryEntries: const ['完成了界面整理'],
      activityFacts: [
        RecapActivityFact(
          date: _date,
          startedAt: '09:00:00',
          appName:
              'TFTTencentClient-Win64-Shipping-Extremely-Long-Application-Name',
          durationSeconds: 42,
        ),
      ],
    );
    await _pumpReport(
      tester,
      result: RecapResult(
        headline: '今天完成了一个名称很长、需要在窄窗口中自然换行的工作主题',
        summary: '根据日记和使用历史，主要时间用于界面整理与交互检查。',
        insights: const [],
        snapshot: snapshot,
        origin: RecapOrigin.ai,
        model: 'a-provider-model-with-an-extremely-long-version-name',
      ),
      aiEnabled: true,
      diaryIncludedInAi: true,
    );

    expect(find.text('已结合已发布日记'), findsOneWidget);
    expect(find.byType(Tooltip), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('month empty state does not falsely claim there was no use', (
    tester,
  ) async {
    await _setView(tester, const Size(800, 600));
    final month = _snapshot(
      start: DateTime(2026, 8, 1),
      activeSeconds: 7200,
      activityFacts: const [],
    );
    await _pumpReport(tester, result: _result(snapshot: month));

    expect(find.text('当前范围暂不提供逐条使用历史'), findsOneWidget);
    expect(find.text('当前范围暂无使用历史'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setView(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpReport(
  WidgetTester tester, {
  required RecapResult result,
  Widget? journal,
  bool aiEnabled = false,
  bool diaryIncludedInAi = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: TimetraceTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: RecapReportView(
          result: result,
          generatedAt: DateTime(2026, 8, 30, 12, 42),
          aiEnabled: aiEnabled,
          diaryIncludedInAi: diaryIncludedInAi,
          journal: journal,
        ),
      ),
    ),
  ),
);

RecapSnapshot _snapshot({
  DateTime? start,
  int activeSeconds = 7200,
  List<String> diaryEntries = const [],
  List<RecapActivityFact>? activityFacts,
}) => RecapSnapshot(
  label: '今天',
  start: start ?? _date,
  end: _date,
  activeSeconds: activeSeconds,
  idleSeconds: 300,
  previousActiveSeconds: 6000,
  topApps: const [
    RecapAppFact(
      name: 'TFTTencentClient-Win64-Shipping',
      activeSeconds: 5400,
      idleSeconds: 0,
    ),
  ],
  sessionCount: 36,
  contextSwitches: 28,
  longestActiveStreakSeconds: 2700,
  peakHour: 10,
  peakHourActiveSeconds: 1800,
  diaryEntries: diaryEntries,
  activityFacts:
      activityFacts ??
      [
        RecapActivityFact(
          date: _date,
          startedAt: '09:00:00',
          appName: 'TimeTrace',
          durationSeconds: 120,
        ),
      ],
);

RecapResult _result({required RecapSnapshot snapshot}) => RecapResult(
  headline: '今天完成了界面整理',
  summary: '从日记与使用历史看，今天主要处理了回顾页面的结构和交互。',
  insights: const [],
  snapshot: snapshot,
  origin: RecapOrigin.local,
);

final _date = DateTime(2026, 8, 30);
