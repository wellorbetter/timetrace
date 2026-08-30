import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_section.dart';

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

  testWidgets('saving an edited entry reports one content change', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi(entries: [_publishedEntry]);
    var changes = 0;
    await _pumpDiary(tester, api: api, onContentChanged: () => changes++);

    await tester.tap(find.text('编辑'));
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

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除日记'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, 1);
    expect(changes, 1);
    expect(api.entries, isEmpty);
  });
}

const _publishedEntry = DiaryEntryDto(
  id: 7,
  date: '2026-08-30',
  content: '原日记',
  status: 'published',
);

Future<void> _pumpDiary(
  WidgetTester tester, {
  required _FakeTimeTraceApi api,
  required VoidCallback onContentChanged,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: TimetraceTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiarySection(
              date: DateTime(2026, 8, 30),
              onContentChanged: onContentChanged,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeTimeTraceApi implements TimeTraceApi {
  _FakeTimeTraceApi({List<DiaryEntryDto> entries = const []})
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
      DiaryEntryDto(id: id, date: date, content: content, status: 'published'),
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
