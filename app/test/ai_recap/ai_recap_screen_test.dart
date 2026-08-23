import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_card.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_screen.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  testWidgets(
    'opening detail and switching model produce zero generation calls',
    (tester) async {
      final port = _FakeAiRecapPort();
      await _pumpScreen(tester, port);

      expect(find.text('AI 使用回顾'), findsWidgets);
      expect(find.text('今日'), findsOneWidget);
      expect(find.text('本周'), findsOneWidget);
      expect(port.generateCalls, 0);

      await tester.tap(find.text('本周'));
      await tester.pump();
      expect(port.generateCalls, 0);

      await tester.tap(find.text('Pro'));
      await tester.pump();
      expect(port.generateCalls, 0);
    },
  );

  testWidgets('explicit click renders summary, highlights and suggestions', (
    tester,
  ) async {
    final port = _FakeAiRecapPort(
      generated: _result(
        _todayKey,
        summary: '今天的专注时间主要集中在编辑器。',
        highlights: const ['完成了两个连续专注时段'],
        suggestions: const ['下午预留一次短休息'],
      ),
    );
    await _pumpScreen(tester, port);

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();

    expect(find.text('今天的专注时间主要集中在编辑器。'), findsOneWidget);
    expect(find.text('完成了两个连续专注时段'), findsOneWidget);
    expect(find.text('下午预留一次短休息'), findsOneWidget);
    expect(find.textContaining('今日 · 2026年8月24日'), findsOneWidget);
    expect(find.textContaining('仅发送最多 12 个应用名称'), findsOneWidget);
    expect(port.generateCalls, 1);
    expect(port.lastKey, _todayKey);
  });

  testWidgets('old result remains readable while regeneration is pending', (
    tester,
  ) async {
    final pending = Completer<AiRecapResult>();
    final port = _FakeAiRecapPort(
      latestResult: _result(_todayKey, summary: '旧回顾仍然可读。'),
      pending: pending,
    );
    await _pumpScreen(tester, port);

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pump();

    expect(find.text('旧回顾仍然可读。'), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-inline-progress')), findsOneWidget);

    pending.complete(_result(_todayKey, summary: '更新后的回顾。'));
    await tester.pumpAndSettle();
    expect(find.text('更新后的回顾。'), findsOneWidget);
  });

  testWidgets('typed failure preserves old content and offers retry', (
    tester,
  ) async {
    final port = _FakeAiRecapPort(
      latestResult: _result(_todayKey, summary: '超时前的回顾。'),
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    await _pumpScreen(tester, port);

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-recap-error')), findsOneWidget);
    expect(find.text('超时前的回顾。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('missing key and unsupported range are stable local states', (
    tester,
  ) async {
    final unconfigured = _FakeAiRecapPort(configured: false);
    await _pumpScreen(tester, unconfigured);
    expect(find.byKey(const Key('ai-recap-not-configured')), findsOneWidget);
    expect(find.textContaining('DEEPSEEK_API_KEY'), findsOneWidget);
    expect(unconfigured.generateCalls, 0);

    await _pumpScreen(
      tester,
      _FakeAiRecapPort(),
      bounds: const DateRangeBounds(
        start: '2026-08-01',
        end: '2026-08-24',
        label: '本月',
        supportedByAiRecap: false,
      ),
    );
    expect(find.byKey(const Key('ai-recap-unsupported-range')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('ai-recap-generate')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('dashboard card projects local result without generating', (
    tester,
  ) async {
    final port = _FakeAiRecapPort(
      latestResult: _result(_todayKey, summary: '两行以内的仪表盘摘要。'),
    );
    await _pumpWidget(
      tester,
      Scaffold(
        body: ListView(padding: EdgeInsets.all(12), children: [AiRecapCard()]),
      ),
      port,
    );
    await tester.pump();

    expect(find.byKey(const Key('ai-recap-dashboard-card')), findsOneWidget);
    expect(find.text('两行以内的仪表盘摘要。'), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-card-metadata')), findsOneWidget);
    expect(find.textContaining('Flash · 生成于'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('ai-recap-dashboard-card'))).height,
      inInclusiveRange(112, 152),
    );
    expect(port.generateCalls, 0);
  });

  testWidgets('evidence durations keep exact seconds instead of truncating', (
    tester,
  ) async {
    final port = _FakeAiRecapPort(
      latestResult: _result(
        _todayKey,
        summary: '短时活动。',
        summaryEvidence: const [
          AiRecapEvidence(appName: '终端', activeSeconds: 30),
          AiRecapEvidence(appName: '编辑器', activeSeconds: 90),
          AiRecapEvidence(appName: '浏览器', activeSeconds: 3599),
          AiRecapEvidence(appName: 'IDE', activeSeconds: 3661),
        ],
      ),
    );
    await _pumpScreen(tester, port);

    expect(find.textContaining('终端 30 秒'), findsOneWidget);
    expect(find.textContaining('编辑器 1 分钟 30 秒'), findsOneWidget);
    expect(find.textContaining('浏览器 59 分钟 59 秒'), findsOneWidget);
    expect(find.textContaining('IDE 1 小时 1 分钟 1 秒'), findsOneWidget);
  });

  testWidgets('generate action is keyboard reachable and card is semantic', (
    tester,
  ) async {
    final port = _FakeAiRecapPort();
    await _pumpScreen(tester, port);

    final generate = find.byKey(const Key('ai-recap-generate'));
    for (var attempt = 0; attempt < 12; attempt++) {
      if (_focusIsInside(tester, generate)) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(_focusIsInside(tester, generate), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(port.generateCalls, 1);

    await _pumpWidget(tester, const AiRecapCard(), port);
    expect(find.bySemanticsLabel(RegExp('AI 使用回顾，今日')), findsOneWidget);
  });

  testWidgets('detail remains usable in a narrow desktop window', (
    tester,
  ) async {
    final port = _FakeAiRecapPort();
    await _pumpWidget(
      tester,
      const AiRecapScreen(),
      port,
      surfaceSize: const Size(420, 560),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('ai-recap-range-selector')), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-model-selector')), findsOneWidget);

    final generate = find.byKey(const Key('ai-recap-generate'));
    await tester.ensureVisible(generate);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(port.generateCalls, 1);
    expect(find.byKey(const Key('ai-recap-result')), findsOneWidget);
  });
}

bool _focusIsInside(WidgetTester tester, Finder target) {
  final focused = tester.binding.focusManager.primaryFocus?.context;
  if (focused == null) return false;
  final targetElement = tester.element(target);
  if (identical(focused, targetElement)) return true;
  var found = false;
  focused.visitAncestorElements((ancestor) {
    found = identical(ancestor, targetElement);
    return !found;
  });
  return found;
}

final AiRecapRangeKey _todayKey = AiRecapRangeKey(
  scope: AiRecapScope.today,
  startDate: DateTime(2026, 8, 24),
  endDate: DateTime(2026, 8, 24),
);

const DateRangeBounds _todayBounds = DateRangeBounds(
  start: '2026-08-24',
  end: '2026-08-24',
  label: '今日',
  supportedByAiRecap: true,
);

Future<void> _pumpScreen(
  WidgetTester tester,
  AiRecapPort port, {
  DateRangeBounds bounds = _todayBounds,
}) => _pumpWidget(tester, const AiRecapScreen(), port, bounds: bounds);

Future<void> _pumpWidget(
  WidgetTester tester,
  Widget child,
  AiRecapPort port, {
  DateRangeBounds bounds = _todayBounds,
  Size surfaceSize = const Size(1100, 820),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiRecapPortProvider.overrideWithValue(port),
        dashboardRangeBoundsProvider.overrideWithValue(bounds),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

AiRecapResult _result(
  AiRecapRangeKey key, {
  required String summary,
  List<AiRecapEvidence>? summaryEvidence,
  List<String> highlights = const ['保持了稳定节奏'],
  List<String> suggestions = const ['安排一次专注复盘'],
}) => AiRecapResult(
  rangeKey: key,
  generatedAt: DateTime.utc(2026, 8, 24, 1, 30),
  model: AiRecapModel.flash,
  summary: AiRecapStatement(
    text: summary,
    evidence:
        summaryEvidence ??
        const [AiRecapEvidence(appName: 'Editor', activeSeconds: 3600)],
  ),
  highlights: highlights.map(_statement).toList(growable: false),
  suggestions: suggestions.map(_statement).toList(growable: false),
  totalActiveSeconds: 7200,
  applicationCount: 3,
);

AiRecapStatement _statement(String text) => AiRecapStatement(
  text: text,
  evidence: const [AiRecapEvidence(appName: 'Editor', activeSeconds: 3600)],
);

class _FakeAiRecapPort implements AiRecapPort {
  _FakeAiRecapPort({
    this.configured = true,
    this.latestResult,
    this.generated,
    this.pending,
    this.failure,
  });

  final bool configured;
  final AiRecapResult? latestResult;
  final AiRecapResult? generated;
  final Completer<AiRecapResult>? pending;
  final AiRecapFailure? failure;
  int generateCalls = 0;
  AiRecapRangeKey? lastKey;

  @override
  AiRecapProviderStatus status() =>
      AiRecapProviderStatus(configured: configured);

  @override
  AiRecapResult? latest(AiRecapRangeKey key) => latestResult;

  @override
  Future<AiRecapResult> generate(
    AiRecapRangeKey key,
    AiRecapModel model,
  ) async {
    generateCalls++;
    lastKey = key;
    if (failure case final value?) throw value;
    if (pending case final value?) return value.future;
    return generated ?? _result(key, summary: '新生成的回顾。');
  }
}
