import 'dart:async';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/browsing/data/diary_candidate_repository.dart';
import 'package:timetrace_app/src/features/browsing/domain/diary_candidate.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_entry_metadata_store.dart';
import 'package:timetrace_app/src/features/dashboard/domain/diary_entry_metadata.dart';
import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_entry_metadata_controls.dart';

/// All tests using this fixture replace the entire private backend, not only its path.
class MemoryDiaryMetadataStore implements DiaryEntryMetadataStore {
  final values = <DiaryEntryKey, DiaryEntryMetadata>{};
  int reads = 0, writes = 0, unexpected = 0;
  bool failWrite = false, failRead = false, failVerification = false;
  DiaryMetadataLoadStatus? blocked;
  Future<DiaryMetadataLoad> Function(DiaryEntryKey)? pendingLoad;
  Future<void> Function(DiaryEntryMetadata)? pendingWrite;
  @override
  Future<DiaryMetadataLoad> load(DiaryEntryKey key) async {
    reads++;
    if (failRead) throw StateError('synthetic read failed');
    if (pendingLoad != null) return pendingLoad!(key);
    final value = values[key];
    return DiaryMetadataLoad(
      blocked ??
          (value == null
              ? DiaryMetadataLoadStatus.missing
              : DiaryMetadataLoadStatus.loaded),
      value: value,
    );
  }

  @override
  Future<void> put(
    DiaryEntryMetadata value, {
    required int? expectedRevision,
  }) async {
    writes++;
    if (pendingWrite != null) await pendingWrite!(value);
    if (failWrite) throw StateError('synthetic write failed');
    final old = values[value.key];
    if (old?.revision == value.revision &&
        jsonEncode(old!.toJson()) == jsonEncode(value.toJson())) {
      return;
    }
    if (old?.revision != expectedRevision) throw const DiaryMetadataConflict();
    values[value.key] = DiaryEntryMetadata.fromJson(value.toJson());
    if (failVerification) throw StateError('synthetic verify failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpected++;
    throw StateError('unexpected private backend fallthrough');
  }
}

class MemoryMetadataCandidates implements DiaryCandidateRepository {
  MemoryMetadataCandidates([this.items = const []]);
  final List<DiaryCandidate> items;
  int reads = 0, unexpected = 0;
  @override
  Future<CandidateLoad> load() async {
    reads++;
    return CandidateLoad(items);
  }

  @override
  Future<void> put(DiaryCandidate candidate) async {
    unexpected++;
    throw StateError('metadata tests never save/generate candidates');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpected++;
    throw StateError('unexpected candidate fallthrough');
  }
}

class _MetadataApi implements TimeTraceApi {
  int appends = 0, imageLinks = 0, unexpected = 0;
  @override
  int publishDiary({required String date, required String content}) =>
      ++appends + 100;
  @override
  void setDiaryImageEntry({required String path, required int entryId}) {
    imageLinks++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpected++;
    throw StateError('unexpected real API fallthrough');
  }
}

DiaryCandidate candidate(
  DiaryEntryKey key,
  DiaryCandidateSource source, {
  String id = 'synthetic',
  bool broken = false,
}) => DiaryCandidate(
  id: id,
  source: source,
  startUtc: '2026-10-01T00:00:00Z',
  endUtc: '2026-10-02T00:00:00Z',
  saveDate: key.date,
  content: 'same text',
  capturedAtUtc: DateTime.utc(2026),
  generatedAtUtc: DateTime.utc(2026),
  publishStatus: CandidatePublishStatus.saved,
  entryId: key.entryId.toString(),
  persisted: true,
  recoveryBlocked: broken,
);

class _VerifyFailureBackend extends DiaryMetadataFileBackend {
  bool failVerification = false, committed = false;
  @override
  Future<void> commit(File temporary, File target) async {
    await super.commit(temporary, target);
    committed = true;
  }

