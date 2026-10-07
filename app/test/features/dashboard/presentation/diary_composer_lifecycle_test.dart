import 'dart:async';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'dart:ui' show SemanticsAction, SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:timetrace_app/src/core/widgets/image_album.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/domain/diary_entry_metadata.dart';
import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import '../diary_entry_metadata_test.dart'
    show MemoryDiaryMetadataStore, MemoryMetadataCandidates;

const _a = '2026-10-01';
const _b = '2026-10-02';

class _FakeApi implements TimeTraceApi {
  final drafts = <String, String>{};
  final writes = <(String, String)>[];
  final published = <(String, String)>[];
  final addedImages = <(String, String)>[];
  final linked = <(String, int)>[];
  final updates = <(int, String)>[];
  final removedImages = <String>[];
  bool failSave = false;
  bool failRemoveImage = false;
  String? failImage;
  int nextId = 100;

  @override
  String? getDiaryDraft({required String date}) => drafts[date];

  @override
  int saveDiaryDraft({required String date, required String content}) {
    if (failSave) throw StateError('synthetic save failure');
    writes.add((date, content));
    drafts[date] = content;
    return 9;
  }

  @override
  int publishDiary({required String date, required String content}) {
    published.add((date, content));
    drafts.remove(date);
    return nextId++;
  }

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) => [
    for (final entry in drafts.entries)
      if (entry.key.compareTo(start) >= 0 && entry.key.compareTo(end) <= 0)
        DiaryEntryDto(
          id: 9,
          date: entry.key,
          content: entry.value,
          status: 'draft',
        ),
  ];

  @override
  void deleteDiaryEntry({required int id}) {
    if (id == 9) drafts.clear();
  }

  @override
  String addDiaryImage({required String date, required String path}) {
    addedImages.add((date, path));
    return path;
  }

  @override
  void removeDiaryImage({required String path}) {
    if (failRemoveImage) throw StateError('synthetic removal failure');
    removedImages.add(path);
    addedImages.removeWhere((image) => image.$2 == path);
  }

  @override
  void setDiaryImageEntry({required String path, required int entryId}) {
    if (path == failImage) throw StateError('synthetic association failure');
    linked.add((path, entryId));
  }

  @override
  void updateDiaryEntry({required int id, required String content}) {
    updates.add((id, content));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CalendarData _data({List<String> staged = const []}) => CalendarData(
  images: {_a: staged},
  entryImages: const {},
  diaryDays: const {_a},
  entries: const [
    DiaryEntryDto(id: 42, date: _a, content: '已发布记录\n原文', status: 'published'),
  ],
);

class _Host extends StatefulWidget {
  const _Host({this.width = 800, this.textScale = 1, super.key});
  final double width;
  final double textScale;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  DateTime date = DateTime(2026, 10, 1);
  bool visible = true;
  DiaryRange range = DiaryRange.day;

  void show(bool value) => setState(() => visible = value);
  void select(DateTime value) => setState(() => date = value);
  void setRange(DiaryRange value) => setState(() => range = value);

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: widget.width,
          child: visible
              ? DiarySection(date: date, range: range)
              : const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

Future<(ProviderContainer, GlobalKey<_HostState>)> _mount(
  WidgetTester tester,
  _FakeApi api, {
  Future<String?> Function(String)? readDraft,
  DiaryImageImporter? importer,
  CalendarData? data,
  DiaryComposerStore? composerStore,
  CalendarData Function()? readData,
  Future<CalendarData> Function()? readCalendar,
  double? width,
  double textScale = 1,
}) async {
  tester.view.resetPhysicalSize();
  tester.view.physicalSize = Size(width ?? 1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final metadata = MemoryDiaryMetadataStore();
  final candidates = MemoryMetadataCandidates();
  final container = ProviderContainer(
    overrides: [
      diaryDraftTagsStoreProvider.overrideWithValue(
        MemoryDiaryDraftTagsStore(),
      ),
      diaryEntryMetadataStoreProvider.overrideWithValue(metadata),
      diaryCandidateRepositoryProvider.overrideWithValue(candidates),
      apiProvider.overrideWithValue(api),
      diaryComposerStoreProvider.overrideWith((ref) {
        // Exercise real session/token/write logic with a synthetic store. A's
        // refresh coalescer is covered separately, not part of editor timing.
        final store =
            composerStore ??
            DiaryComposerStore(
              api: api,
              onPublished: (date, id) async {
                final saved = await ref
                    .read(
                      diaryEntryMetadataProvider(
                        DiaryEntryKey(date, id),
                      ).notifier,
                    )
                    .recordHandwritten();
                if (!saved) {
                  throw StateError('synthetic metadata not acknowledged');
                }
              },
            );
        ref.onDispose(store.dispose);
        return store;
      }),
      calendarDataProvider.overrideWith(
        (ref) async => readCalendar == null
            ? readData?.call() ?? data ?? _data()
            : await readCalendar(),
      ),
      diaryDraftProvider.overrideWith(
        (ref, date) async => readDraft == null
            ? api.getDiaryDraft(date: date)
            : await readDraft(date),
      ),
      diaryImageImporterProvider.overrideWithValue(
        importer ?? (_, __) async => [],
      ),
    ],
  );
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _Host(key: key, width: width ?? 800, textScale: textScale),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    composerStore?.dispose();
    final reads = (metadata.reads, candidates.reads);
    await tester.pump(const Duration(milliseconds: 300));
    expect((metadata.reads, candidates.reads), reads);
    expect(metadata.unexpected, 0);
    expect(candidates.unexpected, 0);
  });
  return (container, key);
}

Finder get _field => find.descendant(
  of: find.byType(MarkdownDiaryEditor),
  matching: find.byType(TextField),
);

Future<void> _open(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('diary-composer-toggle'));
  await tester.ensureVisible(toggle);
  await tester.pump();
  await tester.tap(toggle);
  await tester.pump();
}

