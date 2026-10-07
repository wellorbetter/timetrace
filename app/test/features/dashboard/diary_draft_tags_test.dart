import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_entry_metadata_store.dart';
import 'package:timetrace_app/src/features/dashboard/domain/diary_entry_metadata.dart';
import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'diary_entry_metadata_test.dart' show MemoryDiaryMetadataStore;

const day = '2026-10-04';

class _Api implements TimeTraceApi {
  int appends = 0, otherCalls = 0;
  bool loseId = false, invalidId = false, failDiscard = false;
  String? failImage;
  void Function()? onAppend;
  final linked = <(String, int)>[];
  @override
  int publishDiary({required String date, required String content}) {
    appends++;
    onAppend?.call();
    if (loseId) throw StateError('synthetic append occurred, ID lost');
    return invalidId ? 0 : 42;
  }

  @override
  void setDiaryImageEntry({required String path, required int entryId}) {
    if (path == failImage) throw StateError('synthetic image failure');
    linked.add((path, entryId));
  }

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) {
    if (failDiscard) throw StateError('synthetic cleanup failure');
    return [];
  }

  @override
  void removeDiaryImage({required String path}) {}
  @override
  int saveDiaryDraft({required String date, required String content}) => 9;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    otherCalls++;
    throw StateError('Forbidden API ' + invocation.memberName.toString());
  }
}

class _ControlledStore extends MemoryDiaryDraftTagsStore {
  bool fail = false, loseAck = false, throwRead = false;
  DiaryDraftTagLoad? forcedRead;
  Completer<void>? barrier;
  final attempted = <DiaryDraftTagSnapshot>[];
  @override
  Future<DiaryDraftTagLoad> load(String date) async {
    if (throwRead) throw StateError('synthetic read failure');
    return forcedRead ?? await super.load(date);
  }

  @override
  Future<void> put(
    DiaryDraftTagSnapshot value, {
    required int? expectedRevision,
  }) async {
    attempted.add(value);
    final gate = barrier;
    if (gate != null) await gate.future;
    if (fail) throw StateError('synthetic durable failure');
    await super.put(value, expectedRevision: expectedRevision);
    if (loseAck) {
      loseAck = false;
      throw StateError('synthetic verification lost');
    }
  }
}

class _LateStore extends MemoryDiaryDraftTagsStore {
  Completer<DiaryDraftTagLoad>? read;
  @override
  Future<DiaryDraftTagLoad> load(String date) =>
      read?.future ?? super.load(date);
}

class _NoReadAfterDispose extends MemoryDiaryDraftTagsStore {
  int reads = 0;
  @override
  Future<DiaryDraftTagLoad> load(String date) async {
    reads++;
    throw StateError('Disposed session must not read any backend');
  }
}

class _LostVerifyBackend extends DiaryMetadataFileBackend {
  bool committed = false, failed = false;
  @override
  Future<void> commit(File temporary, File target) async {
    await super.commit(temporary, target);
    committed = true;
  }

  @override
  Future<String> read(File file) async {
    if (committed && !failed && file.path.endsWith('.json')) {
      failed = true;
      throw const FileSystemException('synthetic lost verify');
    }
    return super.read(file);
  }
}

class _TagsCommitGate extends DiaryMetadataFileBackend {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> commit(File temporary, File target) async {
    entered.complete();
    await release.future;
    await super.commit(temporary, target);
  }
}

DiaryComposerSession _session(
  _Api api,
  DiaryDraftTagsStore store, {
  DiaryTagPromotion? promote,
}) => DiaryComposerSession(
  date: day,
  api: api,
  tagsStore: store,
  tagIdentity: () => 'synthetic-generation',
  onPromoteTags: promote,
)..seed('原日期正文');
String _path(Directory root, String name) =>
    root.path + Platform.pathSeparator + day + Platform.pathSeparator + name;
Future<Directory> _fixture() async {
  final root = await Directory.systemTemp.createTemp(
    'timetrace-draft-tags-test-',
  );
  final prefix = Directory.systemTemp.absolute.path + Platform.pathSeparator;
  final absolute = root.absolute.path;
  expect(root.isAbsolute, isTrue);
  expect(absolute.startsWith(prefix), isTrue);
  addTearDown(() async {
    if (root.absolute.path != absolute || !absolute.startsWith(prefix))
      throw StateError('Unsafe cleanup');
    if (await root.exists()) await root.delete(recursive: true);
  });
  return root;
}

