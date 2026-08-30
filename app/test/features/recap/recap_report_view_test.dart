import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';

void main() {
  testWidgets(
    'recap keeps narrative and history without dashboard duplication',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpReport(tester);

      expect(find.text('本地总结'), findsOneWidget);
      expect(find.text('使用历史'), findsOneWidget);
      expect(find.textContaining('本地总结已参考 1 篇日记'), findsOneWidget);
      expect(find.text('事实依据'), findsNothing);
      expect(find.text('时间分配'), findsNothing);
      expect(find.text('活动时间线'), findsNothing);
      expect(find.text('事实快照'), findsNothing);
      expect(find.text('活跃时长'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('report reflows without overflow in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpReport(tester);

    expect(find.byKey(const ValueKey('recap-summary-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-usage-history')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage history stays bounded and scrolls internally', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpReport(tester);

    final history = find.byKey(const ValueKey('recap-usage-history-list'));
    await tester.ensureVisible(history);
    await tester.pumpAndSettle();

    expect(tester.getSize(history).height, lessThanOrEqualTo(360));
    expect(find.text('应用 00'), findsOneWidget);

    final scrollable = find.descendant(
      of: history,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('应用 10'),
      140,
      scrollable: scrollable,
    );

    expect(find.text('应用 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI diary opt-in remains explicit', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecapReportView(
              result: RecapResult(
                headline: _result.headline,
                summary: _result.summary,
                insights: const [],
                snapshot: _snapshot,
                origin: RecapOrigin.ai,
                model: 'deepseek-v4-flash',
              ),
              generatedAt: DateTime(2026, 8, 30, 12, 42),
              aiEnabled: true,
              onOpenSettings: () => opened = true,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('当前未发送给 AI'), findsOneWidget);
    await tester.tap(find.text('允许结合'));
    expect(opened, isTrue);
  });

  test('adjacent history fragments from the same app are merged', () {
    final segments = compactUsageHistory([
      RecapActivityFact(
        date: DateTime(2026, 8, 30),
        startedAt: '2026-08-30T10:00:00Z',
        appName: 'Edge',
        durationSeconds: 20,
      ),
      RecapActivityFact(
        date: DateTime(2026, 8, 30),
        startedAt: '2026-08-30T10:00:30Z',
        appName: 'Edge',
        durationSeconds: 40,
      ),
    ]);

    expect(segments, hasLength(1));
    expect(segments.single.sourceCount, 2);
    expect(segments.single.activeSeconds, 60);
  });
}

Future<void> _pumpReport(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: TimetraceTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: RecapReportView(
          result: _result,
          generatedAt: DateTime(2026, 8, 30, 12, 42),
          aiEnabled: false,
        ),
      ),
    ),
  ),
);

final _snapshot = RecapSnapshot(
  label: '今天',
  start: DateTime(2026, 8, 30),
  end: DateTime(2026, 8, 30),
  activeSeconds: 7200,
  idleSeconds: 300,
  previousActiveSeconds: 6000,
  topApps: [
    RecapAppFact(
      name: 'TFTTencentClient-Win64-Shipping',
      activeSeconds: 5400,
      idleSeconds: 0,
    ),
    RecapAppFact(name: 'Edge', activeSeconds: 1800, idleSeconds: 0),
  ],
  sessionCount: 36,
  contextSwitches: 28,
  longestActiveStreakSeconds: 2700,
  peakHour: 10,
  peakHourActiveSeconds: 1800,
  diaryEntries: ['整理了 TimeTrace 的回顾页面。'],
  activityFacts: List.generate(
    12,
    (index) => RecapActivityFact(
      date: DateTime(2026, 8, 30),
      startedAt: '2026-08-30T${index.toString().padLeft(2, '0')}:00:00Z',
      appName: '应用 ${index.toString().padLeft(2, '0')}',
      durationSeconds: index == 0 ? 12 : 900,
    ),
  ),
);

final _result = RecapResult(
  headline: '今天主要整理了 TimeTrace',
  summary: '主要使用了 TimeTrace 和 Edge，并在日记里记录了回顾页面的调整。',
  insights: const [],
  snapshot: _snapshot,
  origin: RecapOrigin.local,
);
