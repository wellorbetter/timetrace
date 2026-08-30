import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_section.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

void main() {
  testWidgets('publishing notifies once and clears the editor', (tester) async {
    final api = _FakeTimeTraceApi();
    var changes = 0;
    await _pumpDiary(tester, api: api, onContentChanged: () => changes++);

    final editor = find.byType(TextField).first;
    await tester.enterText(editor, '完成了 Recap 页面');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pumpAndSettle();

    expect(api.publishCalls, 1);
    expect(changes, 1);
    expect(tester.widget<TextField>(editor).controller?.text, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发布'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pump();
    expect(api.publishCalls, 1);
    expect(changes, 1);
  });

  testWidgets('draft autosave does not report a published content change', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    var changes = 0;
    await _pumpDiary(tester, api: api, onContentChanged: () => changes++);

    await tester.enterText(find.byType(TextField).first, '仍然是草稿');
    await tester.pump(const Duration(milliseconds: 901));
    await tester.pump();

    expect(api.draftSaveCalls, 1);
    expect(changes, 0);
  });

  testWidgets('keeps the main diary editor, grouped post card and visibility', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi(entries: [_publishedEntry]);
    await _pumpDiary(tester, api: api, onContentChanged: () {});

    final editorSurface = tester.widget<Container>(
      find.byKey(const ValueKey('diary-editor-surface')),
    );
    final editorDecoration = editorSurface.decoration! as BoxDecoration;
    expect(editorDecoration.color?.a, 1);
    expect(find.byKey(const ValueKey('diary-post-7')), findsOneWidget);
    final postCard = tester.widget<Card>(
      find.byKey(const ValueKey('diary-post-7')),
    );
    expect(postCard.color?.a, 1);
    expect(find.byTooltip('隐藏文字'), findsOneWidget);

    await tester.tap(find.byTooltip('隐藏文字'));
    await tester.pumpAndSettle();
    expect(find.text('内容已隐藏 · 原日记'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('diary-day-toggle-2026-08-30')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('diary-post-7')), findsNothing);
  });

  testWidgets(
    'shows the original autosaved draft badge inside editor surface',
    (tester) async {
      final api = _FakeTimeTraceApi(draft: '未发布的内容');
      await _pumpDiary(tester, api: api, onContentChanged: () {});

      expect(find.byKey(const ValueKey('diary-draft-badge')), findsOneWidget);
      expect(find.text('草稿'), findsOneWidget);
      expect(find.text('已自动保存，发布后才会出现在日记列表'), findsOneWidget);
      expect(find.text('放弃草稿'), findsOneWidget);
    },
  );

  testWidgets('saving an edited entry reports one content change', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi(entries: [_publishedEntry]);
    var changes = 0;
    await _pumpDiary(tester, api: api, onContentChanged: () => changes++);

    await tester.tap(find.byKey(const ValueKey('diary-edit-7')));
    await tester.pumpAndSettle();
    final entryEditor = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '写点什么…',
    );
    await tester.enterText(entryEditor, '更新后的日记');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(api.updateCalls, 1);
    expect(changes, 1);
    expect(api.entries.single.content, '更新后的日记');
  });

  testWidgets('deleting an entry reports one content change', (tester) async {
    final api = _FakeTimeTraceApi(entries: [_publishedEntry]);
    var changes = 0;
    await _pumpDiary(tester, api: api, onContentChanged: () => changes++);

    await tester.tap(find.byKey(const ValueKey('diary-edit-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('diary-delete-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
    expect(changes, 1);
    expect(api.entries, isEmpty);
  });

  testWidgets('shows the AI diary action only for a configured day view', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    const configured = RecapAiSettings(
      enabled: true,
      endpoint: 'https://example.com/chat',
      model: 'test-model',
    );

    await _pumpDiary(
      tester,
      api: api,
      onContentChanged: () {},
      aiSettings: configured,
    );
    expect(find.text('AI 写今日日记'), findsOneWidget);

    await _pumpDiary(
      tester,
      api: api,
      onContentChanged: () {},
      aiSettings: configured,
      range: DiaryRange.week,
    );
    expect(find.text('AI 写今日日记'), findsNothing);
  });

  testWidgets('duplicate confirmation happens before the second generation', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi(entries: [_aiGeneratedEntry]);
    var changes = 0;
    final generator = _FakeAiDiaryGenerationNotifier([
      (_) async => const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.duplicate,
        message: '这一天已有 AI 日记。',
      ),
      (_) async => const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.success,
        entryId: 8,
        content: '新的 AI 日记',
        model: 'test-model',
      ),
    ]);

    await _pumpDiary(
      tester,
      api: api,
      onContentChanged: () => changes++,
      aiSettings: _configuredAiSettings,
      generator: generator,
    );

    await tester.tap(find.text('AI 写今日日记'));
    await tester.pumpAndSettle();

    expect(generator.allowDuplicateCalls, [false]);
    expect(find.text('这一天已有 AI 日记'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '继续生成'));
    await tester.pumpAndSettle();

    expect(generator.allowDuplicateCalls, [false, true]);
    expect(changes, 1);
  });

  testWidgets('retryable failure stays inline and can be retried', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    final generator = _FakeAiDiaryGenerationNotifier([
      (_) async => const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.failed,
        message: '模型暂时不可用。',
      ),
      (_) async => const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.success,
        entryId: 8,
        content: '生成成功',
        model: 'test-model',
      ),
    ]);

    await _pumpDiary(
      tester,
      api: api,
      onContentChanged: () {},
      aiSettings: _configuredAiSettings,
      generator: generator,
    );

    await tester.tap(find.text('AI 写今日日记'));
    await tester.pumpAndSettle();
    expect(find.text('模型暂时不可用。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(generator.allowDuplicateCalls, [false, false]);
    expect(find.text('模型暂时不可用。'), findsNothing);
  });

  testWidgets('late AI response cannot leak onto a newly selected date', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    final response = Completer<AiDiaryGenerationOutcome>();
    final generator = _FakeAiDiaryGenerationNotifier([(_) => response.future]);
    final selectedDate = ValueNotifier(DateTime(2026, 8, 30));
    addTearDown(selectedDate.dispose);

    await _pumpDiary(
      tester,
      api: api,
      onContentChanged: () {},
      aiSettings: _configuredAiSettings,
      generator: generator,
      selectedDate: selectedDate,
    );

    await tester.tap(find.text('AI 写今日日记'));
    await tester.pump();
    expect(find.text('正在根据当天使用记录整理日记…'), findsOneWidget);

    selectedDate.value = DateTime(2026, 8, 29);
    await tester.pump();
    expect(find.text('正在根据当天使用记录整理日记…'), findsNothing);

    response.complete(
      const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.failed,
        message: '旧日期错误',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧日期错误'), findsNothing);
  });

  testWidgets('AI provenance changes to assisted after editing', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi(entries: [_aiGeneratedEntry]);
    await _pumpDiary(tester, api: api, onContentChanged: () {});

    expect(find.text('AI 生成 · test-model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diary-edit-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('AI 辅助 · test-model'), findsOneWidget);
    expect(find.text('AI 生成 · test-model'), findsNothing);
  });
}

