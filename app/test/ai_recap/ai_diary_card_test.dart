import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_card.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

void main() {
  testWidgets('renders a compact linked weekly recap with a 16:10 cover', (
    tester,
  ) async {
    final report = _result(_week, summary: '本周主要在编辑器中保持了稳定的专注节奏。');
    await _pumpCard(tester, port: _FakePort(reports: [report]));

    expect(find.text('智能周记'), findsOneWidget);
    expect(find.textContaining('本周 · 2026年8月24日—2026年8月26日'), findsOneWidget);
    expect(find.text('AI 生成 · DeepSeek'), findsOneWidget);
    expect(find.text(report.summary.text), findsOneWidget);
    expect(find.text('2 小时 15 分钟'), findsOneWidget);
    expect(find.text('4 个应用'), findsOneWidget);
    expect(find.text('编辑器'), findsOneWidget);
    expect(find.text('浏览器'), findsOneWidget);
    expect(find.text('终端'), findsOneWidget);
    expect(find.text('音乐'), findsNothing);
    expect(find.byKey(const Key('ai-diary-top-applications')), findsOneWidget);

    final coverSize = tester.getSize(find.byKey(const Key('ai-diary-cover')));
    expect(coverSize.width / coverSize.height, closeTo(1.6, 0.01));
    expect(
      find.descendant(
        of: find.byKey(const Key('ai-recap-dashboard-section')),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the saved recap visible during update and after failure', (
    tester,
  ) async {
    final pending = Completer<AiRecapResult>();
    final saved = _result(_week, summary: '已保存的周记继续可读。');
    final port = _FakePort(reports: [saved], pending: pending);
    await _pumpCard(tester, port: port);

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pump();

    expect(find.text(saved.summary.text), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-inline-progress')), findsOneWidget);
    expect(find.text('正在更新，当前内容继续保留。'), findsOneWidget);

    pending.complete(_result(_week, summary: '更新后的智能周记。'));
    await tester.pumpAndSettle();
    expect(find.text('更新后的智能周记。'), findsOneWidget);
    expect(find.text(saved.summary.text), findsNothing);

    final failedPort = _FakePort(
      reports: [saved],
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    await _pumpCard(tester, port: failedPort);
    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-recap-error')), findsOneWidget);
    expect(find.text('生成超时，已有内容仍然保留。'), findsOneWidget);
    expect(find.text(saved.summary.text), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state generates only after the explicit action', (
    tester,
  ) async {
    final port = _FakePort();
    await _pumpCard(tester, port: port);

    expect(find.byKey(const Key('ai-diary-empty')), findsOneWidget);
    expect(find.textContaining('还没有本期回顾'), findsOneWidget);
    expect(port.generateCalls, 0);

    await tester.tap(find.byKey(const Key('ai-recap-generate')));
    await tester.pumpAndSettle();
    expect(port.generateCalls, 1);
    expect(port.lastKey, _week);
    expect(find.text('刚刚生成的智能周记。'), findsOneWidget);
  });

  testWidgets('cycles built-in covers and supports the no-cover layout', (
    tester,
  ) async {
    final storage = _MemoryPreferencesStorage({
      AiDiaryPreferences.enabledKey: true,
      AiDiaryPreferences.coverSourceKey: 'built_in',
      AiDiaryPreferences.builtInCoverIdKey: 'night_focus',
    });
    await _pumpCard(tester, port: _FakePort(), storage: storage);

    await tester.tap(find.byKey(const Key('ai-diary-change-cover')));
    await tester.pump();
    expect(
      storage.values[AiDiaryPreferences.builtInCoverIdKey],
      'warm_afternoon',
    );

    final noCoverStorage = _MemoryPreferencesStorage({
      AiDiaryPreferences.enabledKey: true,
      AiDiaryPreferences.coverSourceKey: 'none',
    });
    await _pumpCard(
      tester,
      port: _FakePort(),
      storage: noCoverStorage,
      surfaceSize: const Size(420, 700),
    );
    expect(find.byKey(const Key('ai-diary-cover')), findsNothing);
    expect(find.text('智能周记'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required AiRecapPort port,
  _MemoryPreferencesStorage? storage,
  Size surfaceSize = const Size(1100, 720),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences =
      storage ??
      _MemoryPreferencesStorage({
        AiDiaryPreferences.enabledKey: true,
        AiDiaryPreferences.coverSourceKey: 'built_in',
      });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiRecapPortProvider.overrideWithValue(port),
        aiDiaryPreferencesStorageProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AiRecapCard(rangeKey: _week, rangeLabel: '本周'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final AiRecapRangeKey _week = AiRecapRangeKey(
  scope: AiRecapScope.weekly,
  startDate: DateTime(2026, 8, 24),
  endDate: DateTime(2026, 8, 26),
);

AiRecapResult _result(AiRecapRangeKey key, {required String summary}) {
  return AiRecapResult(
    rangeKey: key,
    generatedAt: DateTime.utc(2026, 8, 26, 12),
    providerId: AiRecapProviderId.deepSeek,
    model: AiRecapModel.flash,
    summary: AiRecapStatement(text: summary, evidence: const []),
    highlights: const [],
    suggestions: const [],
    totalActiveSeconds: 8100,
    applicationCount: 4,
    topApplications: const [
      AiRecapEvidence(appName: '编辑器', activeSeconds: 3600),
      AiRecapEvidence(appName: '浏览器', activeSeconds: 2400),
      AiRecapEvidence(appName: '终端', activeSeconds: 1500),
      AiRecapEvidence(appName: '音乐', activeSeconds: 600),
    ],
  );
}

class _FakePort implements AiRecapPort {
  _FakePort({
    List<AiRecapResult> reports = const [],
    this.pending,
    this.failure,
  }) : reports = List.unmodifiable(reports);

  final List<AiRecapResult> reports;
  final Completer<AiRecapResult>? pending;
  final AiRecapFailure? failure;
  int generateCalls = 0;
  AiRecapRangeKey? lastKey;

  @override
  AiRecapProviderStatus status() => const AiRecapProviderStatus(
    ready: true,
    selectedProvider: AiRecapProviderId.deepSeek,
    selectedModel: AiRecapModel.flash,
  );

  @override
  List<AiRecapResult> latestReports() => reports;

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) async {
    generateCalls++;
    lastKey = key;
    if (failure case final value?) throw value;
    if (pending case final value?) return value.future;
    return _result(key, summary: '刚刚生成的智能周记。');
  }
}

class _MemoryPreferencesStorage implements AiDiaryPreferencesStorage {
  _MemoryPreferencesStorage(Map<String, dynamic> initial)
    : values = Map<String, dynamic>.from(initial);

  final Map<String, dynamic> values;

  @override
  Map<String, dynamic> read() => Map<String, dynamic>.from(values);

  @override
  void update(Map<String, dynamic> values) {
    this.values.addAll(values);
  }
}
