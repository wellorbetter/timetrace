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

void main() {
  testWidgets('opening and navigating all report periods never generates', (
    tester,
  ) async {
    final port = _FakePort();
    await _pumpScreen(tester, port);

    expect(find.text('时间报告'), findsWidgets);
    expect(find.text('日报'), findsOneWidget);
    expect(find.text('周报'), findsWidgets);
    expect(find.text('月报'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('ai-recap-model-selector')), findsNothing);
    expect(find.text('2026年8月24日'), findsOneWidget);
    expect(port.generateCalls, 0);

    final next = tester.widget<IconButton>(
      find.byKey(const Key('ai-report-next-period')),
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.byKey(const Key('ai-report-previous-period')));
    await tester.pump();
    expect(find.text('2026年8月23日'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('ai-report-next-period')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('月报'));
    await tester.pump();
    expect(find.textContaining('2026年8月1日—2026年8月24日'), findsOneWidget);
    expect(port.generateCalls, 0);
  });

  testWidgets(
    'explicit click renders the four report sections and usage bars',
    (tester) async {
      final port = _FakePort(
        generated: _result(
          _daily(24),
          summary: '今日主要时间投入在编辑器与浏览器。',
          highlights: const ['上午的使用节奏更集中'],
          suggestions: const ['下周预留一次无打扰时段'],
        ),
      );
      await _pumpScreen(tester, port);

      await tester.tap(find.byKey(const Key('ai-recap-generate')));
      await tester.pumpAndSettle();

      expect(find.text('本期概览'), findsOneWidget);
      expect(find.text('主要投入'), findsOneWidget);
      expect(find.text('使用观察'), findsOneWidget);
      expect(find.text('下期建议'), findsOneWidget);
      expect(find.text('今日主要时间投入在编辑器与浏览器。'), findsOneWidget);
      expect(find.text('上午的使用节奏更集中'), findsOneWidget);
      expect(find.text('下周预留一次无打扰时段'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      expect(find.textContaining('不代表工作成果或绩效评价'), findsOneWidget);
      expect(find.textContaining('DeepSeek · Flash'), findsOneWidget);
      expect(find.textContaining('仅发送应用名称与聚合时长'), findsOneWidget);
      expect(port.generateCalls, 1);
      expect(port.lastKey, _daily(24));
    },
  );

  testWidgets('saved content stays readable while regeneration is pending', (
    tester,
  ) async {
    final pending = Completer<AiRecapResult>();
    final port = _FakePort(
      reports: [_result(_currentWeek, summary: '旧周报仍然可读。')],
      pending: pending,
    );
    await _pumpScreen(tester, port);
    await tester.tap(find.text('周报').first);
    await tester.pump();

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pump();

    expect(find.text('旧周报仍然可读。'), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-inline-progress')), findsOneWidget);
    expect(port.generateCalls, 1);

    await tester.tap(find.text('日报'));
    await tester.pump();
    expect(port.generateCalls, 1);

    pending.complete(_result(_currentWeek, summary: '更新后的周报。'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('周报').first);
    await tester.pump();
    expect(find.text('更新后的周报。'), findsOneWidget);
  });

  testWidgets('failure keeps the latest saved report of that type visible', (
    tester,
  ) async {
    final previousWeek = AiRecapRangeKey(
      scope: AiRecapScope.weekly,
      startDate: DateTime(2026, 8, 17),
      endDate: DateTime(2026, 8, 23),
    );
    final port = _FakePort(
      reports: [_result(previousWeek, summary: '上一份周报。')],
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    await _pumpScreen(tester, port);
    await tester.tap(find.text('周报').first);
    await tester.pump();

    expect(find.byKey(const Key('ai-report-saved-fallback')), findsNothing);
    expect(find.text('上一份周报。'), findsNothing);
    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-recap-error')), findsOneWidget);
    expect(find.byKey(const Key('ai-report-saved-fallback')), findsOneWidget);
    expect(find.text('上一份周报。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('missing key is an actionable local state with generation off', (
    tester,
  ) async {
    final port = _FakePort(
      statusValue: const AiRecapProviderStatus.unconfigured(),
    );
    await _pumpScreen(tester, port);

    expect(find.byKey(const Key('ai-recap-not-configured')), findsOneWidget);
    expect(find.textContaining('在设置中完成报告生成配置'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('ai-recap-generate')))
          .onPressed,
      isNull,
    );
    expect(port.generateCalls, 0);
  });

  testWidgets('local free provider generates without key and stays offline', (
    tester,
  ) async {
    final port = _FakePort(
      statusValue: const AiRecapProviderStatus(
        ready: true,
        selectedProvider: AiRecapProviderId.localSummary,
        selectedModel: AiRecapModel.localSummary,
        credentialSource: AiCredentialSource.notRequired,
      ),
    );
    await _pumpScreen(tester, port);

    expect(find.textContaining('本地总结（免费）'), findsOneWidget);
    expect(find.textContaining('不会发送任何使用数据'), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-not-configured')), findsNothing);
    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();
    expect(port.generateCalls, 1);
    expect(find.textContaining('本地总结（免费） · 本地总结 v1'), findsOneWidget);
  });

  testWidgets(
    'dashboard-linked report uses the latest exact key without duplicate controls',
    (tester) async {
      final port = _FakePort();
      var linkedKey = _currentWeek;
      var linkedLabel = '顶部范围：本周（截至今日）';
      late StateSetter updateHost;

      Widget linkedCard() => Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: 330,
            child: AiRecapCard(rangeKey: linkedKey, rangeLabel: linkedLabel),
          ),
        ),
      );

      await _pumpWidget(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return linkedCard();
          },
        ),
        port,
        surfaceSize: const Size(760, 500),
      );

      expect(find.text(linkedLabel), findsOneWidget);
      expect(find.textContaining('所选范围跟随顶部筛选'), findsOneWidget);
      expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
      expect(find.byKey(const Key('ai-report-previous-period')), findsNothing);
      expect(find.byKey(const Key('ai-report-next-period')), findsNothing);
      expect(find.text('日报'), findsNothing);
      expect(find.text('周报'), findsNothing);
      expect(find.text('月报'), findsNothing);
      expect(
        find.byKey(const Key('ai-recap-dashboard-section')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SingleChildScrollView>(
              find.byKey(const Key('ai-recap-linked-scroll')),
            )
            .primary,
        isFalse,
      );
      expect(find.byType(Scrollbar), findsOneWidget);

      await tester.tap(find.byKey(const Key('ai-recap-generate')));
      await tester.pumpAndSettle();
      expect(port.generateCalls, 1);
      expect(port.lastKey, _currentWeek);
      expect(find.text('新生成的周报。'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final linkedScrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('ai-recap-linked-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(linkedScrollable.position.maxScrollExtent, greaterThan(0));
      linkedScrollable.position.jumpTo(
        linkedScrollable.position.maxScrollExtent,
      );
      expect(linkedScrollable.position.pixels, greaterThan(0));

      updateHost(() {
        linkedKey = _daily(23);
        linkedLabel = '顶部范围：昨日';
      });
      await tester.pumpAndSettle();

      expect(find.text('顶部范围：昨日'), findsOneWidget);
      expect(linkedScrollable.position.pixels, 0);
      expect(find.text('新生成的周报。'), findsNothing);
      await tester.tap(find.byKey(const Key('ai-recap-generate')));
      await tester.pumpAndSettle();
      expect(port.generateCalls, 2);
      expect(port.lastKey, _daily(23));
    },
  );

  testWidgets('dashboard-linked invalid future range cannot generate', (
    tester,
  ) async {
    final port = _FakePort();
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final invalidKey = AiRecapRangeKey(
      scope: AiRecapScope.daily,
      startDate: tomorrow,
      endDate: tomorrow,
    );
    await _pumpWidget(
      tester,
      Scaffold(
        body: SizedBox(
          height: 330,
          child: AiRecapCard(rangeKey: invalidKey, rangeLabel: '未来日期'),
        ),
      ),
      port,
    );

    expect(find.text('未来日期'), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-invalid-range')), findsOneWidget);
    expect(find.textContaining('未来日期不能生成报告'), findsOneWidget);
    expect(find.text('请先在顶部选择今天或过去日期。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('ai-recap-generate')))
          .onPressed,
      isNull,
    );
    expect(port.generateCalls, 0);
  });

  testWidgets('report actions are keyboard reachable and section is semantic', (
    tester,
  ) async {
    final port = _FakePort();
    await _pumpScreen(tester, port);

    final generate = find.byKey(const Key('ai-recap-generate'));
    for (var attempt = 0; attempt < 14; attempt++) {
      if (_focusIsInside(tester, generate)) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(_focusIsInside(tester, generate), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(port.generateCalls, 1);

    await _pumpWidget(
      tester,
      SingleChildScrollView(child: AiRecapSection(now: _today)),
      port,
    );
    final semantics = tester.ensureSemantics();
    expect(find.text('时间报告'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('inline report section remains usable at 420 logical pixels', (
    tester,
  ) async {
    final port = _FakePort(generated: _result(_daily(24), summary: '窄窗口报告内容。'));
    await _pumpScreen(tester, port, surfaceSize: const Size(420, 620));

    expect(tester.takeException(), isNull);
    final generate = find.byKey(const Key('ai-recap-generate'));
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final boundary = find.textContaining('不代表工作成果或绩效评价');
    await tester.ensureVisible(boundary);
    await tester.pumpAndSettle();
    expect(boundary, findsOneWidget);
    expect(tester.takeException(), isNull);
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

final DateTime _today = DateTime(2026, 8, 24); // Monday.

final AiRecapRangeKey _currentWeek = AiRecapRangeKey(
  scope: AiRecapScope.weekly,
  startDate: DateTime(2026, 8, 24),
  endDate: DateTime(2026, 8, 24),
);

AiRecapRangeKey _daily(int day) => AiRecapRangeKey(
  scope: AiRecapScope.daily,
  startDate: DateTime(2026, 8, day),
  endDate: DateTime(2026, 8, day),
);

Future<void> _pumpScreen(
  WidgetTester tester,
  AiRecapPort port, {
  Size surfaceSize = const Size(1100, 820),
}) => _pumpWidget(
  tester,
  AiRecapScreen(now: _today),
  port,
  surfaceSize: surfaceSize,
);

Future<void> _pumpWidget(
  WidgetTester tester,
  Widget child,
  AiRecapPort port, {
  Size surfaceSize = const Size(1100, 820),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

AiRecapResult _result(
  AiRecapRangeKey key, {
  required String summary,
  AiRecapProviderId providerId = AiRecapProviderId.deepSeek,
  AiRecapModel model = AiRecapModel.flash,
  DateTime? generatedAt,
  List<String> highlights = const ['保持了稳定节奏'],
  List<String> suggestions = const ['安排一次专注复盘'],
}) => AiRecapResult(
  rangeKey: key,
  generatedAt: generatedAt ?? DateTime.utc(2026, 8, 24, 1, 30),
  providerId: providerId,
  model: model,
  summary: _statement(summary),
  highlights: highlights.map(_statement).toList(growable: false),
  suggestions: suggestions.map(_statement).toList(growable: false),
  totalActiveSeconds: 7200,
  applicationCount: 3,
  topApplications: const [
    AiRecapEvidence(appName: '编辑器', activeSeconds: 4200),
    AiRecapEvidence(appName: '浏览器', activeSeconds: 2100),
  ],
);

AiRecapStatement _statement(String text) => AiRecapStatement(
  text: text,
  evidence: const [AiRecapEvidence(appName: '编辑器', activeSeconds: 4200)],
);

class _FakePort implements AiRecapPort {
  _FakePort({
    List<AiRecapResult> reports = const [],
    this.statusValue = const AiRecapProviderStatus(configured: true),
    this.generated,
    this.pending,
    this.failure,
  }) : reports = List.unmodifiable(reports);

  final List<AiRecapResult> reports;
  final AiRecapProviderStatus statusValue;
  final AiRecapResult? generated;
  final Completer<AiRecapResult>? pending;
  final AiRecapFailure? failure;
  int generateCalls = 0;
  AiRecapRangeKey? lastKey;

  @override
  AiRecapProviderStatus status() => statusValue;

  @override
  List<AiRecapResult> latestReports() => reports;

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) async {
    generateCalls++;
    lastKey = key;
    if (failure case final value?) throw value;
    if (pending case final value?) return value.future;
    return generated ??
        _result(
          key,
          summary: '新生成的${key.scope.label}。',
          providerId: statusValue.selectedProvider,
          model: statusValue.selectedModel,
        );
  }
}