  @override
  Future<String> read(File file) {
    if (committed && failVerification) {
      committed = false;
      throw const FileSystemException('synthetic verify failure');
    }
    return super.read(file);
  }
}

class _CommitGateBackend extends DiaryMetadataFileBackend {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> commit(File temporary, File target) async {
    entered.complete();
    await release.future;
    await super.commit(temporary, target);
  }
}

class _RaceTarget implements File {
  _RaceTarget(this.actual);
  final File actual;
  @override
  String get path => actual.path;
  @override
  Future<bool> exists() async {
    final captured = await actual.exists();
    await actual.writeAsString('external revision', flush: true);
    return captured;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected synthetic file operation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = DiaryEntryKey('2026-10-01', 42);
  ProviderContainer container(MemoryDiaryMetadataStore store) {
    final c = ProviderContainer(
      overrides: [
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        diaryEntryMetadataStoreProvider.overrideWithValue(store),
        diaryCandidateRepositoryProvider.overrideWithValue(
          MemoryMetadataCandidates(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('identity and bounded normalized immutable tags', () {
    for (final date in ['2026-02-30', '2026-1-01', '0000-01-01']) {
      expect(() => DiaryEntryKey(date, 42), throwsFormatException);
    }
    expect(() => DiaryEntryKey('2026-10-01', 0), throwsFormatException);
    expect(normalizedDiaryTags([' one ', 'one', '😀' * 20]), [
      'one',
      '😀' * 20,
    ]);
    for (final tags in [
      ['😀' * 21],
      ['a\nb'],
      ['a\u0000'],
      List.generate(9, (i) => '$i'),
    ]) {
      expect(() => normalizedDiaryTags(tags), throwsFormatException);
    }
    final value = DiaryEntryMetadata(key: key, tags: ['hello']);
    expect(() => value.tags.add('bad'), throwsUnsupportedError);
    expect(
      () =>
          DiaryEntryMetadata.fromJson({...value.toJson(), 'text': 'forbidden'}),
      throwsFormatException,
    );
    expect(
      () =>
          DiaryEntryMetadata.fromJson({...value.toJson(), 'schemaVersion': 2}),
      throwsA(isA<DiaryMetadataFuture>()),
    );
  });
  test(
    'source binds exact date returned ID, not same text and conflicts unknown',
    () {
      final view = DiaryEntryMetadataView(
        value: DiaryEntryMetadata(key: key),
        loaded: true,
      );
      expect(
        diaryEntrySource(key, view, [candidate(key, DiaryCandidateSource.ai)]),
        DiaryEntrySource.ai,
      );
      expect(
        diaryEntrySource(key, view, [
          candidate(key, DiaryCandidateSource.local),
        ]),
        DiaryEntrySource.local,
      );
      expect(
        diaryEntrySource(key, view, [
          candidate(DiaryEntryKey(key.date, 43), DiaryCandidateSource.ai),
        ]),
        DiaryEntrySource.unknown,
      );
      expect(
        diaryEntrySource(key, view, [
          candidate(DiaryEntryKey('2026-10-02', 42), DiaryCandidateSource.ai),
        ]),
        DiaryEntrySource.unknown,
      );
      expect(
        diaryEntrySource(key, view, [
          candidate(key, DiaryCandidateSource.ai, broken: true),
        ]),
        DiaryEntrySource.unknown,
      );
      expect(
        diaryEntrySource(key, view, [
          candidate(key, DiaryCandidateSource.ai),
          candidate(key, DiaryCandidateSource.local, id: 'other'),
        ]),
        DiaryEntrySource.unknown,
      );
      final manual = DiaryEntryMetadataView(
        value: DiaryEntryMetadata(
          key: key,
          source: DiaryEntrySource.handwritten,
        ),
        loaded: true,
      );
      expect(diaryEntrySource(key, manual, []), DiaryEntrySource.handwritten);
      expect(
        diaryEntrySource(key, manual, [
          candidate(key, DiaryCandidateSource.ai),
        ]),
        DiaryEntrySource.unknown,
      );
    },
  );
  test('manual source tags restart edit and remove preserve source', () async {
    final store = MemoryDiaryMetadataStore();
    final c = container(store);
    final n = c.read(diaryEntryMetadataProvider(key).notifier);
    expect(await n.recordHandwritten(), isTrue);
    expect(await n.setTags([' 工作 ', '工作', '记录']), isTrue);
    expect(
      c.read(diaryEntryMetadataProvider(key)).value.source,
      DiaryEntrySource.handwritten,
    );
    final other = container(store);
    final m = other.read(diaryEntryMetadataProvider(key).notifier);
    await m.ensureLoaded();
    expect(other.read(diaryEntryMetadataProvider(key)).value.tags, [
      '工作',
      '记录',
    ]);
    expect(await m.setTags([]), isTrue);
    expect(store.values[key]!.source, DiaryEntrySource.handwritten);
    expect(store.values[key]!.tags, isEmpty);
    expect(store.unexpected, 0);
  });
  test(
    'returned ID sidecar failure retry has zero extra append or image relink',
    () async {
      final api = _MetadataApi();
      final store = MemoryDiaryMetadataStore()..failWrite = true;
      final c = container(store);
      final publishedKey = DiaryEntryKey(key.date, 101);
      final n = c.read(diaryEntryMetadataProvider(publishedKey).notifier);
      final session =
          DiaryComposerStore(
              api: api,
              onPublished: (date, id) async {
                expect(date, key.date);
                expect(id, 101);
                if (!await n.recordHandwritten()) {
                  throw StateError('synthetic metadata unacknowledged');
                }
              },
            ).read(key.date)
            ..seed(null)
            ..updateText('handwritten');
      session.staged.add('synthetic-image');
      await session.publish();
      await session.retryMetadata();
      expect(session.retired, isTrue);
      expect(session.publishedEntryId, 101);
      expect(session.metadataError, isNotNull);
      expect(c.read(diaryEntryMetadataProvider(publishedKey)).dirty, isTrue);
      store.failWrite = false;
      await session.retryMetadata();
      await session.publish();
      expect(session.metadataError, isNull);
      expect(api.appends, 1);
      expect(api.imageLinks, 1);
      expect(api.unexpected, 0);
    },
  );
  test(
    'metadata acknowledgement lost retries identical revision, no new source',
    () async {
      final store = MemoryDiaryMetadataStore()..failVerification = true;
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      expect(await n.recordHandwritten(), isFalse);
      final revision = c.read(diaryEntryMetadataProvider(key)).value.revision;
      store.failVerification = false;
      expect(await n.recordHandwritten(), isTrue);
      expect(c.read(diaryEntryMetadataProvider(key)).value.revision, revision);
      expect(store.values[key]!.source, DiaryEntrySource.handwritten);
    },
  );
  for (final status in [
    DiaryMetadataLoadStatus.future,
    DiaryMetadataLoadStatus.unreadable,
    DiaryMetadataLoadStatus.conflict,
  ]) {
    test('blocked $status never treated as missing or overwritten', () async {
      final store = MemoryDiaryMetadataStore()
        ..values[key] = DiaryEntryMetadata(
          key: key,
          revision: 4,
          tags: ['retained'],
        )
        ..blocked = status;
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      await n.ensureLoaded();
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['retained']);
      expect(await n.setTags(['new']), isFalse);
      expect(await n.recordHandwritten(), isFalse);
      expect(store.writes, 0);
    });
  }
  test(
    'read error is blocked and retry preserves dirty current intent',
    () async {
      final store = MemoryDiaryMetadataStore();
      final c = container(store), n = container(store);
      final writer = c.read(diaryEntryMetadataProvider(key).notifier);
      store.failWrite = true;
      await writer.setTags(['local']);
      store.failRead = true;
      await writer.reload();
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['local']);
      expect(c.read(diaryEntryMetadataProvider(key)).blocked, isTrue);
      store.failRead = false;
      store.failWrite = false;
      await writer.reload();
      expect(await writer.retrySave(), isTrue);
      expect(store.values[key]!.tags, ['local']);
      expect(n.read(diaryEntryMetadataProvider(key)).value.key, key);
    },
  );
  test('old write acknowledgement cannot roll newer tags back', () async {
    final store = MemoryDiaryMetadataStore();
    final gate = Completer<void>();
    var first = true;
    store.pendingWrite = (_) {
      if (first) {
        first = false;
        return gate.future;
      }
      return Future.value();
    };
    final c = container(store);
    final n = c.read(diaryEntryMetadataProvider(key).notifier);
    final one = n.setTags(['first']);
    await Future<void>.delayed(Duration.zero);
    final two = n.setTags(['second']);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['second']);
    gate.complete();
    await one;
    await two;
    expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['second']);
    expect(c.read(diaryEntryMetadataProvider(key)).dirty, isFalse);
    expect(store.values[key]!.tags, ['second']);
  });
  test('scope dispose before and during load never starts write', () async {
    final store = MemoryDiaryMetadataStore();
    final gate = Completer<DiaryMetadataLoad>();
    store.pendingLoad = (_) => gate.future;
    final c = ProviderContainer(
      overrides: [
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        diaryEntryMetadataStoreProvider.overrideWithValue(store),
      ],
    );
    final n = c.read(diaryEntryMetadataProvider(key).notifier);
    final operation = n.recordHandwritten();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    gate.complete(const DiaryMetadataLoad(DiaryMetadataLoadStatus.missing));
    expect(await operation, isFalse);
    expect(store.writes, 0);
    final before = store.reads;
    final other = ProviderContainer(
      overrides: [
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        diaryEntryMetadataStoreProvider.overrideWithValue(store),
      ],
    );
    other.read(diaryEntryMetadataProvider(key));
    other.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(store.reads, before);
  });
  test(
    'late older load cannot lower a newer durable acknowledgement',
    () async {
      final store = MemoryDiaryMetadataStore();
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      await n.setTags(['first']);
      final old = store.values[key]!;
      final gate = Completer<DiaryMetadataLoad>();
      store.pendingLoad = (_) => gate.future;
      final reading = n.reload();
      await Future<void>.delayed(Duration.zero);
      expect(await n.setTags(['second']), isTrue);
      gate.complete(
        DiaryMetadataLoad(DiaryMetadataLoadStatus.loaded, value: old),
      );
      await reading;
      store.pendingLoad = null;
      expect(await n.setTags(['third']), isTrue);
      expect(store.values[key]!.tags, ['third']);
      expect(store.values[key]!.revision, 3);
      expect(c.read(diaryEntryMetadataProvider(key)).blocked, isFalse);
    },
  );
  test('old write failure does not discard queued current tags', () async {
    final store = MemoryDiaryMetadataStore();
    final gate = Completer<void>();
    var first = true;
    store.pendingWrite = (_) {
      if (first) {
        first = false;
        return gate.future;
      }
      return Future.value();
    };
    final c = container(store);
    final n = c.read(diaryEntryMetadataProvider(key).notifier);
    final one = n.setTags(['first']);
    await Future<void>.delayed(Duration.zero);
    final two = n.setTags(['second']);
    await Future<void>.delayed(Duration.zero);
    gate.completeError(StateError('synthetic first write failure'));
    await one;
    expect(await two, isTrue);
    expect(store.values[key]!.tags, ['second']);
    expect(store.values[key]!.revision, 2);
    expect(c.read(diaryEntryMetadataProvider(key)).dirty, isFalse);
  });
  test(
    'dirty reload never rebases local revision3 onto external revision2',
    () async {
      final store = MemoryDiaryMetadataStore()
        ..values[key] = DiaryEntryMetadata(
          key: key,
          revision: 1,
          tags: ['base'],
        );
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      await n.ensureLoaded();
      store.failWrite = true;
      await n.setTags(['local first']);
      await n.setTags(['local second']);
      store.values[key] = DiaryEntryMetadata(
        key: key,
        revision: 2,
        tags: ['external'],
      );
      store.failWrite = false;
      expect(await n.retrySave(), isFalse);
      await n.reload();
      expect(await n.retrySave(), isFalse);
      expect(store.values[key]!.tags, ['external']);
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, [
        'local second',
      ]);
      expect(c.read(diaryEntryMetadataProvider(key)).blocked, isTrue);
    },
  );
  test(
    'same confirmed revision with different contents remains conflict',
    () async {
      final store = MemoryDiaryMetadataStore()
        ..values[key] = DiaryEntryMetadata(
          key: key,
          revision: 1,
          tags: ['base'],
        );
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      await n.ensureLoaded();
      store.failWrite = true;
      await n.setTags(['local']);
      store.values[key] = DiaryEntryMetadata(
        key: key,
        revision: 1,
        tags: ['external'],
      );
      store.failWrite = false;
      await n.reload();
      final writes = store.writes;
      expect(await n.retrySave(), isFalse);
      expect(store.writes, writes);
      expect(store.values[key]!.tags, ['external']);
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, ['local']);
    },
  );
  test(
    'exact own lost-verification receipt safely keeps newer local intent',
    () async {
      final store = MemoryDiaryMetadataStore()
        ..values[key] = DiaryEntryMetadata(
          key: key,
          revision: 1,
          tags: ['base'],
        )
        ..failVerification = true;
      final c = container(store);
      final n = c.read(diaryEntryMetadataProvider(key).notifier);
      expect(await n.setTags(['first committed']), isFalse);
      store.failVerification = false;
      expect(await n.setTags(['new intent']), isFalse);
      expect(c.read(diaryEntryMetadataProvider(key)).blocked, isTrue);
      await n.reload();
      expect(c.read(diaryEntryMetadataProvider(key)).value.tags, [
        'new intent',
      ]);
      expect(c.read(diaryEntryMetadataProvider(key)).dirty, isTrue);
      expect(await n.retrySave(), isTrue);
      expect(store.values[key]!.tags, ['new intent']);
      expect(store.values[key]!.revision, 3);
    },
  );
  for (final competingRevision in [1, 2]) {
    test(
      'independent stores expected-base race revision$competingRevision preserves winner',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'timetrace-metadata-two-writers-',
        );
        final absolute = dir.absolute.path;
        addTearDown(() async {
          expect(dir.absolute.path, absolute);
          expect(
            absolute.startsWith(Directory.systemTemp.absolute.path),
            isTrue,
          );
          await dir.delete(recursive: true);
        });
        final gate = _CommitGateBackend();
        final first = FileDiaryEntryMetadataStore(
          directory: () => dir,
          backend: gate,
        );
        final second = FileDiaryEntryMetadataStore(directory: () => dir);
        final one = DiaryEntryMetadata(
          key: key,
          revision: 1,
          source: DiaryEntrySource.handwritten,
          tags: ['winner'],
        );
        final two = DiaryEntryMetadata(
          key: key,
          revision: competingRevision,
          source: DiaryEntrySource.ai,
          tags: ['loser'],
        );
        final writing = first.put(one, expectedRevision: null);
        await gate.entered.future;
        Object? rejected;
        var secondDone = false;
        final competing = second
            .put(two, expectedRevision: null)
            .then<void>(
              (_) {
                secondDone = true;
              },
              onError: (Object error) {
                rejected = error;
                secondDone = true;
              },
            );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          secondDone,
          isFalse,
          reason: 'another writer must wait for the held entry lock',
        );
        gate.release.complete();
        await writing;
        await competing;
        expect(rejected, isA<DiaryMetadataConflict>());
        final fresh = FileDiaryEntryMetadataStore(directory: () => dir);
        final result = await fresh.load(key);
        expect(result.status, DiaryMetadataLoadStatus.loaded);
        expect(result.value!.toJson(), one.toJson());
        final path =
            '${dir.path}${Platform.pathSeparator}${key.date}${Platform.pathSeparator}${key.entryId}${Platform.pathSeparator}metadata-r1.json';
        final bytes = await File(path).readAsString();
        await expectLater(
          second.put(one.copyWith(tags: ['different']), expectedRevision: 1),
          throwsA(isA<DiaryMetadataConflict>()),
        );
        expect(await File(path).readAsString(), bytes);
      },
    );
  }
  test(
    'default no-replace commit preserves target created after sample',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'timetrace-metadata-native-race-',
      );
      final absolute = dir.absolute.path;
      addTearDown(() async {
        expect(dir.absolute.path, absolute);
        expect(absolute.startsWith(Directory.systemTemp.absolute.path), isTrue);
        await dir.delete(recursive: true);
      });
      final tmp = File('${dir.path}${Platform.pathSeparator}local.tmp');
      final target = File(
        '${dir.path}${Platform.pathSeparator}metadata-r1.json',
      );
      await tmp.writeAsString('local revision', flush: true);
      await expectLater(
        const DiaryMetadataFileBackend().commit(tmp, _RaceTarget(target)),
        throwsA(isA<DiaryMetadataConflict>()),
      );
      expect(await target.readAsString(), 'external revision');
      expect(await tmp.readAsString(), 'local revision');
    },
  );
  test(
    'default composer records exact returned identity and retries only sidecar',
    () async {
      final api = _MetadataApi();
      final store = MemoryDiaryMetadataStore()..failWrite = true;
      final repo = MemoryMetadataCandidates();
      final c = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          apiProvider.overrideWithValue(api),
          diaryEntryMetadataStoreProvider.overrideWithValue(store),
          diaryCandidateRepositoryProvider.overrideWithValue(repo),
        ],
      );
      final session = c.read(diaryComposerStoreProvider).read(key.date)
        ..seed(null)
        ..updateText('controlled handwritten');
      await session.publish();
      await session.retryMetadata();
      expect(session.publishedEntryId, 101);
      expect(session.metadataError, isNotNull);
      expect(store.values, isEmpty);
      store.failWrite = false;
      await session.retryMetadata();
      await session.publish();
      expect(session.metadataError, isNull);
      expect(
        store.values[DiaryEntryKey(key.date, 101)]!.source,
        DiaryEntrySource.handwritten,
      );
      expect(api.appends, 1);
      expect(api.imageLinks, 0);
      c.dispose();
      final reads = store.reads;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(store.reads, reads);
      expect(api.unexpected, 0);
      expect(store.unexpected, 0);
      expect(repo.unexpected, 0);
    },
  );
  test(
    'temporary immutable store strict history conflict future corruption and failed verify',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'timetrace-metadata-synthetic-',
      );
      final absolute = dir.absolute.path;
      addTearDown(() async {
        expect(dir.absolute.path, absolute);
        expect(
          dir.absolute.path.startsWith(Directory.systemTemp.absolute.path),
          isTrue,
        );
        await dir.delete(recursive: true);
      });
      final backend = _VerifyFailureBackend();
      final store = FileDiaryEntryMetadataStore(
        directory: () => dir,
        backend: backend,
      );
      final v1 = DiaryEntryMetadata(
        key: key,
        revision: 1,
        source: DiaryEntrySource.handwritten,
        tags: ['saved'],
      );
      expect((await store.load(key)).status, DiaryMetadataLoadStatus.missing);
      backend.failVerification = true;
      await expectLater(
        store.put(v1, expectedRevision: null),
        throwsA(isA<FileSystemException>()),
      );
      backend.failVerification = false;
      await store.put(v1, expectedRevision: null);
      expect((await store.load(key)).value!.tags, ['saved']);
      final freshStore = FileDiaryEntryMetadataStore(directory: () => dir);
      expect((await freshStore.load(key)).value!.tags, ['saved']);
      expect(
        (await freshStore.load(key)).value!.source,
        DiaryEntrySource.handwritten,
      );
      final path =
          '${dir.path}${Platform.pathSeparator}${key.date}${Platform.pathSeparator}${key.entryId}';
      final original = await File(
        '$path${Platform.pathSeparator}metadata-r1.json',
      ).readAsString();
      await expectLater(
        store.put(v1.copyWith(tags: ['other']), expectedRevision: 1),
        throwsA(isA<DiaryMetadataConflict>()),
      );
      expect(
        await File(
          '$path${Platform.pathSeparator}metadata-r1.json',
        ).readAsString(),
        original,
      );
      await File(
        '$path${Platform.pathSeparator}metadata-r2.json',
      ).writeAsString(
        jsonEncode({...v1.toJson(), 'revision': 2, 'schemaVersion': 2}),
        flush: true,
      );
      final blocked = await store.load(key);
      expect(blocked.status, DiaryMetadataLoadStatus.future);
      expect(blocked.value!.tags, ['saved']);
      await expectLater(
        store.put(v1.copyWith(revision: 3), expectedRevision: 1),
        throwsA(isA<DiaryMetadataConflict>()),
      );
      await File(
        '$path${Platform.pathSeparator}metadata-r2.json',
      ).writeAsString('{broken', flush: true);
      expect(
        (await store.load(key)).status,
        DiaryMetadataLoadStatus.unreadable,
      );
      expect(
        await File(
          '$path${Platform.pathSeparator}metadata-r1.json',
        ).readAsString(),
        original,
      );
    },
  );
  testWidgets(
    'tag panel failed storage keeps entered text and retry only metadata',
    (tester) async {
      final store = MemoryDiaryMetadataStore()..failWrite = true;
      final repo = MemoryMetadataCandidates();
      final c = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          diaryEntryMetadataStoreProvider.overrideWithValue(store),
          diaryCandidateRepositoryProvider.overrideWithValue(repo),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(body: DiaryEntryMetadataEditor(entryKey: key)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final input = find.byKey(const Key('diary_metadata_tags_input'));
      await tester.enterText(input, '工作, 学习');
      await tester.tap(find.byKey(const Key('diary_metadata_save')));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '工作, 学习');
      expect(find.byKey(const Key('diary_metadata_error')), findsOneWidget);
      expect(store.values, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump();
      expect(store.unexpected, 0);
      expect(repo.unexpected, 0);
    },
  );
}