const _publishedEntry = DiaryEntryDto(
  id: 7,
  date: '2026-08-30',
  content: '原日记',
  status: 'published',
  source: 'manual',
);

const _aiGeneratedEntry = DiaryEntryDto(
  id: 7,
  date: '2026-08-30',
  content: '由 AI 整理的日记',
  status: 'published',
  source: 'ai_generated',
  sourceModel: 'test-model',
);

const _configuredAiSettings = RecapAiSettings(
  enabled: true,
  endpoint: 'https://example.com/chat',
  model: 'test-model',
);

Future<void> _pumpDiary(
  WidgetTester tester, {
  required _FakeTimeTraceApi api,
  required VoidCallback onContentChanged,
  RecapAiSettings aiSettings = const RecapAiSettings(),
  AiDiaryGenerationNotifier? generator,
  DiaryRange range = DiaryRange.day,
  ValueNotifier<DateTime>? selectedDate,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        recapAiSettingsProvider.overrideWithBuild((_, _) async => aiSettings),
        if (generator != null)
          aiDiaryGenerationProvider.overrideWith(() => generator),
      ],
      child: MaterialApp(
        theme: TimetraceTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: selectedDate == null
                ? DiarySection(
                    date: DateTime(2026, 8, 30),
                    range: range,
                    onContentChanged: onContentChanged,
                  )
                : ValueListenableBuilder<DateTime>(
                    valueListenable: selectedDate,
                    builder: (context, date, _) => DiarySection(
                      date: date,
                      range: range,
                      onContentChanged: onContentChanged,
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeTimeTraceApi implements TimeTraceApi {
  _FakeTimeTraceApi({List<DiaryEntryDto> entries = const [], this.draft})
    : entries = List.of(entries);

  final List<DiaryEntryDto> entries;
  String? draft;
  int publishCalls = 0;
  int draftSaveCalls = 0;
  int updateCalls = 0;
  int deleteCalls = 0;
  int _nextId = 100;

  @override
  int publishDiary({required String date, required String content}) {
    publishCalls++;
    draft = null;
    final id = _nextId++;
    entries.insert(
      0,
      DiaryEntryDto(
        id: id,
        date: date,
        content: content,
        status: 'published',
        source: 'manual',
      ),
    );
    return id;
  }

  @override
  int saveDiaryDraft({required String date, required String content}) {
    draftSaveCalls++;
    draft = content;
    return 1;
  }

  @override
  String? getDiaryDraft({required String date}) => draft;

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) => List.of(entries);

  @override
  List<(String, String)> getDiaryEntries({
    required String start,
    required String end,
  }) => [for (final entry in entries) (entry.date, entry.content)];

  @override
  List<(String, int?, String)> getDiaryImagesDetailed({
    required String start,
    required String end,
  }) => const [];

  @override
  String exportCsv({required String start, required String end}) => '';

  @override
  void updateDiaryEntry({required int id, required String content}) {
    updateCalls++;
    final index = entries.indexWhere((entry) => entry.id == id);
    final current = entries[index];
    entries[index] = DiaryEntryDto(
      id: current.id,
      date: current.date,
      content: content,
      status: current.status,
      source: current.source == 'ai_generated' ? 'ai_assisted' : current.source,
      sourceModel: current.sourceModel,
    );
  }

  @override
  List<String> getDiaryImagesForEntry({required int entryId}) => const [];

  @override
  void deleteDiaryEntry({required int id}) {
    deleteCalls++;
    entries.removeWhere((entry) => entry.id == id);
  }

  @override
  void setDiaryImageEntry({required String path, required int entryId}) {}

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _GenerationStep =
    Future<AiDiaryGenerationOutcome> Function(bool allowDuplicate);

class _FakeAiDiaryGenerationNotifier extends AiDiaryGenerationNotifier {
  _FakeAiDiaryGenerationNotifier(this.steps);

  final List<_GenerationStep> steps;
  final List<bool> allowDuplicateCalls = [];

  @override
  Future<AiDiaryGenerationOutcome?> build() async => null;

  @override
  Future<AiDiaryGenerationOutcome> generateForDate(
    DateTime date, {
    bool allowDuplicate = false,
  }) async {
    final index = allowDuplicateCalls.length;
    allowDuplicateCalls.add(allowDuplicate);
    state = const AsyncLoading();
    final outcome = await steps[index](allowDuplicate);
    state = AsyncData(outcome);
    return outcome;
  }
}
