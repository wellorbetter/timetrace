import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/time_tools/domain/time_tool_state.dart';
import 'package:timetrace_app/src/features/time_tools/data/time_tools_store.dart';
import 'package:timetrace_app/src/features/time_tools/providers/time_tools_provider.dart';

class MemoryTimeStore implements TimeToolsStore {
  TimeToolsState? saved;
  TimeToolsLoad? result;
  Completer<TimeToolsLoad>? pendingLoad;
  final pendingWrites = <Completer<void>>[];
  final writes = <TimeToolsState>[];
  bool failRead = false, failWrite = false, holdWrites = false;
  int reads = 0;
  @override
  Future<TimeToolsLoad> load() async {
    reads++;
    if (failRead) throw StateError('synthetic read failure');
    if (pendingLoad != null) return pendingLoad!.future;
    return result ?? TimeToolsLoad(value: saved);
  }

  @override
  Future<void> put(
    TimeToolsState state, {
    TimeToolsState? expectedBase,
    bool checkBase = false,
  }) async {
    writes.add(state);
    if (failWrite) throw StateError('synthetic write failure');
    if (holdWrites) {
      final pending = Completer<void>();
      pendingWrites.add(pending);
      await pending.future;
    }
    if (checkBase &&
        jsonEncode(saved?.toJson()) != jsonEncode(expectedBase?.toJson()) &&
        jsonEncode(saved?.toJson()) != jsonEncode(state.toJson()))
      throw StateError('Synthetic base conflict');
    saved = TimeToolsState.fromJson(state.toJson());
  }
}

class Fixture {
  Fixture({MemoryTimeStore? storage}) : store = storage ?? MemoryTimeStore() {
    container = ProviderContainer(
      overrides: [
        timeToolsStoreProvider.overrideWithValue(store),
        timeToolsClockProvider.overrideWithValue(() => now),
        timeToolsIdProvider.overrideWithValue(
          () => 'fixture-' + (++id).toString(),
        ),
      ],
    );
  }
  final MemoryTimeStore store;
  late final ProviderContainer container;
  DateTime now = DateTime.utc(2026, 10, 3, 12);
  int id = 0;
  TimeToolsNotifier get notifier => container.read(timeToolsProvider.notifier);
  TimeToolsViewState get view => container.read(timeToolsProvider);
}

