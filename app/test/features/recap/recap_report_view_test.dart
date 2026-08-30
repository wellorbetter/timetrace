import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';

void main() {
  testWidgets('local recap stays readable and snapshot expands on desktop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpReport(tester);

    expect(find.text('本地回顾'), findsOneWidget);
    expect(find.text('关键事实'), findsOneWidget);
    expect(find.text('时间分配'), findsOneWidget);
    expect(find.text('AI 增强'), findsNothing);

    final disclosure = find.byKey(
      const ValueKey('recap-snapshot-disclosure'),
    );
    await tester.ensureVisible(disclosure);
    await tester.tap(disclosure);
    await tester.pumpAndSettle();

    expect(find.textContaining('"active_seconds": 7200'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('report reflows without overflow in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpReport(tester);

    expect(find.byKey(const ValueKey('recap-summary-surface')), findsOneWidget);
    expect(find.text('活跃时长'), findsOneWidget);
    expect(find.text('最常用'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
  diaryEntries: [],
);

final _result = RecapResult(
  headline: '今天主要时间集中在一个应用',
  summary: '活跃 2 小时，最长连续活跃 45 分钟。',
  insights: [
    '最常用应用活跃 1 小时 30 分。',
    '记录到 36 个活跃片段。',
    '应用切换 28 次。',
  ],
  snapshot: _snapshot,
  origin: RecapOrigin.local,
);