void main() {
  for (final competingRevision in [1, 2]) {
    test(
      'draft tags held transaction excludes independent revision $competingRevision',
      () async {
        final root = await _fixture(), gate = _TagsCommitGate();
        final first = FileDiaryDraftTagsStore(
          directory: () => root,
          backend: gate,
        );
        final second = FileDiaryDraftTagsStore(directory: () => root);
        final winner = DiaryDraftTagSnapshot(
          date: day,
          generation: 'winner',
          revision: 1,
          tags: ['original'],
        );
        final loser = DiaryDraftTagSnapshot(
          date: day,
          generation: 'loser',
          revision: competingRevision,
          tags: ['competing'],
        );
        final writing = first.put(winner, expectedRevision: null);
        await gate.entered.future;
        Object? failure;
        var completed = false;
        final competing = second
            .put(loser, expectedRevision: null)
            .then<void>(
              (_) {
                completed = true;
              },
              onError: (Object error) {
                failure = error;
                completed = true;
              },
            );
        try {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            completed,
            isFalse,
            reason:
                'same entry transaction is held by the first independent handle',
          );
        } finally {
          gate.release.complete();
        }
        await writing;
        await competing;
        expect(failure, isA<DiaryMetadataConflict>());
        final target = File(_path(root, 'tags-r1.json'));
        final bytes = await target.readAsString();
        expect((await second.load(day)).value!.toJson(), winner.toJson());
        await expectLater(
          second.put(loser, expectedRevision: null),
          throwsA(isA<DiaryMetadataConflict>()),
        );
        expect(await target.readAsString(), bytes);
      },
    );
  }

  test('disposed before start rejects every tags entry and draft IO', () async {
    final backend = _NoReadAfterDispose(), api = _Api();
    var writes = 0, notifications = 0;
    final owner = DiaryComposerStore(
      api: api,
      tagsStore: backend,
      writeDraft: (_, _) {
        writes++;
      },
      onPersisted: (_) {
        notifications++;
      },
    );
    final session = owner.read(day)..seed('original');
    session.updateText('retained unsaved');
    owner.dispose();
    await session.ensureTagsLoaded();
    await session.reloadTags();
    await session.flush();
    expect(await session.setTags(['no']), isFalse);
    expect(await session.retryTags(), isFalse);
    await session.publish();
    await session.discard();
    expect(backend.reads, 0);
    expect(writes, 0);
    expect(notifications, 0);
    expect(api.appends, 0);
    expect(api.otherCalls, 0);
    expect(session.text, 'retained unsaved');
    expect(session.tagsLoaded, isFalse);
  });

  test(
    'complete receipt ACK barrier keeps retired session identity until durable ACK',
    () async {
      final store = _ControlledStore(), api = _Api(), gate = Completer<void>();
      final owner = DiaryComposerStore(
        api: api,
        tagsStore: store,
        onPromoteTags: (date, id, tags) {
          store.barrier = gate;
        },
      );
      final s = owner.read(day)..seed('正文');
      await s.publish();
      await Future<void>.delayed(Duration.zero);
      expect(s.tagSnapshot.phase, DiaryDraftTagPhase.complete);
      expect(s.tagsDirty, isTrue);
      expect(s.hasPendingReceipt, isTrue);
      expect(owner.read(day), same(s));
      expect(api.appends, 1);
      gate.complete();
      await s.retryMetadata();
      expect(s.tagsDirty, isFalse);
      expect(s.hasPendingReceipt, isFalse);
      expect(owner.read(day), isNot(same(s)));
      owner.dispose();
    },
  );
  test(
    'recovered returned ID cannot close receipt before images snapshot is known',
    () async {
      final store = MemoryDiaryDraftTagsStore(), api = _Api();
      var promotions = 0;
      await store.put(
        DiaryDraftTagSnapshot(
          date: day,
          generation: 'recover',
          revision: 1,
          phase: DiaryDraftTagPhase.returnedId,
          intent: 'recover-1',
          entryId: 77,
        ),
        expectedRevision: null,
      );
      final owner = DiaryComposerStore(
        api: api,
        tagsStore: store,
        onPromoteTags: (date, id, tags) {
          promotions++;
        },
      );
      final s = owner.read(day);
      await s.ensureTagsLoaded();
      await s.retryMetadata();
      expect(store.values[day]!.phase, DiaryDraftTagPhase.returnedId);
      expect(owner.read(day), same(s));
      expect(s.metadataError, isNotNull);
      expect(api.appends, 0);
      s.seedImages(
        const CalendarData(
          images: {
            day: ['unlinked'],
          },
          entryImages: {
            77: ['already-linked'],
          },
          diaryDays: {},
          entries: [],
        ),
      );
      await s.publish();
      await s.retryMetadata();
      expect(api.linked, [('unlinked', 77)]);
      expect(api.appends, 0);
      expect(promotions, 1);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
      owner.dispose();
    },
  );

  test(
    'returned ID receipt write failure is independent and same session retry no append',
    () async {
      final store = _ControlledStore(), api = _Api();
      api.onAppend = () => store.fail = true;
      var metadataWrites = 0;
      final owner = DiaryComposerStore(
        api: api,
        tagsStore: store,
        onPromoteTags: (date, id, tags) {
          metadataWrites++;
          expect((date, id), (day, 42));
          expect(tags, ['frozen']);
        },
      );
      final s = owner.read(day)..seed('原范围原正文');
      await s.setTags(['frozen']);
      await s.publish();
      await s.retryMetadata();
      expect(api.appends, 1);
      expect(s.publishedEntryId, 42);
      expect(s.retired, isTrue);
      expect(s.metadataError, isNotNull);
      expect(metadataWrites, 0);
      expect(owner.read(day), same(s));
      expect(store.values[day]!.phase, DiaryDraftTagPhase.publishPending);
      final recovered = _session(api, store);
      await recovered.ensureTagsLoaded();
      await expectLater(recovered.publish(), throwsStateError);
      expect(api.appends, 1);
      store.fail = false;
      api.onAppend = null;
      await s.retryMetadata();
      expect(metadataWrites, 1);
      expect(api.appends, 1);
      expect(store.values[day]!.entryId, 42);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
      final next = owner.read(day);
      expect(next, isNot(same(s)));
      expect(next.token, isNot(same(s.token)));
      await next.ensureTagsLoaded();
      expect(next.tagsDirty, isFalse);
      expect(next.tags, isEmpty);
      expect(await next.setTags(['新意图']), isTrue);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.draft);
      expect(store.values[day]!.generation, isNot(s.tagSnapshot.generation));
      owner.dispose();
    },
  );
  test(
    'metadata ACK then complete-receipt fail retries receipt only despite later user edit',
    () async {
      final store = _ControlledStore(), api = _Api();
      var writes = 0;
      final s = _session(
        api,
        store,
        promote: (date, id, tags) {
          writes++;
          store.fail = true;
        },
      );
      await s.setTags(['原']);
      await s.publish();
      await s.retryMetadata();
      expect(writes, 1);
      expect(s.tagsDirty, isTrue);
      expect(api.appends, 1);
      // A later user edit is not a reason to repeat an already ACKed promotion.
      store.fail = false;
      await s.retryMetadata();
      expect(writes, 1);
      expect(api.appends, 1);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
    },
  );
  test(
    'clean higher revision cannot be rolled back by an older reload',
    () async {
      final store = _ControlledStore(), s = _session(_Api(), store);
      await s.setTags(['current']);
      for (var i = 0; i < 4; i++) await s.setTags(['current-' + i.toString()]);
      final current = store.values[day]!;
      store.forcedRead = DiaryDraftTagLoad(
        DiaryDraftTagLoadStatus.loaded,
        value: current.copyWith(revision: 3, tags: ['old']),
      );
      await s.reloadTags();
      expect(s.tagSnapshot.revision, 5);
      expect(s.tags, current.tags);
      expect(s.tagsBlocked, isTrue);
    },
  );
  test(
    'unknown .tmp is not silently treated as this writer artifact',
    () async {
      final root = await _fixture(), dir = Directory(_path(root, ''));
      await dir.create();
      final file = File(_path(root, 'unknown.tmp'));
      await file.writeAsString('unknown durable bytes', flush: true);
      final store = FileDiaryDraftTagsStore(directory: () => root);
      expect((await store.load(day)).blocked, isTrue);
      await expectLater(
        store.put(
          DiaryDraftTagSnapshot(date: day, generation: 'new', revision: 1),
          expectedRevision: null,
        ),
        throwsA(isA<DiaryMetadataConflict>()),
      );
      expect(await file.readAsString(), 'unknown durable bytes');
    },
  );

  test(
    'legacy constructors independent editable memory, zero file defaults',
    () async {
      final api = _Api(),
          a = DiaryComposerStore(api: _Api()),
          b = DiaryComposerStore(api: api);
      expect(a.tagsStore, isA<MemoryDiaryDraftTagsStore>());
      expect(identical(a.tagsStore, b.tagsStore), isFalse);
      expect(await a.read(day).setTags(['一', '二']), isTrue);
      await b.read(day).ensureTagsLoaded();
      expect(a.read(day).tags, ['一', '二']);
      expect(b.read(day).tags, isEmpty);
      a.dispose();
      b.dispose();
      expect(api.otherCalls, 0);
    },
  );
  test('production provider creation leaves private path trap at zero', () {
    var paths = 0;
    final file = FileDiaryDraftTagsStore(
      directory: () {
        paths++;
        throw StateError('Forbidden private');
      },
    );
    final c = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(_Api()),
        diaryDraftTagsStoreProvider.overrideWithValue(file),
        diaryEntryMetadataStoreProvider.overrideWithValue(
          MemoryDiaryMetadataStore(),
        ),
      ],
    );
    expect(c.read(diaryComposerStoreProvider).tagsStore, same(file));
    c.read(diaryComposerStoreProvider).read(day);
    expect(paths, 0);
    c.dispose();
    expect(paths, 0);
  });
  test(
    'ordered tags immutable, trim duplicate and 8x20 runes/control guard',
    () async {
      final s = _session(_Api(), MemoryDiaryDraftTagsStore());
      expect(await s.setTags([' 二 ', '一', '二', '😀' * 20]), isTrue);
      expect(s.tags, ['二', '一', '😀' * 20]);
      expect(() => normalizedDiaryTags(['😀' * 21]), throwsFormatException);
      expect(() => normalizedDiaryTags(['x\nx']), throwsFormatException);
      expect(
        () => normalizedDiaryTags(List.generate(9, (i) => '$i')),
        throwsFormatException,
      );
      expect(() => s.tags.add('bad'), throwsUnsupportedError);
    },
  );
  test(
    'pending verified ACK barrier API0 and repeated click one flight',
    () async {
      final store = _ControlledStore()..barrier = Completer<void>(),
          api = _Api();
      final s = _session(api, store), run = s.publish();
      await Future<void>.delayed(Duration.zero);
      expect(api.appends, 0);
      expect(store.attempted.single.phase, DiaryDraftTagPhase.publishPending);
      await s.publish();
      expect(api.appends, 0);
      store.barrier!.complete();
      await run;
      await s.retryMetadata();
      expect(api.appends, 1);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
      expect(store.values[day]!.entryId, 42);
    },
  );
  for (final lostAck in [false, true]) {
    test(
      'intent write/verify failure until same-process ACK retry $lostAck',
      () async {
        final store = _ControlledStore()
              ..fail = !lostAck
              ..loseAck = lostAck,
            api = _Api();
        final s = _session(api, store);
        await expectLater(s.publish(), throwsStateError);
        expect(api.appends, 0);
        expect(s.text, '原日期正文');
        expect(s.tagsDirty, isTrue);
        store.fail = false;
        await s.publish();
        await s.retryMetadata();
        expect(api.appends, 1);
        expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
      },
    );
  }
  for (final invalid in [false, true]) {
    test(
      'append then lost/invalid ID no reappend even discard/reopen $invalid',
      () async {
        final store = MemoryDiaryDraftTagsStore(),
            api = _Api()
              ..loseId = !invalid
              ..invalidId = invalid;
        final owner = DiaryComposerStore(api: api, tagsStore: store),
            s = owner.read(day)..seed('不会复制再发表');
        await s.setTags(['原标签']);
        await expectLater(s.publish(), throwsStateError);
        expect(api.appends, 1);
        expect(store.values[day]!.phase, DiaryDraftTagPhase.publishPending);
        await expectLater(s.publish(), throwsStateError);
        await s.discard();
        expect(s.retired, isFalse);
        owner.dispose();
        final restored = _session(api, store);
        await restored.ensureTagsLoaded();
        expect(restored.tags, ['原标签']);
        expect(restored.tagsBlocked, isTrue);
        await expectLater(restored.publish(), throwsStateError);
        expect(api.appends, 1);
      },
    );
  }
  test(
    'crash after durable intent ACK before API blocks fresh scope',
    () async {
      final store = MemoryDiaryDraftTagsStore();
      await store.put(
        DiaryDraftTagSnapshot(
          date: day,
          generation: 'crash',
          revision: 1,
          tags: ['已确认'],
          phase: DiaryDraftTagPhase.publishPending,
          intent: 'intent',
        ),
        expectedRevision: null,
      );
      final api = _Api(), s = _session(api, store);
      await s.ensureTagsLoaded();
      expect(s.publishUnknown, isTrue);
      await expectLater(s.publish(), throwsStateError);
      expect(api.appends, 0);
    },
  );
  test(
    'partial images receipt failure retry only original ID/remaining paths',
    () async {
      final store = _ControlledStore(), api = _Api()..failImage = 'image-b';
      var promotions = 0;
      final owner = DiaryComposerStore(
        api: api,
        tagsStore: store,
        onPromoteTags: (date, id, tags) {
          promotions++;
          expect((date, id), (day, 42));
          expect(tags, ['ordered']);
        },
      );
      final s = owner.read(day)..seed('原文');
      await s.setTags(['ordered']);
      s.staged.addAll(['image-a', 'image-b']);
      await expectLater(s.publish(), throwsStateError);
      await s.retryMetadata();
      expect(api.appends, 1);
      expect(api.linked, [('image-a', 42)]);
      expect(owner.read(day), same(s));
      store.fail = true;
      api.failImage = null;
      await s.publish();
      await s.retryMetadata();
      expect(api.appends, 1);
      expect(api.linked, [('image-a', 42), ('image-b', 42)]);
      expect(s.tagsDirty, isTrue);
      store.fail = false;
      await s.retryMetadata();
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
      expect(api.appends, 1);
      expect(promotions, greaterThanOrEqualTo(1));
      owner.dispose();
    },
  );
  test(
    'returned receipt restores original ID/date and no body append',
    () async {
      final store = MemoryDiaryDraftTagsStore(), api = _Api();
      await store.put(
        DiaryDraftTagSnapshot(
          date: day,
          generation: 'receipt',
          revision: 2,
          phase: DiaryDraftTagPhase.returnedId,
          intent: 'receipt-1',
          entryId: 91,
          tags: ['恢复'],
        ),
        expectedRevision: null,
      );
      final s = _session(
        api,
        store,
        promote: (date, id, tags) {
          expect((date, id), (day, 91));
          expect(tags, ['恢复']);
        },
      );
      await s.ensureTagsLoaded();
      expect(s.retired, isTrue);
      s.seedImages(
        const CalendarData(
          images: {},
          entryImages: {},
          diaryDays: {},
          entries: [],
        ),
      );
      await s.retryMetadata();
      await s.publish();
      expect(api.appends, 0);
      expect(store.values[day]!.entryId, 91);
      expect(store.values[day]!.phase, DiaryDraftTagPhase.complete);
    },
  );
  test('same ID retry preserves later user source/tags revision', () async {
    final metadata = MemoryDiaryMetadataStore(), key = DiaryEntryKey(day, 42);
    final c = ProviderContainer(
      overrides: [diaryEntryMetadataStoreProvider.overrideWithValue(metadata)],
    );
    final n = c.read(diaryEntryMetadataProvider(key).notifier);
    expect(await n.promoteHandwrittenTags(['原标签']), isTrue);
    expect(await n.setTags(['用户新改']), isTrue);
    expect(await n.promoteHandwrittenTags(['原标签']), isFalse);
    expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['用户新改']);
    expect(
      c.read(diaryEntryMetadataProvider(key)).value.source,
      DiaryEntrySource.handwritten,
    );
    c.dispose();
  });
  test(
    'existing unknown source with user tags cannot be claimed by delayed promotion',
    () async {
      final metadata = MemoryDiaryMetadataStore(), key = DiaryEntryKey(day, 42);
      final c = ProviderContainer(
        overrides: [
          diaryEntryMetadataStoreProvider.overrideWithValue(metadata),
        ],
      );
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      expect(await n.setTags(['独立编辑']), isTrue);
      expect(await n.promoteHandwrittenTags(['草稿']), isFalse);
      expect(
        c.read(diaryEntryMetadataProvider(key)).value.source,
        DiaryEntrySource.unknown,
      );
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['独立编辑']);
      c.dispose();
    },
  );
  test(
    'dirty reload external tags stays conflict without local overwrite',
    () async {
      final store = _ControlledStore(), s = _session(_Api(), store);
      await s.setTags(['base']);
      store.fail = true;
      expect(await s.setTags(['local']), isFalse);
      store.values[day] = store.values[day]!.copyWith(
        revision: 5,
        tags: ['external'],
      );
      await s.reloadTags();
      expect(s.tags, ['local']);
      expect(s.tagsBlocked, isTrue);
      store.fail = false;
      expect(await s.retryTags(), isFalse);
      expect(store.values[day]!.tags, ['external']);
    },
  );
  test('late read old base cannot regress latest acknowledged tags', () async {
    final store = _LateStore(), s = _session(_Api(), store);
    await s.setTags(['一']);
    final old = store.values[day]!;
    store.read = Completer<DiaryDraftTagLoad>();
    final reload = s.reloadTags();
    // Already loaded: the new tag edit does not wait on the explicit reload.
    await s.setTags(['二']);
    store.read!.complete(
      DiaryDraftTagLoad(DiaryDraftTagLoadStatus.loaded, value: old),
    );
    await reload;
    expect(s.tags, ['二']);
    expect(s.tagSnapshot.revision, 2);
    expect(s.tagsBlocked, isFalse);
  });
  test('disposed late load never seeds or invokes API', () async {
    final store = _LateStore()..read = Completer<DiaryDraftTagLoad>(),
        api = _Api();
    final owner = DiaryComposerStore(api: api, tagsStore: store),
        s = owner.read(day);
    final read = s.ensureTagsLoaded();
    owner.dispose();
    store.read!.complete(
      DiaryDraftTagLoad(
        DiaryDraftTagLoadStatus.loaded,
        value: DiaryDraftTagSnapshot(
          date: day,
          generation: 'external',
          revision: 5,
          tags: ['later'],
        ),
      ),
    );
    await read;
    expect(s.tags, isEmpty);
    expect(s.tagsLoaded, isFalse);
    expect(await s.setTags(['no']), isFalse);
    expect(api.appends, 0);
  });
  test(
    'read fail/future blocks API, explicit valid reread restores only draft',
    () async {
      final store = _ControlledStore()..throwRead = true,
          api = _Api(),
          s = _session(api, store);
      await s.ensureTagsLoaded();
      expect(s.tagsBlocked, isTrue);
      await expectLater(s.publish(), throwsStateError);
      expect(api.appends, 0);
      store.throwRead = false;
      await s.reloadTags();
      expect(s.canEditTags, isTrue);
      store.forcedRead = const DiaryDraftTagLoad(
        DiaryDraftTagLoadStatus.future,
      );
      await s.reloadTags();
      expect(s.tagsBlocked, isTrue);
      await expectLater(s.publish(), throwsStateError);
      expect(api.appends, 0);
    },
  );
  test(
    'discard failure keeps text/tags and tombstone ACK then resets new generation',
    () async {
      final store = _ControlledStore(), api = _Api()..failDiscard = true;
      final owner = DiaryComposerStore(api: api, tagsStore: store),
          s = owner.read(day)..seed('保留');
      await s.setTags(['保留标签']);
      await expectLater(s.discard(), throwsStateError);
      expect(s.text, '保留');
      expect(s.tags, ['保留标签']);
      expect(s.retired, isFalse);
      api.failDiscard = false;
      store.fail = true;
      await expectLater(s.discard(), throwsStateError);
      expect(s.retired, isFalse);
      store.fail = false;
      await s.discard();
      expect(s.retired, isTrue);
      final next = owner.read(day);
      await next.ensureTagsLoaded();
      expect(next.tags, isEmpty);
      expect(next.tagsDirty, isFalse);
      expect(await next.setTags(['新草稿']), isTrue);
      expect(api.appends, 0);
      owner.dispose();
    },
  );
  test('strict codec date/canonical tags/unknown/future guards', () {
    final value = DiaryDraftTagSnapshot(
      date: '2028-02-29',
      generation: 'test',
      tags: ['a'],
    );
    expect(DiaryDraftTagSnapshot.fromJson(value.toJson()).date, '2028-02-29');
    expect(
      () => DiaryDraftTagSnapshot(date: '2026-02-31', generation: 'test'),
      throwsFormatException,
    );
    expect(
      () => DiaryDraftTagSnapshot.fromJson({...value.toJson(), 'extra': true}),
      throwsFormatException,
    );
    expect(
      () => DiaryDraftTagSnapshot.fromJson({
        ...value.toJson(),
        'schemaVersion': 2,
      }),
      throwsA(isA<DiaryMetadataFuture>()),
    );
  });
  test(
    'file immutable history reopen, exact ACK retry, same revision different content rejected',
    () async {
      final root = await _fixture(),
          store = FileDiaryDraftTagsStore(directory: () => root);
      final value = DiaryDraftTagSnapshot(
        date: day,
        generation: 'file',
        revision: 1,
        tags: ['a', 'b'],
      );
      await store.put(value, expectedRevision: null);
      final reopened = FileDiaryDraftTagsStore(directory: () => root);
      expect((await reopened.load(day)).value!.tags, ['a', 'b']);
      await reopened.put(value, expectedRevision: null);
      await expectLater(
        reopened.put(value.copyWith(tags: ['different']), expectedRevision: 1),
        throwsA(isA<DiaryMetadataConflict>()),
      );
      await reopened.put(
        value.copyWith(
          revision: 2,
          phase: DiaryDraftTagPhase.returnedId,
          intent: 'file-1',
          entryId: 81,
        ),
        expectedRevision: 1,
      );
      expect(
        (await FileDiaryDraftTagsStore(
          directory: () => root,
        ).load(day)).value!.entryId,
        81,
      );
    },
  );
  test(
    'two file store same/different revision expected-base competitors never clobber',
    () async {
      for (final nextRevision in [1, 2]) {
        final root = await _fixture(),
            a = FileDiaryDraftTagsStore(directory: () => root),
            b = FileDiaryDraftTagsStore(directory: () => root);
        final first = DiaryDraftTagSnapshot(
          date: day,
          generation: 'a',
          revision: 1,
          tags: ['one'],
        );
        final second = DiaryDraftTagSnapshot(
          date: day,
          generation: 'b',
          revision: nextRevision,
          tags: ['two'],
        );
        final results = await Future.wait([
          a
              .put(first, expectedRevision: null)
              .then((_) => true, onError: (_) => false),
          b
              .put(second, expectedRevision: null)
              .then((_) => true, onError: (_) => false),
        ]);
        expect(results.where((v) => v).length, 1);
        final committed = (await a.load(day)).value!;
        expect(committed.tags, results[0] ? ['one'] : ['two']);
        final file = File(
              _path(root, 'tags-r' + committed.revision.toString() + '.json'),
            ),
            bytes = await file.readAsString();
        await expectLater(
          (results[0] ? b : a).put(
            results[0] ? second : first,
            expectedRevision: null,
          ),
          throwsA(isA<DiaryMetadataConflict>()),
        );
        expect(await file.readAsString(), bytes);
      }
    },
  );
  test(
    'file lost verify exact retry creates no replacement/revision',
    () async {
      final root = await _fixture(),
          backend = _LostVerifyBackend(),
          store = FileDiaryDraftTagsStore(
            directory: () => root,
            backend: backend,
          );
      final value = DiaryDraftTagSnapshot(
        date: day,
        generation: 'verify',
        revision: 1,
        tags: ['durable'],
      );
      await expectLater(
        store.put(value, expectedRevision: null),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await FileDiaryDraftTagsStore(
          directory: () => root,
        ).load(day)).value!.tags,
        ['durable'],
      );
      await store.put(value, expectedRevision: null);
      final files = await Directory(_path(root, '')).list().toList();
      expect(files.where((e) => e.path.endsWith('.json')).length, 1);
    },
  );
  for (final kind in ['future', 'corrupt', 'unknown']) {
    test('file $kind retained read-only, zero new intent/API', () async {
      final root = await _fixture(), dir = Directory(_path(root, ''));
      await dir.create();
      final file = File(
        _path(root, kind == 'unknown' ? 'unexpected.json' : 'tags-r1.json'),
      );
      final bytes = kind == 'future'
          ? jsonEncode({
              ...DiaryDraftTagSnapshot(
                date: day,
                generation: 'future',
                revision: 1,
              ).toJson(),
              'schemaVersion': 9,
            })
          : 'not-json';
      await file.writeAsString(bytes, flush: true);
      final store = FileDiaryDraftTagsStore(directory: () => root),
          api = _Api(),
          s = _session(api, store);
      await s.ensureTagsLoaded();
      expect(s.tagsBlocked, isTrue);
      await expectLater(s.publish(), throwsStateError);
      expect(api.appends, 0);
      expect(await file.readAsString(), bytes);
    });
  }
}