Future<void> flushEvents() async {
  for (var n = 0; n < 8; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Directory> temporaryFixture() async {
  final parent = await Directory.systemTemp.resolveSymbolicLinks();
  final root = await Directory(
    parent,
  ).createTemp('timetrace-time-tools-fixture-');
  final resolved = await root.resolveSymbolicLinks();
  final name = root.uri.pathSegments.where((s) => s.isNotEmpty).last;
  if (!root.isAbsolute ||
      await root.parent.resolveSymbolicLinks() != parent ||
      !name.startsWith('timetrace-time-tools-fixture-')) {
    throw StateError('Unexpected synthetic fixture path');
  }
  addTearDown(() async {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await root.resolveSymbolicLinks() != resolved ||
        await root.parent.resolveSymbolicLinks() != parent) {
      throw StateError('Unsafe fixture cleanup');
    }
    await root.delete(recursive: true);
  });
  return root;
}

ProviderContainer fileScope(TimeToolsStore store, DateTime Function() clock) {
  final scope = ProviderContainer(
    overrides: [
      timeToolsStoreProvider.overrideWithValue(store),
      timeToolsClockProvider.overrideWithValue(clock),
      timeToolsIdProvider.overrideWithValue(() => 'file-fixture-task'),
    ],
  );
  addTearDown(scope.dispose);
  return scope;
}

/// Inject only a put failure; successful retries still use the real file codec
/// and immutable revision commit, not an in-memory persistence substitute.
class FailingFileStore implements TimeToolsStore {
  FailingFileStore(this.delegate);
  final FileTimeToolsStore delegate;
  bool failPut = false;
  final attemptedRevisions = <int>[];
  @override
  Future<TimeToolsLoad> load() => delegate.load();
  @override
  Future<void> put(
    TimeToolsState value, {
    TimeToolsState? expectedBase,
    bool checkBase = false,
  }) async {
    TimeToolsState.fromJson(value.toJson());
    attemptedRevisions.add(value.revision);
    if (failPut) throw const FileSystemException('Synthetic put failure');
    await delegate.put(value, expectedBase: expectedBase, checkBase: checkBase);
  }
}

void main() {
  TimeToolsState taskSnapshot() => TimeToolsState(
    revision: 7,
    pomodoro: const PomodoroState(remainingSeconds: 700),
    countdown: CountdownState(
      title: 'unchanged timer',
      targetUtc: DateTime.utc(2027),
    ),
    tasks: [
      const TimeTask(id: 'old', text: 'legacy null dates'),
      TimeTask(
        id: 'target',
        text: 'delete only this',
        done: true,
        createdAtUtc: DateTime.utc(2026, 9, 1),
        dueAtUtc: DateTime.utc(2026, 9, 2),
      ),
      TimeTask(
        id: 'keep',
        text: 'keep all fields',
        done: true,
        createdAtUtc: DateTime.utc(2026, 8, 1),
        dueAtUtc: DateTime.utc(2027),
      ),
    ],
  );
  test(
    'delete by ID changes only one task and one revision without clock reads',
    () async {
      final store = MemoryTimeStore()..saved = taskSnapshot();
      final c = ProviderContainer(
        overrides: [
          timeToolsStoreProvider.overrideWithValue(store),
          timeToolsClockProvider.overrideWithValue(
            () => throw StateError('delete must not read clock'),
          ),
          timeToolsIdProvider.overrideWithValue(
            () => throw StateError('delete must not allocate ID'),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      final before = c.read(timeToolsProvider).data;
      expect(n.deleteTask('target'), isTrue);
      expect(n.deleteTask('target'), isFalse);
      await n.flush();
      final expected = before.toJson()..['revision'] = 8;
      expected['tasks'] = [
        for (final t in before.tasks)
          if (t.id != 'target') t.toJson(),
      ];
      expect(c.read(timeToolsProvider).data.toJson(), expected);
      expect(store.writes, hasLength(1));
      expect(store.saved!.toJson(), expected);
      expect(c.read(timeToolsProvider).dirty, isFalse);
    },
  );
  test(
    'delete absent unloaded loading and blocked IDs never mutate or write',
    () async {
      final f = Fixture(storage: MemoryTimeStore()..saved = taskSnapshot());
      addTearDown(f.container.dispose);
      expect(f.notifier.deleteTask('target'), isFalse);
      await f.notifier.ensureLoaded();
      final before = f.view.data.toJson();
      expect(f.notifier.deleteTask('missing'), isFalse);
      f.store.pendingLoad = Completer<TimeToolsLoad>();
      final pending = f.notifier.reload();
      await flushEvents();
      expect(f.view.loading, isTrue);
      expect(f.notifier.deleteTask('target'), isFalse);
      f.store.pendingLoad!.complete(
        TimeToolsLoad(value: taskSnapshot(), blocked: true),
      );
      await pending;
      expect(f.notifier.deleteTask('target'), isFalse);
      expect(f.view.data.toJson(), before);
      expect(f.store.writes, isEmpty);
    },
  );
  test(
    'failed delete preserves dirty intent and retries same snapshot without clock',
    () async {
      final store = MemoryTimeStore()
        ..saved = taskSnapshot()
        ..failWrite = true;
      final c = ProviderContainer(
        overrides: [
          timeToolsStoreProvider.overrideWithValue(store),
          timeToolsClockProvider.overrideWithValue(
            () => throw StateError('no new timestamp'),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      expect(n.deleteTask('target'), isTrue);
      await n.flush();
      final intent = c.read(timeToolsProvider).data.toJson();
      expect(c.read(timeToolsProvider).dirty, isTrue);
      expect(c.read(timeToolsProvider).error, isNotNull);
      expect(store.saved!.tasks.map((t) => t.id), contains('target'));
      store.failWrite = false;
      await n.retrySave();
      expect(c.read(timeToolsProvider).data.toJson(), intent);
      expect(store.writes.map((s) => s.toJson()), [intent, intent]);
      final fresh = ProviderContainer(
        overrides: [
          timeToolsStoreProvider.overrideWithValue(store),
          timeToolsClockProvider.overrideWithValue(
            () => throw StateError('no default clock read'),
          ),
          timeToolsIdProvider.overrideWithValue(
            () => throw StateError('no default ID read'),
          ),
        ],
      );
      addTearDown(fresh.dispose);
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      expect(fresh.read(timeToolsProvider).data.toJson(), intent);
      expect(fresh.read(timeToolsProvider).dirty, isFalse);
    },
  );
  test(
    'old pending ACK and lower late load cannot resurrect deleted task',
    () async {
      final f = Fixture(storage: MemoryTimeStore()..saved = taskSnapshot());
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      f.store.holdWrites = true;
      expect(f.notifier.editTask('old', 'keep this edit'), isTrue);
      await flushEvents();
      expect(f.notifier.deleteTask('target'), isTrue);
      final intent = f.view.data.toJson();
      f.store.pendingWrites.first.complete();
      await flushEvents();
      expect(f.view.data.toJson(), intent);
      expect(f.view.dirty, isTrue);
      f.store.pendingLoad = Completer<TimeToolsLoad>();
      final read = f.notifier.reload();
      await flushEvents();
      f.store.pendingLoad!.complete(TimeToolsLoad(value: taskSnapshot()));
      await read;
      expect(f.view.data.toJson(), intent);
      expect(f.view.dirty, isTrue);
      f.store.pendingWrites[1].complete();
      await f.notifier.flush();
      expect(f.view.dirty, isFalse);
      expect(f.view.data.toJson(), intent);
      expect(f.store.saved!.toJson(), intent);
    },
  );
  test(
    'real immutable file delete flush and fresh scope reopen preserve other bytes',
    () async {
      final dir = await temporaryFixture();
      final file = FileTimeToolsStore(directory: () => dir);
      final before = taskSnapshot();
      await file.put(before);
      final old = File(dir.path + '/state-r7.json');
      final bytes = await old.readAsString();
      final c = fileScope(file, () => DateTime.utc(2026, 10, 4));
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      expect(n.deleteTask('target'), isTrue);
      await n.flush();
      final intent = c.read(timeToolsProvider).data.toJson();
      expect(await old.readAsString(), bytes);
      final fresh = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => DateTime.utc(2026, 10, 4),
      );
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      expect(fresh.read(timeToolsProvider).data.toJson(), intent);
      expect(fresh.read(timeToolsProvider).data.tasks.map((t) => t.id), [
        'old',
        'keep',
      ]);
      expect(
        fresh.read(timeToolsProvider).data.tasks.first.createdAtUtc,
        isNull,
      );
      expect(fresh.read(timeToolsProvider).dirty, isFalse);
    },
  );
  test(
    'independent stores race after flush: one winner, bytes immutable, losing intent dirty',
    () async {
      final dir = await temporaryFixture();
      final staged = Completer<void>(), release = Completer<void>();
      var nonce = 0;
      final external = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'external-' + (++nonce).toString(),
        beforeCommit: (temporary, target) async {
          expect(await temporary.readAsString(), isNotEmpty);
          expect(await target.exists(), isFalse);
          staged.complete();
          await release.future;
        },
      );
      final local = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'local',
      );
      final created = DateTime.utc(2026, 10, 3, 12),
          due = created.add(const Duration(days: 1));
      final c = fileScope(local, () => created);
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      final winner = TimeToolsState(
        revision: 1,
        tasks: [
          TimeTask(
            id: 'external',
            text: 'winning external intent',
            createdAtUtc: created.subtract(const Duration(hours: 1)),
            dueAtUtc: due.add(const Duration(days: 1)),
          ),
        ],
      );
      final externalWrite = external.put(winner);
      await staged.future;
      expect(n.addTask('losing local intent', dueAtUtc: due), isTrue);
      final pending = n.flush();
      await pending;
      release.complete();
      await externalWrite;
      final target = File(dir.path + '/state-r1.json'),
          bytes = await File(dir.path + '/state-r1.json').readAsString();
      expect(c.read(timeToolsProvider).dirty, isTrue);
      expect(c.read(timeToolsProvider).error, isNotNull);
      expect(
        c.read(timeToolsProvider).data.tasks.single.text,
        'losing local intent',
      );
      expect(c.read(timeToolsProvider).data.tasks.single.createdAtUtc, created);
      expect(c.read(timeToolsProvider).data.tasks.single.dueAtUtc, due);
      expect(await target.readAsString(), bytes);
      // A retry must report conflict, not overwrite the durable winner.
      await n.retrySave();
      expect(c.read(timeToolsProvider).dirty, isTrue);
      expect(await target.readAsString(), bytes);
      final fresh = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => created,
      );
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      final tasks = fresh.read(timeToolsProvider).data.tasks;
      expect(tasks.single.text, winner.tasks.single.text);
      expect(tasks.single.createdAtUtc, winner.tasks.single.createdAtUtc);
      expect(tasks.single.dueAtUtc, winner.tasks.single.dueAtUtc);
      expect(fresh.read(timeToolsProvider).dirty, isFalse);
    },
  );

  test(
    'two stores at same revision: stable lock allows exactly one commit',
    () async {
      final dir = await temporaryFixture();
      final both = Completer<void>(), release = Completer<void>();
      var arrivals = 0;
      Future<void> barrier(File temporary, File target) async {
        expect(await target.exists(), isFalse);
        expect(await temporary.readAsString(), isNotEmpty);
        arrivals++;
        if (arrivals == 1) both.complete();
        await release.future;
      }

      final a = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'writer-a',
        beforeCommit: barrier,
      );
      final b = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'writer-b',
        beforeCommit: barrier,
      );
      final values = [
        TimeToolsState(
          revision: 1,
          tasks: const [TimeTask(id: 'a', text: 'writer a')],
        ),
        TimeToolsState(
          revision: 1,
          tasks: const [TimeTask(id: 'b', text: 'writer b')],
        ),
      ];
      Future<Object?> outcome(
        FileTimeToolsStore store,
        TimeToolsState value,
      ) async {
        try {
          await store.put(value);
          return null;
        } catch (error) {
          return error;
        }
      }

      final firstOutcome = outcome(a, values[0]);
      await both.future;
      final secondOutcome = await outcome(b, values[1]);
      release.complete();
      final outcomes = [await firstOutcome, secondOutcome];
      expect(outcomes.where((error) => error == null), hasLength(1));
      final failure = outcomes.whereType<FileSystemException>().single;
      expect(failure.osError!.errorCode, anyOf(33, 80, 183));
      if (failure.osError!.errorCode == 33) {
        expect(
          failure.path!.replaceAll('\\', '/'),
          '${dir.path.replaceAll('\\', '/')}/writer.lock',
        );
        expect(arrivals, 1); // loser never reached its staging callback
      } else {
        expect(
          failure.path!.replaceAll('\\', '/'),
          '${dir.path.replaceAll('\\', '/')}/state-r1.json',
        );
      }
      final index = outcomes.indexOf(null);
      final target = File(dir.path + '/state-r1.json'),
          bytes = await File(dir.path + '/state-r1.json').readAsString();
      expect(bytes, jsonEncode(values[index].toJson()));
      expect(
        (await FileTimeToolsStore(
          directory: () => dir,
        ).load()).value!.tasks.single.id,
        values[index].tasks.single.id,
      );
      await (index == 0 ? a : b).put(values[index]);
      expect(await target.readAsString(), bytes);
      await expectLater(
        (index == 0 ? b : a).put(values[1 - index]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), bytes);
    },
  );

  test(
    'identical concurrent snapshots verify idempotently and staging collision cannot rewrite',
    () async {
      final dir = await temporaryFixture();
      final staged = Completer<void>(), release = Completer<void>();
      final value = TimeToolsState(
        revision: 1,
        tasks: const [TimeTask(id: 'same', text: 'same bytes')],
      );
      final first = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'shared-stage',
        beforeCommit: (temporary, target) async {
          staged.complete();
          await release.future;
        },
      );
      final operation = first.put(value);
      await staged.future;
      final collision = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'shared-stage',
      );
      final temporary = File(dir.path + '/state-r1-shared-stage.tmp');
      final stagedBytes = await temporary.readAsString();
      await expectLater(
        collision.put(value.copyWith(tasks: const [])),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e.osError?.errorCode, 'lock acquisition', 33)
              .having(
                (e) => e.path!.replaceAll('\\', '/'),
                'exact lock path',
                '${dir.path.replaceAll('\\', '/')}/writer.lock',
              ),
        ),
      );
      expect(await temporary.readAsString(), stagedBytes);
      final second = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'another-stage',
      );
      await expectLater(
        second.put(value),
        throwsA(
          isA<FileSystemException>()
              .having((e) => e.osError?.errorCode, 'lock acquisition', 33)
              .having(
                (e) => e.path!.replaceAll('\\', '/'),
                'exact lock path',
                '${dir.path.replaceAll('\\', '/')}/writer.lock',
              ),
        ),
      );
      release.complete();
      await operation;
      final bytes = await File(dir.path + '/state-r1.json').readAsString();
      await second.put(value);
      expect(await File(dir.path + '/state-r1.json').readAsString(), bytes);
      expect((await first.load()).blocked, isFalse);
    },
  );
  test(
    'one injected UTC clock read per creation and no read on persistence retry',
    () async {
      var clockReads = 0;
      final store = MemoryTimeStore()..failWrite = true;
      final c = ProviderContainer(
        overrides: [
          timeToolsStoreProvider.overrideWithValue(store),
          timeToolsIdProvider.overrideWithValue(() => 'single-clock'),
          timeToolsClockProvider.overrideWithValue(() {
            clockReads++;
            return DateTime.utc(2026, 10, 3, 12);
          }),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      expect(n.addTask('合成'), isTrue);
      await n.flush();
      expect(clockReads, 1);
      store.failWrite = false;
      await n.retrySave();
      expect(clockReads, 1);
    },
  );
  for (final bad in [
    '2026-02-31T12:00:00Z',
    7,
    true,
    {'unknown': 'field'},
  ]) {
    test(
      'malformed UTC metadata file fails closed and preserves history $bad',
      () async {
        final dir = await temporaryFixture();
        final file = FileTimeToolsStore(directory: () => dir);
        await file.put(
          TimeToolsState(
            revision: 1,
            tasks: const [TimeTask(id: 'old', text: '旧内容')],
          ),
        );
        final damaged = TimeToolsState(
          revision: 2,
          tasks: const [TimeTask(id: 'new', text: '新内容')],
        ).toJson();
        damaged['tasks'] = [
          {
            'id': 'new',
            'text': '新内容',
            'done': false,
            'createdAtUtc': bad,
            'dueAtUtc': null,
          },
        ];
        final bytes = jsonEncode(damaged),
            target = File(dir.path + '/state-r2.json');
        await target.writeAsString(bytes, flush: true);
        final loaded = await file.load();
        expect(loaded.blocked, isTrue);
        expect(loaded.value!.tasks.single.text, '旧内容');
        await expectLater(
          file.put(TimeToolsState(revision: 3)),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.readAsString(), bytes);
        expect(await File(dir.path + '/state-r3.json').exists(), isFalse);
      },
    );
  }
  test('schema1 null history and schema2 strict task instants', () {
    final legacy = TimeToolsState(
      tasks: const [TimeTask(id: 'old', text: '旧任务')],
    ).toJson();
    legacy['schemaVersion'] = 1;
    legacy.remove('sessions');
    legacy['tasks'] = [
      {'id': 'old', 'text': '旧任务', 'done': false},
    ];
    final read = TimeToolsState.fromJson(legacy);
    expect(read.tasks.single.createdAtUtc, isNull);
    expect(read.tasks.single.dueAtUtc, isNull);
    expect(read.toJson()['schemaVersion'], 3);
    final created = DateTime.utc(2026, 10, 3, 12);
    final task = TimeTask(
      id: 'new',
      text: '新任务',
      createdAtUtc: created,
      dueAtUtc: created.subtract(const Duration(days: 1)),
    );
    final roundtrip = TimeTask.fromJson(task.toJson());
    expect(roundtrip.createdAtUtc, created);
    expect(roundtrip.dueAtUtc, task.dueAtUtc);
    for (final bad in [
      '2026-02-31T12:00:00Z',
      '2026-10-03T25:00:00Z',
      '2026-10-03T12:00:00+00:00',
      'not-a-date',
    ]) {
      expect(
        () => TimeTask.fromJson({...task.toJson(), 'createdAtUtc': bad}),
        throwsFormatException,
      );
      expect(
        () => TimeTask.fromJson({...task.toJson(), 'dueAtUtc': bad}),
        throwsFormatException,
      );
    }
    expect(
      () => TimeTask.fromJson({
        ...task.toJson(),
        'futureField': 'retain elsewhere',
      }),
      throwsFormatException,
    );
    expect(
      () => TimeToolsState.fromJson({...legacy, 'schemaVersion': 4}),
      throwsFormatException,
    );
  });

  test(
    'created time stays stable across edit toggle failed save and retry',
    () async {
      final f = Fixture();
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      final created = f.now;
      final due = created.subtract(const Duration(hours: 1));
      f.store.failWrite = true;
      expect(f.notifier.addTask('真实时钟的合成任务', dueAtUtc: due), isTrue);
      await f.notifier.flush();
      final revision = f.view.data.revision;
      expect(f.view.dirty, isTrue);
      f.now = f.now.add(const Duration(days: 2));
      f.store.failWrite = false;
      await f.notifier.retrySave();
      expect(f.view.data.revision, revision);
      expect(f.store.saved!.tasks.single.createdAtUtc, created);
      expect(f.notifier.editTask('fixture-1', '修改正文'), isTrue);
      expect(f.view.data.tasks.single.dueAtUtc, due);
      expect(f.notifier.toggleTask('fixture-1'), isTrue);
      expect(f.view.data.tasks.single.createdAtUtc, created);
      expect(f.notifier.editTask('fixture-1', '清除目标', clearDue: true), isTrue);
      await f.notifier.flush();
      final fresh = Fixture(storage: f.store);
      addTearDown(fresh.container.dispose);
      await fresh.notifier.ensureLoaded();
      expect(fresh.view.data.tasks.single.createdAtUtc, created);
      expect(fresh.view.data.tasks.single.dueAtUtc, isNull);
      expect(fresh.view.data.tasks.single.done, isTrue);
    },
  );

  test(
    'real schema1 history upgrades without rewriting bytes and metadata failure reopens',
    () async {
      final dir = await temporaryFixture();
      final legacy = TimeToolsState(
        revision: 1,
        tasks: const [TimeTask(id: 'old', text: '旧任务')],
      ).toJson();
      legacy['schemaVersion'] = 1;
      legacy.remove('sessions');
      legacy['tasks'] = [
        {'id': 'old', 'text': '旧任务', 'done': false},
      ];
      final old = File(dir.path + '/state-r1.json');
      final bytes = jsonEncode(legacy);
      await old.writeAsString(bytes, flush: true);
      final file = FileTimeToolsStore(directory: () => dir);
      final store = FailingFileStore(file);
      var now = DateTime.utc(2026, 10, 3, 12);
      final c = fileScope(store, () => now);
      final n = c.read(timeToolsProvider.notifier);
      await n.ensureLoaded();
      expect(c.read(timeToolsProvider).data.tasks.single.createdAtUtc, isNull);
      expect(n.editTask('old', '旧任务新标题'), isTrue);
      await n.flush();
      expect(c.read(timeToolsProvider).data.tasks.single.createdAtUtc, isNull);
      final created = now, due = now.add(const Duration(days: 1));
      store.failPut = true;
      expect(n.addTask('新任务', dueAtUtc: due), isTrue);
      await n.flush();
      final failedRevision = c.read(timeToolsProvider).data.revision;
      expect(c.read(timeToolsProvider).dirty, isTrue);
      expect((await file.load()).value!.tasks, hasLength(1));
      now = now.add(const Duration(days: 3));
      store.failPut = false;
      await n.retrySave();
      expect(c.read(timeToolsProvider).data.revision, failedRevision);
      expect(await old.readAsString(), bytes);
      final reopened = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => now,
      );
      await reopened.read(timeToolsProvider.notifier).ensureLoaded();
      final tasks = reopened.read(timeToolsProvider).data.tasks;
      expect(tasks.first.createdAtUtc, isNull);
      expect(tasks.last.createdAtUtc, created);
      expect(tasks.last.dueAtUtc, due);
      expect(reopened.read(timeToolsProvider).dirty, isFalse);
      final newest =
          jsonDecode(
                await File(
                  dir.path + '/state-r' + failedRevision.toString() + '.json',
                ).readAsString(),
              )
              as Map;
      expect(newest['schemaVersion'], 3);
    },
  );
  test(
    'shared bound covers ceil, zero, codec and rejected malformed pause',
    () {
      final now = DateTime.utc(2026, 10, 3, 12);
      expect(maxPomodoroSeconds, 10800);
      for (final (milliseconds, expected) in <(int, int)>[
        (-1001, 0),
        (-1, 0),
        (0, 0),
        (1, 1),
        (1000, 1),
        (1001, 2),
        (10800000, 10800),
        (10800001, 10800),
      ]) {
        final p = PomodoroState(
          running: true,
          deadlineUtc: now.add(Duration(milliseconds: milliseconds)),
        );
        expect(p.remaining(now), expected);
        expect(PomodoroState.fromJson(p.toJson()).deadlineUtc, p.deadlineUtc);
      }
      for (final phase in PomodoroPhase.values) {
        for (final remaining in [0, 60, 1500, maxPomodoroSeconds]) {
          final paused = PomodoroState(
            phase: phase,
            remainingSeconds: remaining,
            focusSeconds: maxPomodoroSeconds,
            restSeconds: maxPomodoroSeconds,
          );
          final roundtrip = PomodoroState.fromJson(paused.toJson());
          expect(roundtrip.remainingSeconds, remaining);
          expect(roundtrip.phase, phase);
          expect(roundtrip.running, isFalse);
          expect(roundtrip.deadlineUtc, isNull);
        }
        for (final remaining in [-1, maxPomodoroSeconds + 1]) {
          expect(
            () => PomodoroState.fromJson(
              PomodoroState(phase: phase, remainingSeconds: remaining).toJson(),
            ),
            throwsFormatException,
          );
        }
      }
    },
  );

  for (final phase in PomodoroPhase.values) {
    for (final (minutes, rollback, expected) in <(int, Duration, int)>[
      (180, const Duration(seconds: 1), 10800),
      (1, const Duration(seconds: 1), 61),
      (25, const Duration(hours: 4), 10800),
    ]) {
      test(
        'real files keep ' +
            phase.name +
            ' pause durable after ' +
            minutes.toString() +
            ' minute rollback',
        () async {
          final dir = await temporaryFixture();
          var now = DateTime.utc(2026, 10, 3, 12);
          var nonce = 0;
          final store = FileTimeToolsStore(
            directory: () => dir,
            nonce: () => 'rollback-' + (++nonce).toString(),
          );
          final scope = fileScope(store, () => now);
          final notifier = scope.read(timeToolsProvider.notifier);
          await notifier.ensureLoaded();
          expect(notifier.configurePomodoro(minutes, minutes), isTrue);
          await notifier.flush();
          expect(notifier.startPomodoro(), isTrue);
          await notifier.flush();
          if (phase == PomodoroPhase.rest) {
            now = now.add(Duration(minutes: minutes));
            notifier.reconcile();
            await notifier.flush();
            expect(
              scope.read(timeToolsProvider).data.pomodoro.completed,
              isTrue,
            );
            expect(notifier.startPomodoro(), isTrue);
            await notifier.flush();
          }
          final running = scope.read(timeToolsProvider);
          expect(running.data.pomodoro.phase, phase);
          expect(running.dirty, isFalse);
          final oldFile = File(
            dir.path + '/state-r' + running.data.revision.toString() + '.json',
          );
          final oldBytes = await oldFile.readAsString();
          final deadline = running.data.pomodoro.deadlineUtc;
          now = now.subtract(rollback);
          expect(running.data.pomodoro.remaining(now), expected);
          expect(
            scope.read(timeToolsProvider).data.revision,
            running.data.revision,
          );
          expect(
            scope.read(timeToolsProvider).data.pomodoro.deadlineUtc,
            deadline,
          );
          expect(notifier.pausePomodoro(), isTrue);
          await notifier.flush();
          final paused = scope.read(timeToolsProvider);
          expect(paused.data.revision, running.data.revision + 1);
          expect(paused.dirty, isFalse);
          expect(paused.error, isNull);
          expect(paused.data.pomodoro.running, isFalse);
          expect(paused.data.pomodoro.deadlineUtc, isNull);
          expect(paused.data.pomodoro.remainingSeconds, expected);
          final disk = await store.load();
          expect(disk.blocked, isFalse);
          expect(disk.value!.revision, paused.data.revision);
          expect(disk.value!.pomodoro.remainingSeconds, expected);
          expect(await oldFile.readAsString(), oldBytes);
          final fresh = fileScope(
            FileTimeToolsStore(
              directory: () => dir,
              nonce: () => 'fresh-' + (++nonce).toString(),
            ),
            () => now,
          );
          final reopened = fresh.read(timeToolsProvider.notifier);
          await reopened.ensureLoaded();
          final view = fresh.read(timeToolsProvider);
          expect(view.dirty, isFalse);
          expect(view.data.revision, paused.data.revision);
          expect(view.data.pomodoro.running, isFalse);
          expect(view.data.pomodoro.deadlineUtc, isNull);
          expect(view.data.pomodoro.phase, phase);
          expect(view.data.pomodoro.remainingSeconds, expected);
          expect(reopened.startPomodoro(), isTrue);
          expect(
            fresh.read(timeToolsProvider).data.pomodoro.deadlineUtc,
            now.add(Duration(seconds: expected)),
          );
          await reopened.flush();
          expect(fresh.read(timeToolsProvider).dirty, isFalse);
          expect(
            (await store.load()).value!.revision,
            paused.data.revision + 1,
          );
        },
      );
    }
  }

  test(
    'real file pause failure retains capped snapshot and retry reopens paused',
    () async {
      final dir = await temporaryFixture();
      var now = DateTime.utc(2026, 10, 3, 12), nonce = 0;
      final file = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'retry-' + (++nonce).toString(),
      );
      final store = FailingFileStore(file);
      final scope = fileScope(store, () => now);
      final notifier = scope.read(timeToolsProvider.notifier);
      await notifier.ensureLoaded();
      notifier.configurePomodoro(180, 5);
      await notifier.flush();
      notifier.startPomodoro();
      await notifier.flush();
      final runningRevision = scope.read(timeToolsProvider).data.revision;
      now = now.subtract(const Duration(seconds: 1));
      store.failPut = true;
      expect(notifier.pausePomodoro(), isTrue);
      await notifier.flush();
      final paused = scope.read(timeToolsProvider);
      expect(paused.dirty, isTrue);
      expect(paused.error, isNotNull);
      expect(paused.data.pomodoro.running, isFalse);
      expect(paused.data.pomodoro.deadlineUtc, isNull);
      expect(paused.data.pomodoro.remainingSeconds, maxPomodoroSeconds);
      expect((await file.load()).value!.revision, runningRevision);
      store.failPut = false;
      await notifier.retrySave();
      await notifier.flush();
      expect(scope.read(timeToolsProvider).dirty, isFalse);
      expect(scope.read(timeToolsProvider).error, isNull);
      expect(scope.read(timeToolsProvider).data.revision, paused.data.revision);
      expect(store.attemptedRevisions.where((r) => r == paused.data.revision), [
        paused.data.revision,
        paused.data.revision,
      ]);
      final disk = (await file.load()).value!;
      expect(disk.revision, paused.data.revision);
      expect(disk.pomodoro.running, isFalse);
      final fresh = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => now,
      );
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      expect(fresh.read(timeToolsProvider).data.revision, paused.data.revision);
      expect(fresh.read(timeToolsProvider).data.pomodoro.running, isFalse);
      expect(fresh.read(timeToolsProvider).data.pomodoro.deadlineUtc, isNull);
      expect(
        fresh.read(timeToolsProvider).data.pomodoro.remainingSeconds,
        10800,
      );
      expect(fresh.read(timeToolsProvider).dirty, isFalse);
    },
  );

  test(
    'real file expiry cannot reopen itself when clock moves backward',
    () async {
      final dir = await temporaryFixture();
      var now = DateTime.utc(2026, 10, 3, 12);
      final scope = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => now,
      );
      final notifier = scope.read(timeToolsProvider.notifier);
      await notifier.ensureLoaded();
      notifier.configurePomodoro(1, 1);
      await notifier.flush();
      notifier.startPomodoro();
      await notifier.flush();
      now = now.add(const Duration(minutes: 1));
      notifier.reconcile();
      await notifier.flush();
      final expiredRevision = scope.read(timeToolsProvider).data.revision;
      now = now.subtract(const Duration(hours: 4));
      notifier.reconcile();
      expect(scope.read(timeToolsProvider).data.revision, expiredRevision);
      final fresh = fileScope(
        FileTimeToolsStore(directory: () => dir),
        () => now,
      );
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      final p = fresh.read(timeToolsProvider).data.pomodoro;
      expect(p.completed, isTrue);
      expect(p.running, isFalse);
      expect(p.deadlineUtc, isNull);
      expect(p.remaining(now), 0);
      expect(p.phase, PomodoroPhase.focus);
      expect(fresh.read(timeToolsProvider).data.revision, expiredRevision);
    },
  );

  test('deadline pause resume complete and explicit next phase only', () async {
    final f = Fixture();
    addTearDown(f.container.dispose);
    await f.notifier.ensureLoaded();
    expect(f.notifier.configurePomodoro(1, 1), isTrue);
    expect(f.notifier.startPomodoro(), isTrue);
    expect(f.notifier.startPomodoro(), isFalse);
    f.now = f.now.add(const Duration(seconds: 20));
    expect(f.view.data.pomodoro.remaining(f.now), 40);
    expect(f.notifier.pausePomodoro(), isTrue);
    expect(f.view.data.pomodoro.deadlineUtc, isNull);
    f.now = f.now.add(const Duration(hours: 3));
    expect(f.view.data.pomodoro.remaining(f.now), 40);
    f.notifier.startPomodoro();
    f.now = f.now.add(const Duration(seconds: 41));
    f.notifier.reconcile();
    expect(f.view.data.pomodoro.running, isFalse);
    expect(f.view.data.pomodoro.completed, isTrue);
    expect(f.view.data.pomodoro.phase, PomodoroPhase.focus);
    final revision = f.view.data.revision;
    f.now = f.now.add(const Duration(days: 3));
    f.notifier.reconcile();
    expect(f.view.data.revision, revision);
    f.notifier.startPomodoro();
    expect(f.view.data.pomodoro.phase, PomodoroPhase.rest);
    expect(f.view.data.pomodoro.remaining(f.now), 60);
    f.notifier.resetPomodoro();
    expect(f.view.data.pomodoro.running, isFalse);
    expect(f.view.data.pomodoro.phase, PomodoroPhase.focus);
    await f.notifier.flush();
  });

  test(
    'running future deadline and expired restart never catch up rounds',
    () async {
      final first = Fixture();
      addTearDown(first.container.dispose);
      await first.notifier.ensureLoaded();
      first.notifier.startPomodoro();
      await first.notifier.flush();
      final second = Fixture(storage: first.store)
        ..now = first.now.add(const Duration(minutes: 5));
      addTearDown(second.container.dispose);
      await second.notifier.ensureLoaded();
      expect(second.view.data.pomodoro.remaining(second.now), 1200);
      expect(second.view.data.pomodoro.running, isTrue);
      final third = Fixture(storage: first.store)
        ..now = first.now.add(const Duration(days: 2));
      addTearDown(third.container.dispose);
      await third.notifier.ensureLoaded();
      expect(third.view.data.pomodoro.completed, isTrue);
      expect(third.view.data.pomodoro.running, isFalse);
      expect(third.view.data.pomodoro.phase, PomodoroPhase.focus);
      await third.notifier.flush();
    },
  );

  test(
    'tasks preserve identity order and countdown independent UTC target',
    () async {
      final f = Fixture();
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      for (final text in ['第一件', '第二件', '第三件']) {
        expect(f.notifier.addTask(text), isTrue);
      }
      f.notifier.toggleTask('fixture-2');
      f.notifier.editTask('fixture-1', '修改第一件');
      expect(f.view.data.tasks.map((t) => t.id), [
        'fixture-1',
        'fixture-2',
        'fixture-3',
      ]);
      expect(f.view.data.tasks.map((t) => t.text), ['修改第一件', '第二件', '第三件']);
      expect(f.view.data.tasks[1].done, isTrue);
      expect(f.notifier.addTask('  '), isFalse);
      expect(parseLocalCountdown('2026-02-31 10:00'), isNull);
      expect(parseLocalCountdown('2026-10-03 25:00'), isNull);
      final local = parseLocalCountdown('2026-10-04 10:30')!;
      f.notifier.setCountdown('合成目标', local);
      final target = f.view.data.countdown!.targetUtc;
      expect(target.isUtc, isTrue);
      expect(target, local.toUtc());
      f.now = DateTime.utc(2027);
      expect(f.view.data.countdown!.targetUtc, target);
      expect(f.view.data.countdown!.expired(f.now), isTrue);
      await f.notifier.flush();
      final fresh = Fixture(storage: f.store);
      addTearDown(fresh.container.dispose);
      await fresh.notifier.ensureLoaded();
      expect(fresh.view.data.tasks.map((t) => t.id), [
        'fixture-1',
        'fixture-2',
        'fixture-3',
      ]);
      expect(fresh.view.data.countdown!.targetUtc, target);
      expect(f.view.data.toJson().keys.toSet(), {
        'schemaVersion',
        'revision',
        'pomodoro',
        'tasks',
        'countdown',
        'sessions',
      });
    },
  );

  test(
    'read failure blocks defaults; retry recovers without losing memory',
    () async {
      final store = MemoryTimeStore()..failRead = true;
      final f = Fixture(storage: store);
      addTearDown(f.container.dispose);
      expect(f.notifier.addTask('not loaded'), isFalse);
      await f.notifier.ensureLoaded();
      expect(f.view.blocked, isTrue);
      expect(f.notifier.addTask('blocked'), isFalse);
      expect(store.writes, isEmpty);
      store.failRead = false;
      await f.notifier.reload();
      expect(f.notifier.addTask('kept'), isTrue);
      await f.notifier.flush();
      store.failRead = true;
      await f.notifier.reload();
      expect(f.view.data.tasks.single.text, 'kept');
      expect(f.view.blocked, isTrue);
      store.failRead = false;
      await f.notifier.reload();
      expect(f.view.canEdit, isTrue);
    },
  );

  test(
    'future or damaged load shows old state readonly with no writes',
    () async {
      final store = MemoryTimeStore()
        ..result = TimeToolsLoad(
          value: TimeToolsState(
            revision: 7,
            tasks: const [TimeTask(id: 'safe', text: '可恢复旧内容')],
          ),
          blocked: true,
          message: 'synthetic future revision',
        );
      final f = Fixture(storage: store);
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      expect(f.view.data.tasks.single.text, '可恢复旧内容');
      expect(f.notifier.resetPomodoro(), isFalse);
      expect(f.notifier.addTask('unsafe'), isFalse);
      await f.notifier.retrySave();
      expect(store.writes, isEmpty);
    },
  );

  test(
    'failed persistence keeps dirty content; retry does not replay actions',
    () async {
      final f = Fixture();
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      f.store.failWrite = true;
      f.notifier.addTask('paid no API involved');
      await f.notifier.flush();
      final revision = f.view.data.revision;
      expect(f.view.dirty, isTrue);
      expect(f.view.error, isNotNull);
      f.store.failWrite = false;
      await f.notifier.retrySave();
      expect(f.view.dirty, isFalse);
      expect(f.view.data.revision, revision);
      expect(f.store.saved!.tasks, hasLength(1));
    },
  );

  test(
    'old ack never clears newer dirty revision; serial fake writes',
    () async {
      final f = Fixture();
      addTearDown(f.container.dispose);
      await f.notifier.ensureLoaded();
      f.store.holdWrites = true;
      f.notifier.addTask('one');
      await flushEvents();
      f.notifier.addTask('two');
      f.store.pendingWrites[0].complete();
      await flushEvents();
      expect(f.view.data.tasks, hasLength(2));
      expect(f.view.dirty, isTrue);
      expect(f.store.pendingWrites, hasLength(2));
      f.store.pendingWrites[1].complete();
      await f.notifier.flush();
      expect(f.view.dirty, isFalse);
      expect(f.store.saved!.tasks, hasLength(2));
    },
  );

  test('late lower load cannot overwrite newly acknowledged memory', () async {
    final f = Fixture();
    addTearDown(f.container.dispose);
    await f.notifier.ensureLoaded();
    f.notifier.addTask('new memory');
    await f.notifier.flush();
    f.store.pendingLoad = Completer<TimeToolsLoad>();
    final operation = f.notifier.reload();
    await flushEvents();
    f.store.pendingLoad!.complete(
      TimeToolsLoad(value: TimeToolsState(revision: 0)),
    );
    await operation;
    expect(f.view.data.revision, 1);
    expect(f.view.data.tasks.single.text, 'new memory');
  });

  for (final started in [false, true]) {
    test('dispose before or after load begins ends safely', () async {
      final f = Fixture();
      f.store.pendingLoad = Completer<TimeToolsLoad>();
      final operation = f.notifier.ensureLoaded();
      if (started) await flushEvents();
      f.container.dispose();
      f.store.pendingLoad!.complete(const TimeToolsLoad());
      await expectLater(operation, completes);
      expect(f.store.reads, started ? 1 : 0);
      expect(f.store.writes, isEmpty);
    });
  }
  test(
    'disposed pending write completion performs no provider access',
    () async {
      final f = Fixture();
      await f.notifier.ensureLoaded();
      f.store.holdWrites = true;
      f.notifier.addTask('in flight');
      await flushEvents();
      final operation = f.notifier.flush();
      f.container.dispose();
      f.store.pendingWrites.single.complete();
      await expectLater(operation, completes);
    },
  );

  test(
    'immutable file revisions roundtrip, collision and queue failure recover',
    () async {
      final dir = await temporaryFixture();
      var invalid = true, nonce = 0;
      final store = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => invalid ? '../bad' : 'nonce-' + (++nonce).toString(),
      );
      expect((await store.load()).missing, isTrue);
      final first = TimeToolsState(
        revision: 1,
        tasks: const [TimeTask(id: 'one', text: '合成')],
      );
      await expectLater(store.put(first), throwsFormatException);
      invalid = false;
      await store.put(first);
      final original = await File(dir.path + '/state-r1.json').readAsString();
      await store.put(first);
      await expectLater(
        store.put(first.copyWith(tasks: const [])),
        throwsA(isA<FileSystemException>()),
      );
      await store.put(first.copyWith(revision: 2));
      final fresh = FileTimeToolsStore(directory: () => dir);
      expect((await fresh.load()).value!.revision, 2);
      expect(await File(dir.path + '/state-r1.json').readAsString(), original);
      await File(
        dir.path + '/interrupted.tmp',
      ).writeAsString('synthetic unfinished');
      expect((await fresh.load()).blocked, isFalse);
      expect(await File(dir.path + '/interrupted.tmp').exists(), isTrue);
    },
  );

  for (final bad in ['{bad', '{"schemaVersion":4,"revision":2}']) {
    test(
      'bad or future newer file is retained and never overwritten',
      () async {
        final dir = await temporaryFixture();
        final store = FileTimeToolsStore(directory: () => dir);
        await store.put(
          TimeToolsState(
            revision: 1,
            tasks: const [TimeTask(id: 'one', text: 'old safe')],
          ),
        );
        final file = File(dir.path + '/state-r2.json');
        await file.writeAsString(bad);
        final result = await store.load();
        expect(result.blocked, isTrue);
        expect(result.value!.tasks.single.text, 'old safe');
        await expectLater(
          store.put(TimeToolsState(revision: 3)),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), bad);
        expect(await File(dir.path + '/state-r3.json').exists(), isFalse);
      },
    );
  }
  test('store rejects relative injected path instead of reading cwd', () async {
    final store = FileTimeToolsStore(
      directory: () => Directory('unsafe-relative-fixture'),
    );
    await expectLater(store.load(), throwsA(isA<FileSystemException>()));
  });
}