Finder _title(int id) => find.byKey(ValueKey('diary-post-title-$id'));
Finder _body(int id) => find.byKey(ValueKey('diary-post-body-$id'));
Future<void> _tapReading(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 300));
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _keyboard(
  WidgetTester tester,
  Finder target,
  LogicalKeyboardKey key,
) async {
  await tester.ensureVisible(target);
  final child = find.descendant(of: target, matching: find.byType(Text));
  final content = child.evaluate().isEmpty
      ? find.descendant(of: target, matching: find.byType(Icon)).first
      : child.first;
  Focus.of(tester.element(content)).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

CalendarData _readingData(
  List<DiaryEntryDto> entries, {
  Map<int, List<String>> entryImages = const {},
}) => CalendarData(
  images: const {},
  entryImages: entryImages,
  diaryDays: entries.map((entry) => entry.date).toSet(),
  entries: entries,
);

void _expectComposerSemantics(
  WidgetTester tester,
  String label, {
  bool enabled = true,
}) {
  final toggle = find.byKey(const ValueKey('diary-composer-toggle'));
  final data = tester.getSemantics(toggle).getSemanticsData();
  expect(data.label, label);
  expect(data.tooltip, label);
  expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
  expect(data.hasFlag(SemanticsFlag.isEnabled), enabled);
  expect(data.hasAction(SemanticsAction.tap), enabled);
  expect(find.bySemanticsLabel(label), findsOneWidget);
}

void main() {
  testWidgets(
    'published loading preview uses real state and retains mounted draft through retry',
    (tester) async {
      final api = _FakeApi();
      final requests = <Completer<CalendarData>>[];
      final (container, _) = await _mount(
        tester,
        api,
        readCalendar: () {
          final request = Completer<CalendarData>();
          requests.add(request);
          return request.future;
        },
      );
      final section = tester.state(find.byType(DiarySection));
      expect(requests, hasLength(1));
      expect(
        find.byKey(const Key('diary-posts-loading-preview')),
        findsOneWidget,
      );
      expect(find.text('暂无已发布记录'), findsNothing);
      expect(_title(42), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _open(tester);
      await tester.pump();
      await tester.enterText(_field, 'actual unfinished draft');
      final editor = tester.state(find.byType(MarkdownDiaryEditor));
      requests.single.completeError(StateError('private synthetic diagnostic'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('diary-posts-load-error')), findsOneWidget);
      expect(find.textContaining('private synthetic'), findsNothing);
      expect(tester.state(find.byType(DiarySection)), same(section));
      expect(tester.state(find.byType(MarkdownDiaryEditor)), same(editor));
      expect(
        tester.widget<TextField>(_field).controller!.text,
        'actual unfinished draft',
      );
      await _tapReading(
        tester,
        find.byKey(const Key('diary-posts-load-retry')),
      );
      expect(requests, hasLength(2));
      expect(
        find.byKey(const Key('diary-posts-loading-preview')),
        findsOneWidget,
      );
      requests.last.complete(_readingData([]));
      await tester.pump();
      await tester.pump();
      expect(find.text('暂无已发布记录'), findsOneWidget);
      expect(
        find.byKey(const Key('diary-posts-loading-preview')),
        findsNothing,
      );
      expect(tester.state(find.byType(MarkdownDiaryEditor)), same(editor));
      container.invalidate(calendarDataProvider);
      await tester.pump();
      expect(requests, hasLength(3));
      expect(
        find.byKey(const Key('diary-posts-refresh-status')),
        findsOneWidget,
      );
      requests.last.completeError(StateError('private refresh failure'));
      await tester.pump();
      await tester.pump();
      expect(find.text('记录更新失败，保留上次已读取内容'), findsOneWidget);
      expect(find.textContaining('private refresh'), findsNothing);
      expect(tester.state(find.byType(MarkdownDiaryEditor)), same(editor));
      expect(api.published, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'published eight ordered tags paint fully in narrow title atscale2',
    (tester) async {
      final api = _FakeApi();
      final (c, _) = await _mount(tester, api, width: 280, textScale: 2);
      final n = c.read(
        diaryEntryMetadataProvider(DiaryEntryKey(_a, 42)).notifier,
      );
      final tags = List.generate(8, (i) => '标签' + i.toString() + '中文' * 8);
      expect(await n.setTags(tags), isTrue);
      await tester.pump();
      expect(find.text('来源未知'), findsOneWidget);
      for (final tag in tags) {
        final p = tester.renderObject<RenderParagraph>(
          find.byKey(ValueKey(('diary-tag', tag))),
        );
        expect(p.text.toPlainText(), tag);
        expect(p.didExceedMaxLines, isFalse);
        final boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: tag.length),
        );
        expect(boxes, isNotEmpty);
        for (final b in boxes)
          expect(b.right, lessThanOrEqualTo(p.size.width + .01));
      }
      final more = find.byKey(const ValueKey('diary-post-more-42'));
      // Complete the entry height transition before locating the real target.
      await tester.pump(const Duration(milliseconds: 300));
      await _tapReading(tester, more);
      expect(tester.getSize(more), const Size(48, 48));
      expect(find.byKey(const ValueKey('diary-post-tags-42')), findsOneWidget);
      expect(find.byType(MaterialTransientPanel), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'ordered draft tag Enter/remove at280 scale$scale survives close/date/remount',
      (tester) async {
        final api = _FakeApi(), repo = MemoryDiaryDraftTagsStore();
        final store = DiaryComposerStore(api: api, tagsStore: repo);
        final (container, key) = await _mount(
          tester,
          api,
          composerStore: store,
          width: 280,
          textScale: scale,
        );
        await _open(tester);
        await tester.pump();
        final input = find.byKey(const Key('diary-draft-tag-input'));
        await tester.enterText(_field, '900ms内原日正文');
        await tester.enterText(input, '第一');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.enterText(input, '😀' * 20);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(store.read(_a).tags, ['第一', '😀' * 20]);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byKey(ValueKey(('diary-tag', '😀' * 20))),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.text.toPlainText(), '😀' * 20);
        final glyphs = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 40),
        );
        expect(glyphs, isNotEmpty);
        for (final glyph in glyphs) {
          expect(glyph.left, greaterThanOrEqualTo(-.01));
          expect(glyph.right, lessThanOrEqualTo(paragraph.size.width + .01));
          expect(glyph.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
        }
        final remove = find.byKey(const ValueKey(('diary-remove-tag', '第一')));
        await tester.ensureVisible(remove);
        expect(tester.getSize(remove), const Size(48, 48));
        await tester.tap(remove);
        await tester.pump();
        expect(store.read(_a).tags, ['😀' * 20]);
        final add = find.byKey(const Key('diary-draft-tag-add'));
        expect(tester.getSize(add), const Size(48, 48));
        await _open(tester); // close before editor debounce
        expect(find.byType(MarkdownDiaryEditor), findsNothing);
        key.currentState!.select(DateTime(2026, 10, 2));
        await tester.pump();
        await _open(tester);
        await tester.pump();
        expect(store.read(_b).tags, isEmpty);
        key.currentState!.select(DateTime(2026, 10, 1));
        await tester.pump();
        await _open(tester);
        await tester.pump();
        expect(tester.widget<TextField>(_field).controller!.text, '900ms内原日正文');
        expect(store.read(_a).tags, ['😀' * 20]);
        expect(repo.values[_a]!.tags, ['😀' * 20]);
        key.currentState!.show(false);
        await tester.pump();
        key.currentState!.show(true);
        await tester.pump();
        await _open(tester);
        await tester.pump();
        expect(store.read(_a).tags, ['😀' * 20]);
        expect(api.published, isEmpty);
        expect(tester.takeException(), isNull);
        expect(
          container.read(diaryDraftTagsStoreProvider),
          isA<MemoryDiaryDraftTagsStore>(),
        );
      },
    );
  }
  testWidgets(
    'pending tag write disables stale Enter/removal and original tags are retained',
    (tester) async {
      final api = _FakeApi(), repo = MemoryDiaryDraftTagsStore();
      final store = DiaryComposerStore(
        api: api,
        tagsStore: repo,
        writeDraft: (_, __) async {},
      );
      await _mount(tester, api, composerStore: store, width: 280, textScale: 2);
      await _open(tester);
      await tester.pump();
      final input = find.byKey(const Key('diary-draft-tag-input'));
      await tester.enterText(input, '保留');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      // A publication intent consumes editing eligibility; UI callbacks recheck.
      final session = store.read(_a);
      session.updateText('正文');
      await session.publish();
      await session.retryMetadata();
      await tester.pump();
      expect(session.retired, isTrue);
      expect(await session.setTags(['不覆盖']), isFalse);
      expect(session.tags, ['保留']);
      expect(api.published.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source and tags More panel is usable at280 scale2 and preserves collapsed body',
    (tester) async {
      final api = _FakeApi();
      final (container, _) = await _mount(
        tester,
        api,
        width: 280,
        textScale: 2,
      );
      await tester.pump();
      expect(find.text('来源未知'), findsOneWidget);
      final title = _title(42);
      final edit = find.byKey(const ValueKey('diary-post-edit-42'));
      final more = find.byKey(const ValueKey('diary-post-more-42'));
      expect(tester.getSize(title).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(edit), const Size(48, 48));
      expect(tester.getSize(more), const Size(48, 48));
      await _tapReading(tester, more);
      await _tapReading(
        tester,
        find.byKey(const ValueKey('diary-post-tags-42')),
      );
      expect(
        find.byKey(const ValueKey('diary-metadata-panel-42')),
        findsOneWidget,
      );
      final input = find.byKey(const Key('diary_metadata_tags_input'));
      await tester.enterText(input, '工作, 阅读');
      await _tapReading(tester, find.byKey(const Key('diary_metadata_save')));
      expect(
        container
            .read(diaryEntryMetadataProvider(DiaryEntryKey(_a, 42)))
            .value
            .tags,
        ['工作', '阅读'],
      );
      expect(
        find.byKey(const ValueKey('diary-metadata-panel-42')),
        findsNothing,
      );
      expect(_body(42), findsNothing);
      expect(api.published, isEmpty);
      await _tapReading(tester, more);
      await _tapReading(
        tester,
        find.byKey(const ValueKey('diary-post-tags-42')),
      );
      // Ordered chips replace the old comma-separated prefilled input.
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      final panel = find.byKey(const ValueKey('diary-metadata-panel-42'));
      for (final tag in ['工作', '阅读']) {
        final remove = find.descendant(
          of: panel,
          matching: find.byKey(ValueKey(('diary-remove-tag', tag))),
        );
        await _tapReading(tester, remove);
      }
      await _tapReading(tester, find.byKey(const Key('diary_metadata_save')));
      expect(
        container
            .read(diaryEntryMetadataProvider(DiaryEntryKey(_a, 42)))
            .value
            .tags,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [280.0, 720.0]) {
    testWidgets(
      'published title edit and menu share one line at $width scale2',
      (tester) async {
        final api = _FakeApi();
        await _mount(tester, api, width: width, textScale: 2);
        final title = _title(42);
        final edit = find.byKey(const ValueKey('diary-post-edit-42'));
        final menu = find.byKey(const ValueKey('diary-post-more-42'));
        expect(
          tester.getRect(title).center.dy,
          closeTo(tester.getRect(edit).center.dy, .01),
        );
        expect(
          tester.getRect(menu).center.dy,
          closeTo(tester.getRect(edit).center.dy, .01),
        );
        expect(tester.getSize(edit), const Size(48, 48));
        expect(tester.getSize(menu), const Size(48, 48));
        expect(find.byType(MarkdownBody), findsNothing);
        await _tapReading(tester, edit);
        expect(
          find.byKey(const ValueKey('diary-post-editor-42')),
          findsOneWidget,
        );
        expect(_body(42), findsNothing);
        expect(api.published, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'write icon exposes its action and Enter/Space keep read and write separate',
    (tester) async {
      final api = _FakeApi();
      await _mount(tester, api);
      final semantics = tester.ensureSemantics();
      try {
        final write = find.byKey(const ValueKey('diary-composer-toggle'));
        expect(tester.widget<IconButton>(write).tooltip, '写日记');
        expect(tester.getSize(write).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(write).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(write).getSemanticsData().label,
          contains('写日记'),
        );
        _expectComposerSemantics(tester, '写日记');
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(MarkdownBody), findsNothing);
        await _keyboard(tester, write, LogicalKeyboardKey.enter);
        expect(find.byType(MarkdownDiaryEditor), findsOneWidget);
        expect(tester.widget<IconButton>(write).tooltip, '收起编辑');
        _expectComposerSemantics(tester, '收起编辑');
        await _keyboard(tester, write, LogicalKeyboardKey.space);
        expect(find.byType(MarkdownDiaryEditor), findsNothing);
        expect(find.byType(TextField), findsNothing);
        await _keyboard(tester, _title(42), LogicalKeyboardKey.enter);
        expect(_body(42), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(
          tester
              .widget<Semantics>(
                find.byKey(const ValueKey('diary-post-title-semantics-42')),
              )
              .properties
              .expanded,
          isTrue,
        );
        await _keyboard(tester, _title(42), LogicalKeyboardKey.space);
        expect(_body(42), findsNothing);
        expect(
          tester
              .widget<Semantics>(
                find.byKey(const ValueKey('diary-post-title-semantics-42')),
              )
              .properties
              .expanded,
          isFalse,
        );
        expect(api.published, isEmpty);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'narrow large-text draft load and retry keep named disabled action',
    (tester) async {
      final api = _FakeApi();
      final pending = Completer<String?>();
      var reads = 0;
      await _mount(
        tester,
        api,
        width: 280,
        textScale: 2,
        readDraft: (_) => ++reads == 1 ? pending.future : Future.value('原草稿'),
      );
      final semantics = tester.ensureSemantics();
      try {
        expect(find.text('草稿加载中'), findsOneWidget);
        _expectComposerSemantics(tester, '写日记', enabled: false);
        expect(tester.takeException(), isNull);
        pending.completeError(StateError('synthetic read failure'));
        await tester.pump();
        await tester.pump();
        _expectComposerSemantics(tester, '写日记', enabled: false);
        expect(find.byTooltip('重试读取草稿'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _tapReading(tester, find.byTooltip('重试读取草稿'));
        await tester.pump();
        _expectComposerSemantics(tester, '继续草稿');
        expect(find.byType(MarkdownDiaryEditor), findsNothing);
        expect(api.writes, isEmpty);
        expect(api.published, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  final titleCases = <(String, String)>[
    ('# **一级标题** ###\n正文', '一级标题'),
    ('## [二级标题](https://invalid.fixture)\n正文', '二级标题'),
    ('###### 六级标题\n正文', '六级标题'),
    ('**Setext 标题**\n==========\n正文', 'Setext 标题'),
    ('兼容短标题\n-----------\n正文', '兼容短标题'),
    ('普通序言\n~~~md\n# 围栏里的假标题\n~~~\n## 真标题\n正文', '真标题'),
    ('无标题首行\n第二行', '无标题首行'),
    ('![只有图片](synthetic-only.png)', '无文字日记'),
    ('![图片][img]\n[img]: synthetic-reference.png', '无文字日记'),
    (' \n\t', '无文字日记'),
    ('~~~\n# 只有代码\n~~~', '无文字日记'),
    ('# ' + '😀' * 90 + '\n正文', '😀' * 80),
  ];
  for (var index = 0; index < titleCases.length; index++) {
    final fixture = titleCases[index];
    testWidgets(
      'published title is bounded plain text case $index without Markdown mount',
      (tester) async {
        final api = _FakeApi();
        await _mount(
          tester,
          api,
          data: _readingData([
            DiaryEntryDto(
              id: 42,
              date: _a,
              content: fixture.$1,
              status: 'published',
            ),
          ]),
        );
        await tester.pump();
        final title = tester.widget<Text>(
          find.byKey(const ValueKey('diary-post-title-text-42')),
        );
        expect(title.data, fixture.$2);
        expect(title.maxLines, 1);
        expect(title.overflow, TextOverflow.ellipsis);
        expect(find.byType(MarkdownBody), findsNothing);
        expect(find.byType(MarkdownDiaryEditor), findsNothing);
        expect(find.byType(ImageAlbum), findsNothing);
        expect(api.writes, isEmpty);
        expect(api.published, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'long bodies are built only for the selected title and title toggles never edit',
    (tester) async {
      final api = _FakeApi();
      final longText =
          '# 长总结\n\n' +
          List.generate(
            18,
            (index) => '第$index段：这是较长的活动总结，只在明确展开后才阅读。',
          ).join('\n\n');
      await _mount(
        tester,
        api,
        data: _readingData(
          [
            DiaryEntryDto(
              id: 42,
              date: _a,
              content: longText,
              status: 'published',
            ),
            const DiaryEntryDto(
              id: 43,
              date: _a,
              content: '## 第二条\n另一个独立正文',
              status: 'published',
            ),
          ],
          entryImages: {
            42: ['synthetic-reading-only.png'],
          },
        ),
      );
      await tester.pump();
      expect(_title(42), findsOneWidget);
      expect(_title(43), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.byType(ImageAlbum), findsNothing);
      expect(find.text('图片已隐藏'), findsNothing);
      expect(find.byTooltip('显示文字'), findsNothing);
      await _tapReading(tester, _title(42));
      expect(_body(42), findsOneWidget);
      expect(_body(43), findsNothing);
      expect(tester.widget<MarkdownBody>(_body(42)).data, longText);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(MarkdownDiaryEditor), findsNothing);
      await _tapReading(tester, _title(42));
      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.text('图片已隐藏'), findsNothing);
      await _tapReading(tester, _title(43));
      expect(_body(43), findsOneWidget);
      expect(_body(42), findsNothing);
      expect(api.updates, isEmpty);
      expect(api.writes, isEmpty);
      expect(api.published, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-range insertion/removal preserves expanded IDs; date/range/remount reset reading',
    (tester) async {
      final api = _FakeApi();
      const original = DiaryEntryDto(
        id: 42,
        date: _a,
        content: '# 既有标题\n需要保持的正文',
        status: 'published',
      );
      const added = DiaryEntryDto(
        id: 43,
        date: _a,
        content: '# 新标题\n新正文默认不挂',
        status: 'published',
      );
      var entries = <DiaryEntryDto>[original];
      final (container, host) = await _mount(
        tester,
        api,
        readData: () => _readingData(entries),
      );
      await _tapReading(tester, _title(42));
      expect(_body(42), findsOneWidget);
      entries = [added, original];
      container.invalidate(calendarDataProvider);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(_body(42), findsOneWidget);
      expect(_body(43), findsNothing);
      entries = [original];
      container.invalidate(calendarDataProvider);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(_body(42), findsOneWidget);
      expect(_title(43), findsNothing);
      host.currentState!.setRange(DiaryRange.week);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(_title(42), findsOneWidget);
      expect(_body(42), findsNothing);
      await _tapReading(tester, _title(42));
      host.currentState!.select(
        DateTime(2026, 10, 2),
      ); // Both days keep ID42 in this week.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(_title(42), findsOneWidget);
      expect(_body(42), findsNothing);
      await _tapReading(tester, _title(42));
      host.currentState!.show(false);
      await tester.pump();
      host.currentState!.show(true);
      await tester.pump();
      await tester.pump();
      expect(_title(42), findsOneWidget);
      expect(_body(42), findsNothing);
      expect(find.byType(MarkdownDiaryEditor), findsNothing);
      expect(api.published, isEmpty);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [280.0, 720.0]) {
    testWidgets(
      'title and write controls remain readable at $width with large text',
      (tester) async {
        final api = _FakeApi()..drafts[_a] = '继续的草稿';
        await _mount(
          tester,
          api,
          width: width,
          textScale: 2,
          data: _readingData([
            DiaryEntryDto(
              id: 42,
              date: _a,
              content: '# ' + '很长的阅读标题' * 20 + '\n正文',
              status: 'published',
            ),
          ]),
        );
        await tester.pump();
        expect(find.byTooltip('继续草稿'), findsOneWidget);
        expect(_title(42), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(MarkdownBody), findsNothing);
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('diary-post-title-text-42')),
              )
              .data!
              .runes
              .length,
          lessThanOrEqualTo(80),
        );
        await _tapReading(tester, _title(42));
        expect(_body(42), findsOneWidget);
        await _tapReading(tester, _title(42));
        expect(_body(42), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'independent inline edit keeps original ID and newly picked image ownership',
    (tester) async {
      final api = _FakeApi();
      await _mount(
        tester,
        api,
        importer: (_, __) async => ['synthetic-inline-reading.png'],
        data: _readingData([
          const DiaryEntryDto(
            id: 42,
            date: _a,
            content: '# 标题42\n原文42',
            status: 'published',
          ),
          const DiaryEntryDto(
            id: 43,
            date: _a,
            content: '# 标题43\n原文43',
            status: 'published',
          ),
        ]),
      );
      await _tapReading(
        tester,
        find.byKey(const ValueKey('diary-post-edit-42')),
      );
      expect(find.byType(MarkdownDiaryEditor), findsNothing);
      expect(_body(42), findsNothing);
      expect(_body(43), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('diary-post-editor-42')),
        '修改后的原42',
      );
      final add = find
          .ancestor(
            of: find.descendant(
              of: find.byKey(const ValueKey(42)),
              matching: find.byIcon(Icons.add),
            ),
            matching: find.byType(InkWell),
          )
          .first;
      // The existing inline image grid's trailing add target, never a real picker.
      await _tapReading(tester, add);
      expect(api.addedImages, [(_a, 'synthetic-inline-reading.png')]);
      await _tapReading(
        tester,
        find.byKey(const ValueKey('diary-post-save-42')),
      );
      expect(api.updates, [(42, '修改后的原42')]);
      expect(api.linked, [('synthetic-inline-reading.png', 42)]);
      expect(api.published, isEmpty);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'fresh session rejects stale text and image snapshots after publish',
    () async {
      final api = _FakeApi();
      final store = DiaryComposerStore(api: api);
      final old = store.read(_a)..seed('已发布内容');
      old.addImage('synthetic-already-linked.png');
      await old.publish();
      final fresh = store.read(_a);
      fresh.seed('迟到旧草稿');
      fresh.seedImages(_data(staged: ['synthetic-already-linked.png']));
      expect(identical(old.token, fresh.token), isFalse);
      expect(fresh.text, '');
      expect(fresh.staged, isEmpty);
    },
  );

  test(
    'scope disposal rejects picker result and delayed publication',
    () async {
      final api = _FakeApi();
      final saving = Completer<void>();
      final store = DiaryComposerStore(
        api: api,
        writeDraft: (_, __) => saving.future,
      );
      final session = store.read(_a)..seed('范围内草稿');
      session.updateText('等待保存');
      final flush = session.flush();
      final publish = session.publish();
      store.dispose();
      expect(session.acceptsImages, isFalse);
      saving.complete();
      await flush;
      await publish;
      expect(api.published, isEmpty);
    },
  );

  testWidgets(
    'reading first; continue loads existing draft and preserves feed',
    (tester) async {
      final api = _FakeApi()..drafts[_a] = '原草稿';
      await _mount(tester, api);
      expect(find.text('已发布记录'), findsOneWidget);
      expect(find.byTooltip('继续草稿'), findsOneWidget);
      expect(find.byType(MarkdownDiaryEditor), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('加粗'), findsNothing);
      expect(find.byTooltip('添加图片（可多选）'), findsNothing);
      await _open(tester);
      expect(tester.widget<TextField>(_field).controller!.text, '原草稿');
      expect(find.byTooltip('加粗'), findsOneWidget);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets('typing and format insertion survive close before debounce', (
    tester,
  ) async {
    final api = _FakeApi();
    final (container, _) = await _mount(tester, api);
    await _open(tester);
    await tester.enterText(_field, '最新内容');
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    final latest = tester.widget<TextField>(_field).controller!.text;
    expect(latest, contains('**'));
    expect(container.read(diaryComposerStoreProvider).read(_a).text, latest);
    await tester.tap(find.byTooltip('收起编辑'));
    await tester.pump();
    expect(find.byType(MarkdownDiaryEditor), findsNothing);
    await _open(tester);
    expect(tester.widget<TextField>(_field).controller!.text, latest);
    expect(api.writes, [(_a, latest)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent removal and date update flush only captured date A', (
    tester,
  ) async {
    final api = _FakeApi()..drafts[_b] = 'B原草稿';
    final (_, host) = await _mount(tester, api);
    await _open(tester);
    await tester.enterText(_field, 'A卸载内容');
    host.currentState!.show(false);
    await tester.pump();
    expect(api.writes, [(_a, 'A卸载内容')]);
    host.currentState!.show(true);
    await tester.pump();
    await tester.pump();
    await _open(tester);
    expect(tester.widget<TextField>(_field).controller!.text, 'A卸载内容');
    await tester.enterText(_field, 'A换日内容');
    host.currentState!.select(DateTime(2026, 10, 2));
    await tester.pump();
    await tester.pump();
    expect(api.writes.last, (_a, 'A换日内容'));
    expect(api.drafts[_b], 'B原草稿');
    expect(find.byType(MarkdownDiaryEditor), findsNothing);
    await _open(tester);
    expect(tester.widget<TextField>(_field).controller!.text, 'B原草稿');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'debounce still waits 900ms and successful clean unmount does not rewrite',
    (tester) async {
      final api = _FakeApi();
      final (_, host) = await _mount(tester, api);
      await _open(tester);
      await tester.enterText(_field, '定时草稿');
      await tester.pump(const Duration(milliseconds: 899));
      expect(api.writes, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(api.writes, [(_a, '定时草稿')]);
      host.currentState!.show(false);
      await tester.pump();
      expect(api.writes, hasLength(1));
    },
  );

  testWidgets(
    'cold draft loading blocks empty editing; error permits read retry',
    (tester) async {
      final api = _FakeApi();
      final first = Completer<String?>();
      var reads = 0;
      await _mount(
        tester,
        api,
        readDraft: (_) {
          reads++;
          return reads == 1 ? first.future : Future.value('读取后草稿');
        },
      );
      expect(find.text('草稿加载中'), findsOneWidget);
      expect(find.byType(MarkdownDiaryEditor), findsNothing);
      first.completeError(StateError('synthetic read failure'));
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('重试读取草稿'), findsOneWidget);
      await tester.tap(find.byTooltip('重试读取草稿'));
      await tester.pump();
      await tester.pump();
      await _open(tester);
      expect(tester.widget<TextField>(_field).controller!.text, '读取后草稿');
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'failed save retains memory through unload and retries successfully',
    (tester) async {
      final api = _FakeApi()..failSave = true;
      final (container, host) = await _mount(tester, api);
      await _open(tester);
      await tester.enterText(_field, '失败后保留');
      host.currentState!.show(false);
      await tester.pump();
      await tester.pump();
      final session = container.read(diaryComposerStoreProvider).read(_a);
      expect(session.text, '失败后保留');
      expect(session.dirty, isTrue);
      expect(session.error, isNotNull);
      host.currentState!.show(true);
      await tester.pump();
      await tester.pump();
      await _open(tester);
      expect(tester.widget<TextField>(_field).controller!.text, '失败后保留');
      api.failSave = false;
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      await tester.pump();
      expect(api.drafts[_a], '失败后保留');
      expect(session.dirty, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'publish retires draft before disposal and next composer starts empty',
    (tester) async {
      final api = _FakeApi()..drafts[_a] = '待发布';
      final (container, host) = await _mount(tester, api);
      await _open(tester);
      await tester.enterText(_field, '最终发布');
      final oldSession = container.read(diaryComposerStoreProvider).read(_a);
      await tester.tap(find.byTooltip('发布'));
      await tester.pump();
      await tester.pump();
      expect(api.published, [(_a, '最终发布')]);
      expect(oldSession.retired, isTrue);
      expect(api.drafts[_a], isNull);
      expect(api.writes, isEmpty);
      host.currentState!.show(false);
      await tester.pump();
      host.currentState!.show(true);
      await tester.pump();
      await tester.pump();
      await _open(tester);
      expect(tester.widget<TextField>(_field).controller!.text, '');
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'confirmed discard retires token and does not resurrect on dispose',
    (tester) async {
      final api = _FakeApi()..drafts[_a] = '旧草稿';
      final (container, _) = await _mount(tester, api);
      await _open(tester);
      await tester.enterText(_field, '待放弃内容');
      final session = container.read(diaryComposerStoreProvider).read(_a);
      await tester.tap(find.text('放弃草稿'));
      await tester.pump();
      await tester.tap(find.text('放弃'));
      await tester.pump();
      await tester.pump();
      expect(session.retired, isTrue);
      expect(api.drafts[_a], isNull);
      expect(api.writes, isEmpty);
      await session.flush();
      await _open(tester);
      expect(tester.widget<TextField>(_field).controller!.text, '');
      expect(api.writes, isEmpty);
    },
  );

  test(
    'late seed cannot overwrite newer buffer; save completion leaves newer revision dirty',
    () async {
      final api = _FakeApi();
      final save = Completer<void>();
      final writes = <(String, String)>[];
      final store = DiaryComposerStore(
        api: api,
        writeDraft: (date, text) {
          writes.add((date, text));
          return save.future;
        },
      );
      final session = store.read(_a);
      session.updateText('第一版');
      session.seed('迟到旧草稿');
      expect(session.text, '第一版');
      final operation = session.flush();
      session.updateText('第二版');
      save.complete();
      await operation;
      expect(writes, [(_a, '第一版')]);
      expect(session.text, '第二版');
      expect(session.dirty, isTrue);
      await session.flush();
      expect(writes.last, (_a, '第二版'));
      expect(session.dirty, isFalse);
    },
  );

  test(
    'publish waits for earlier draft write; retired token rejects later flush',
    () async {
      final api = _FakeApi();
      final save = Completer<void>();
      final session = DiaryComposerStore(
        api: api,
        writeDraft: (date, text) async {
          await save.future;
          api.saveDiaryDraft(date: date, content: text);
        },
      ).read(_a)..seed(null);
      session.updateText('先存后发');
      final flush = session.flush();
      final publish = session.publish();
      expect(api.published, isEmpty);
      save.complete();
      await flush;
      await publish;
      await session.flush();
      expect(api.writes, [(_a, '先存后发')]);
      expect(api.published, [(_a, '先存后发')]);
      expect(api.drafts[_a], isNull);
      expect(session.retired, isTrue);
    },
  );

  test('partial image association retry never publishes text twice', () async {
    final api = _FakeApi()..failImage = 'synthetic-second.png';
    final session = DiaryComposerStore(api: api).read(_a)..seed(null);
    session.updateText('图片日记');
    session.addImage('synthetic-first.png');
    session.addImage('synthetic-second.png');
    await expectLater(session.publish(), throwsStateError);
    expect(session.retired, isTrue);
    expect(session.staged, ['synthetic-second.png']);
    expect(session.publishedEntryId, 100);
    session.updateText('不应改写已发表文字');
    await session.flush();
    api.failImage = null;
    await session.publish();
    expect(api.published, [(_a, '图片日记')]);
    expect(api.linked, [
      ('synthetic-first.png', 100),
      ('synthetic-second.png', 100),
    ]);
    expect(api.writes, isEmpty);
    expect(session.staged, isEmpty);
  });

  testWidgets(
    'picker return across date stays at original session and close retains images',
    (tester) async {
      final api = _FakeApi();
      final selected = Completer<List<String>>();
      String? pickedDate;
      final (container, host) = await _mount(
        tester,
        api,
        importer: (date, accepts) {
          pickedDate = date;
          return selected.future;
        },
      );
      await _open(tester);
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pump();
      host.currentState!.select(DateTime(2026, 10, 2));
      await tester.pump();
      await tester.pump();
      selected.complete(['synthetic-composer-image.png']);
      await tester.pump();
      expect(pickedDate, _a);
      expect(api.addedImages, [(_a, 'synthetic-composer-image.png')]);
      expect(
        container.read(diaryComposerStoreProvider).read(_b).staged,
        isEmpty,
      );
      host.currentState!.select(DateTime(2026, 10, 1));
      await tester.pump();
      await tester.pump();
      await _open(tester);
      await tester.pump();
      expect(container.read(diaryComposerStoreProvider).read(_a).staged, [
        'synthetic-composer-image.png',
      ]);
      await tester.tap(find.byTooltip('收起编辑'));
      await tester.pump();
      expect(container.read(diaryComposerStoreProvider).read(_a).staged, [
        'synthetic-composer-image.png',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'picker return for retired session is rejected before registration',
    (tester) async {
      final api = _FakeApi()..drafts[_a] = 'picker期间发布';
      final selected = Completer<List<String>>();
      bool Function()? accepts;
      await _mount(
        tester,
        api,
        importer: (_, check) {
          accepts = check;
          return selected.future;
        },
      );
      await _open(tester);
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pump();
      await tester.tap(find.byTooltip('发布'));
      await tester.pump();
      await tester.pump();
      expect(accepts!(), isFalse);
      selected.complete(['synthetic-retired-image.png']);
      await tester.pump();
      expect(api.addedImages, isEmpty);
      expect(api.published, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'staged removal confirms registration before allowing file deletion',
    () {
      final api = _FakeApi();
      final session = DiaryComposerStore(api: api).read(_a)..seed(null);
      session.addImage('synthetic-remove.png');
      session.addImage('synthetic-keep.png');
      api.failRemoveImage = true;
      expect(session.removeImage('synthetic-remove.png'), isFalse);
      expect(session.staged, ['synthetic-remove.png', 'synthetic-keep.png']);
      expect(api.addedImages, [
        (_a, 'synthetic-remove.png'),
        (_a, 'synthetic-keep.png'),
      ]);
      expect(session.error, '图片未移除，请重试');
      expect(api.removedImages, isEmpty);
      api.failRemoveImage = false;
      expect(session.removeImage('synthetic-remove.png'), isTrue);
      expect(session.staged, ['synthetic-keep.png']);
      expect(api.addedImages, [(_a, 'synthetic-keep.png')]);
      expect(api.removedImages, ['synthetic-remove.png']);
      expect(session.error, isNull);
      expect(session.removeImage('synthetic-remove.png'), isFalse);
      expect(api.removedImages, ['synthetic-remove.png']);
    },
  );

  testWidgets('staged removal is disabled while publication waits for save', (
    tester,
  ) async {
    const path = 'synthetic-publishing-image.png';
    final api = _FakeApi()..drafts[_a] = '等待发布';
    final saving = Completer<void>();
    final store = DiaryComposerStore(
      api: api,
      writeDraft: (_, __) => saving.future,
    );
    final session = store.read(_a)..seed('等待发布');
    session.addImage(path);
    final (_, _) = await _mount(tester, api, composerStore: store);
    await _open(tester);
    session.updateText('等待保存完成后发布');
    final flush = session.flush();
    await tester.tap(find.byTooltip('发布'));
    await tester.pump();
    expect(session.publishing, isTrue);
    final remove = find.byKey(const ValueKey('diary-staged-remove-$path'));
    expect(remove, findsOneWidget);
    expect(tester.widget<InkWell>(remove).onTap, isNull);
    await tester.tap(remove);
    expect(session.removeImage(path), isFalse);
    expect(session.staged, [path]);
    expect(api.addedImages, [(_a, path)]);
    expect(api.removedImages, isEmpty);
    expect(api.published, isEmpty);
    saving.complete();
    await flush;
    await tester.pump();
    await tester.pump();
    expect(api.published, hasLength(1));
    expect(api.linked, [(path, 100)]);
    expect(api.removedImages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retired pending image cannot be removed and retries original id',
    (tester) async {
      const path = 'synthetic-pending-image.png';
      final api = _FakeApi()
        ..drafts[_a] = '图片发表'
        ..failImage = path;
      final (container, host) = await _mount(
        tester,
        api,
        importer: (_, __) async => [path],
      );
      await _open(tester);
      await tester.tap(find.byTooltip('添加图片（可多选）'));
      await tester.pump();
      await tester.tap(find.byTooltip('发布'));
      await tester.pump();
      await tester.pump();
      final session = container.read(diaryComposerStoreProvider).read(_a);
      expect(session.retired, isTrue);
      expect(session.hasPendingImages, isTrue);
      expect(session.publishedEntryId, 100);
      final remove = find.byKey(const ValueKey('diary-staged-remove-$path'));
      expect(remove, findsOneWidget);
      expect(tester.widget<InkWell>(remove).onTap, isNull);
      await tester.tap(remove);
      expect(session.removeImage(path), isFalse);
      expect(session.staged, [path]);
      expect(api.addedImages, [(_a, path)]);
      expect(api.removedImages, isEmpty);
      host.currentState!.show(false);
      await tester.pump();
      host.currentState!.show(true);
      await tester.pump();
      await tester.pump();
      await _open(tester);
      expect(tester.widget<InkWell>(remove).onTap, isNull);
      expect(session.staged, [path]);
      api.failImage = null;
      await tester.tap(find.byTooltip('发布'));
      await tester.pump();
      await tester.pump();
      expect(api.published, [(_a, '图片发表')]);
      expect(api.linked, [(path, 100)]);
      expect(api.removedImages, isEmpty);
      expect(session.staged, isEmpty);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'existing published inline save still updates original entry id',
    (tester) async {
      final api = _FakeApi();
      await _mount(tester, api);
      await tester.tap(find.byTooltip('编辑'));
      // Start, then finish the day group's 250ms height transition.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '修改既有记录');
      final save = find.widgetWithText(FilledButton, '保存');
      expect(save, findsOneWidget);
      await tester.ensureVisible(save);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(save.hitTestable(), findsOneWidget);
      await tester.tap(save);
      await tester.pump();
      expect(api.updates, [(42, '修改既有记录')]);
      expect(api.published, isEmpty);
      expect(api.writes, isEmpty);
    },
  );
}
