import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/time_tools/data/time_tools_store.dart';
import 'package:timetrace_app/src/features/time_tools/domain/time_tool_state.dart';
import 'package:timetrace_app/src/features/time_tools/providers/time_tools_provider.dart';
import 'time_tools_state_test.dart' show MemoryTimeStore, temporaryFixture;

class SessionFixture {
  SessionFixture({TimeToolsStore? storage, DateTime? initial})
    : store = storage ?? MemoryTimeStore() {
    now = initial ?? DateTime.utc(2026, 10, 5, 12);
    scope = ProviderContainer(
      overrides: [
        timeToolsStoreProvider.overrideWithValue(store),
        timeToolsClockProvider.overrideWithValue(() => now),
        timeToolsMonotonicProvider.overrideWithValue(() => elapsed),
        timeToolsIdProvider.overrideWithValue(() => 'session-fixture-${++ids}'),
      ],
    );
    addTearDown(scope.dispose);
  }
  final TimeToolsStore store;
  late DateTime now;
  Duration elapsed = Duration.zero;
  int ids = 0;
  late final ProviderContainer scope;
  TimeToolsNotifier get n => scope.read(timeToolsProvider.notifier);
  TimeToolsViewState get view => scope.read(timeToolsProvider);
  void advance(Duration delta) {
    now = now.add(delta);
    elapsed += delta;
  }
}

class IntentTrackingStore implements TimeToolsStore {
  TimeToolsState? saved;
  bool failWrite = false;
  int? failureRevision;
  Completer<void>? gate;
  TimeToolsState? lastBase, lastIntent;
  @override
  Future<TimeToolsLoad> load() async => TimeToolsLoad(value: saved);
  @override
  Future<void> put(
    TimeToolsState value, {
    TimeToolsState? expectedBase,
    bool checkBase = false,
  }) async {
    expect(checkBase, isTrue);
    lastBase = expectedBase;
    lastIntent = value;
    await gate?.future;
    if (failWrite || value.revision == failureRevision)
      throw StateError('synthetic write failure');
    if (jsonEncode(expectedBase?.toJson()) != jsonEncode(saved?.toJson())) {
      throw StateError('synthetic CAS conflict');
    }
    saved = value;
  }
}

void main() {
  test(
    'failed intent bookkeeping stays bounded and latest retry never refreshes CAS base',
    () async {
      final store = IntentTrackingStore();
      final f = SessionFixture(storage: store);
      await f.n.ensureLoaded();
      f.n.setCountdown('initial', f.now.add(const Duration(days: 1)));
      await f.n.flush();
      final base = store.saved!, id = f.view.data.sessions.single.id;
      store.failWrite = true;
      for (var i = 0; i < 2048; i++) {
        expect(
          f.n.setCountdown('failed-$i', f.view.data.countdown!.targetUtc),
          isTrue,
        );
        await f.n.flush();
        expect(f.view.dirty, isTrue);
        expect(f.n.retainedIntentBaseCount, 1);
        expect(store.lastBase, same(base));
        expect(f.view.data.sessions.single.id, id);
      }
      final snapshot = f.view.data, ids = f.ids;
      store.failWrite = false;
      store.saved = base.copyWith(revision: 9999);
      final rival = store.saved;
      await f.n.retrySave();
      expect(f.view.dirty, isTrue);
      expect(store.saved, same(rival));
      expect(store.lastBase, same(base));
      expect(store.lastIntent, same(snapshot));
      expect(f.n.retainedIntentBaseCount, 1);
      store.saved =
          base; // controlled restoration, not production conflict override
      await f.n.retrySave();
      expect(store.saved, same(snapshot));
      expect(f.view.data, same(snapshot));
      expect(f.view.dirty, isFalse);
      expect(f.n.retainedIntentBaseCount, 0);
      expect(f.ids, ids);
    },
  );
  test(
    'in-flight retry retains first base, late ACK cannot clear newer failed snapshot',
    () async {
      final store = IntentTrackingStore();
      final f = SessionFixture(storage: store);
      await f.n.ensureLoaded();
      store.failWrite = true;
      f.n.startPomodoro();
      await f.n.flush();
      final first = f.view.data;
      expect(f.n.retainedIntentBaseCount, 1);
      store.failWrite = false;
      store.gate = Completer<void>();
      final retry = f.n.retrySave();
      await Future<void>.delayed(Duration.zero);
      expect(store.lastBase, isNull);
      expect(store.lastIntent, same(first));
      f.n.pausePomodoro();
      final latest = f.view.data;
      store.failureRevision = latest.revision;
      expect(f.n.retainedIntentBaseCount, lessThanOrEqualTo(2));
      store.gate!.complete();
      await retry;
      // First ACK is real but must not clear or re-identify the queued edit.
      expect(f.view.data, same(latest));
      expect(f.view.dirty, isTrue);
      store.gate = null;
      store.failWrite = true;
      await f.n.flush();
      expect(store.saved, same(first));
      expect(store.lastBase, same(first));
      expect(f.n.retainedIntentBaseCount, 1);
      expect(f.view.dirty, isTrue);
      store.failWrite = false;
      store.failureRevision = null;
      await f.n.retrySave();
      expect(store.lastBase, same(first));
      expect(store.saved, same(latest));
      expect(latest.sessions.single.id, first.sessions.single.id);
      expect(f.n.retainedIntentBaseCount, 0);
      expect(f.view.dirty, isFalse);
    },
  );
  test(
    'schema3 session strict types, unknown fields, UTC and timer link fail closed',
    () {
      final now = DateTime.utc(2026, 10, 5);
      final s = TimeSession(
        id: 'valid',
        kind: TimeSessionKind.pomodoro,
        phase: PomodoroPhase.focus,
        startUtc: now,
      );
      final root = TimeToolsState(
        pomodoro: PomodoroState(
          running: true,
          deadlineUtc: now.add(const Duration(minutes: 1)),
        ),
        sessions: [s],
      ).toJson();
      expect(TimeToolsState.fromJson(root).sessions.single.id, 'valid');
      for (final bad in [
        {...root, 'schemaVersion': 3.0},
        {...root, 'schemaVersion': 4},
        {...root, 'unknown': 'preserve raw'},
        {...root, 'pomodoro': const PomodoroState().toJson()},
        {
          ...root,
          'sessions': [s.toJson()..['knownMicroseconds'] = '1'],
        },
        {
          ...root,
          'sessions': [s.toJson()..['elapsedKnown'] = 1],
        },
        {
          ...root,
          'sessions': [s.toJson()..['startUtc'] = '2026-02-31T00:00:00Z'],
        },
        {
          ...root,
          'sessions': [s.toJson()..['endUtc'] = now.toIso8601String()],
        },
        {
          ...root,
          'sessions': [s.toJson(), s.toJson()],
        },
      ]) {
        expect(
          () => TimeToolsState.fromJson(bad),
          throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
        );
      }
    },
  );
  for (final stage in ['flush', 'commit', 'readback']) {
    test(
      'real synthetic $stage failure keeps session intent and retry bytes/ID',
      () async {
        final dir = await temporaryFixture();
        var failStage = true, nonce = 0;
        final store = FileTimeToolsStore(
          directory: () => dir,
          nonce: () => 'fault-${++nonce}',
          writeTemporary: (tmp, encoded) async {
            if (stage == 'flush' && failStage) {
              await tmp.writeAsString('synthetic partial', flush: true);
              throw const FileSystemException('synthetic flush rejected');
            }
            await tmp.writeAsString(encoded, flush: true);
          },
          beforeCommit: (tmp, target) async {
            if (stage == 'commit' && failStage)
              throw const FileSystemException('synthetic commit failure');
          },
          beforeReadback: (_) async {
            if (stage == 'readback' && failStage)
              throw const FileSystemException('synthetic readback failure');
          },
        );
        final f = SessionFixture(storage: store);
        await f.n.ensureLoaded();
        f.n.startPomodoro();
        await f.n.flush();
        final intent = f.view.data.toJson(),
            id = f.view.data.sessions.single.id,
            calls = f.ids;
        expect(f.view.dirty, isTrue);
        if (stage != 'readback') expect((await store.load()).value, isNull);
        failStage = false;
        f.advance(const Duration(days: 1));
        await f.n.retrySave();
        expect(f.view.dirty, isFalse);
        expect(f.view.data.toJson(), intent);
        expect(f.ids, calls);
        expect(
          (await FileTimeToolsStore(
            directory: () => dir,
          ).load()).value!.sessions.single.id,
          id,
        );
        expect((await store.load()).value!.toJson(), intent);
      },
    );
  }
  test(
    'existing staging bytes cannot be rewritten even without another lock owner',
    () async {
      final dir = await temporaryFixture();
      final tmp = File('${dir.path}/state-r1-fixed.tmp');
      await tmp.writeAsString('synthetic orphan', flush: true);
      final store = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'fixed',
      );
      await expectLater(
        store.put(TimeToolsState(revision: 1)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await tmp.readAsString(), 'synthetic orphan');
      expect(await File('${dir.path}/state-r1.json').exists(), isFalse);
    },
  );

  test(
    'strict hms boundaries do not truncate or accept malformed components',
    () {
      for (final (h, m, s, want) in [
        ('0', '0', '0', null),
        ('0', '0', '59', null),
        ('0', '1', '0', 60),
        ('0', '1', '1', 61),
        ('3', '0', '0', 10800),
        ('3', '0', '1', null),
        ('-1', '1', '0', null),
        ('0', '1.0', '0', null),
        ('0', '60', '0', null),
        ('0', '0', '60', null),
        ('999999999999999999999', '0', '0', null),
      ]) {
        expect(pomodoroSeconds(h, m, s), want);
      }
    },
  );
  test(
    'monotonic pause resume same ID checkpoints only, late expiry once, no catchup',
    () async {
      final f = SessionFixture();
      await f.n.ensureLoaded();
      expect(f.n.configurePomodoroSeconds(61, 60), isTrue);
      expect(f.n.startPomodoro(), isTrue);
      await f.n.flush();
      final id = f.view.data.sessions.single.id;
      final writes = (f.store as MemoryTimeStore).writes.length;
      f.advance(const Duration(seconds: 20));
      f.n.reconcile();
      expect((f.store as MemoryTimeStore).writes.length, writes);
      expect(f.n.pausePomodoro(), isTrue);
      await f.n.flush();
      expect(f.view.data.sessions.single.knownMicroseconds, 20000000);
      f.advance(const Duration(hours: 2));
      expect(f.n.startPomodoro(), isTrue);
      expect(f.view.data.sessions.single.id, id);
      await f.n.flush();
      f.advance(const Duration(seconds: 44));
      f.n.reconcile();
      await f.n.flush();
      final ended = f.view.data.sessions.single;
      expect(ended.status, TimeSessionStatus.completed);
      expect(ended.effectiveActiveSeconds, 61);
      expect(ended.endUtc, f.now);
      final revision = f.view.data.revision;
      f.n.reconcile();
      f.advance(const Duration(days: 1));
      f.n.reconcile();
      expect(f.view.data.revision, revision);
      expect(f.view.data.sessions, hasLength(1));
      expect(f.n.startPomodoro(), isTrue);
      await f.n.flush();
      expect(f.view.data.pomodoro.phase, PomodoroPhase.rest);
      expect(f.view.data.sessions, hasLength(2));
      expect(f.view.data.sessions.last.id, isNot(id));
    },
  );
  test(
    'reset cancels, explicit hms edit interrupts, title-only does not read ID/clock',
    () async {
      final f = SessionFixture();
      await f.n.ensureLoaded();
      f.n.startPomodoro();
      f.advance(const Duration(seconds: 10));
      expect(f.n.configurePomodoroSeconds(61, 60), isTrue);
      await f.n.flush();
      expect(f.view.data.sessions.single.status, TimeSessionStatus.interrupted);
      expect(f.view.data.sessions.single.effectiveActiveSeconds, 10);
      f.n.startPomodoro();
      f.advance(const Duration(seconds: 1));
      f.n.resetPomodoro();
      await f.n.flush();
      expect(f.view.data.sessions.last.status, TimeSessionStatus.cancelled);
      expect(
        f.n.setCountdown('long', f.now.add(const Duration(days: 5))),
        isTrue,
      );
      await f.n.flush();
      final session = f.view.data.sessions.last.toJson(), ids = f.ids;
      final target = f.view.data.countdown!.targetUtc;
      expect(f.n.setCountdown('renamed', target), isTrue);
      await f.n.flush();
      expect(f.ids, ids);
      expect(f.view.data.sessions.last.toJson(), session);
    },
  );
  test(
    'countdown absolute >3h saves reopens and expiry is unknown on restart',
    () async {
      final dir = await temporaryFixture();
      var nonce = 0;
      final store = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'long-${++nonce}',
      );
      final f = SessionFixture(storage: store);
      await f.n.ensureLoaded();
      final target = f.now.add(const Duration(days: 7));
      expect(f.n.setCountdown('合法长日期', target), isTrue);
      await f.n.flush();
      final id = f.view.data.sessions.single.id;
      final fresh = SessionFixture(
        storage: FileTimeToolsStore(directory: () => dir),
        initial: f.now,
      );
      await fresh.n.ensureLoaded();
      expect(fresh.view.data.countdown!.targetUtc, target);
      expect(fresh.view.data.sessions.single.elapsedKnown, isFalse);
      fresh.now = target.add(const Duration(seconds: 1));
      fresh.n.reconcile();
      await fresh.n.flush();
      expect(fresh.view.data.sessions.single.id, id);
      expect(
        fresh.view.data.sessions.single.status,
        TimeSessionStatus.completed,
      );
      expect(fresh.view.data.sessions.single.effectiveActiveSeconds, isNull);
      final r = fresh.view.data.revision;
      fresh.n.reconcile();
      expect(fresh.view.data.revision, r);
      expect((await store.load()).value!.sessions, hasLength(1));
    },
  );
  test(
    'clock anomaly retains known checkpoints, unknown total, failed retry unchanged',
    () async {
      final store = MemoryTimeStore();
      final f = SessionFixture(storage: store);
      await f.n.ensureLoaded();
      f.n.startPomodoro();
      f.advance(const Duration(seconds: 10));
      f.n.pausePomodoro();
      await f.n.flush();
      f.n.startPomodoro();
      await f.n.flush();
      f.elapsed += const Duration(seconds: 5);
      f.now = f.now.subtract(const Duration(hours: 1));
      store.failWrite = true;
      f.n.pausePomodoro();
      await f.n.flush();
      final intent = f.view.data.toJson();
      expect(f.view.dirty, isTrue);
      expect(f.view.data.sessions.single.knownMicroseconds, 10000000);
      expect(f.view.data.sessions.single.effectiveActiveSeconds, isNull);
      store.failWrite = false;
      f.now = f.now.add(const Duration(days: 2));
      await f.n.retrySave();
      expect(f.view.data.toJson(), intent);
      expect(f.view.dirty, isFalse);
    },
  );
  for (final version in [1, 2]) {
    test('legacy v$version running timer never invents a session', () async {
      final dir = await temporaryFixture();
      final now = DateTime.utc(2026, 10, 5, 12);
      final raw = TimeToolsState(
        revision: 1,
        pomodoro: PomodoroState(
          running: true,
          deadlineUtc: now.add(const Duration(minutes: 1)),
        ),
      ).toJson();
      raw['schemaVersion'] = version;
      raw.remove('sessions');
      final file = File('${dir.path}/state-r1.json'), bytes = jsonEncode(raw);
      await file.writeAsString(bytes, flush: true);
      final f = SessionFixture(
        storage: FileTimeToolsStore(directory: () => dir),
        initial: now,
      );
      await f.n.ensureLoaded();
      expect(f.view.data.sessions, isEmpty);
      f.advance(const Duration(minutes: 2));
      f.n.reconcile();
      await f.n.flush();
      expect(f.view.data.sessions, isEmpty);
      expect(f.view.data.pomodoro.completed, isTrue);
      expect(await file.readAsString(), bytes);
    });
  }
  test(
    'capacity includes active slot; full active completes and retries, new start blocked',
    () async {
      final now = DateTime.utc(2026, 10, 5, 12);
      final records = [
        for (var i = 0; i < maxTimeSessions - 1; i++)
          TimeSession(
            id: 'old-$i',
            kind: TimeSessionKind.countdown,
            startUtc: now,
            endUtc: now,
            status: TimeSessionStatus.completed,
          ),
      ];
      records.add(
        TimeSession(
          id: 'active',
          kind: TimeSessionKind.pomodoro,
          phase: PomodoroPhase.focus,
          startUtc: now,
        ),
      );
      final store = MemoryTimeStore()
        ..saved = TimeToolsState(
          revision: 1,
          sessions: records,
          pomodoro: PomodoroState(
            running: true,
            deadlineUtc: now.add(const Duration(minutes: 1)),
          ),
        );
      final f = SessionFixture(storage: store, initial: now);
      await f.n.ensureLoaded();
      expect(f.n.pausePomodoro(), isTrue);
      await f.n.flush();
      expect(f.n.startPomodoro(), isTrue);
      await f.n.flush();
      store.failWrite = true;
      f.advance(const Duration(hours: 1));
      f.n.reconcile();
      await f.n.flush();
      final intent = f.view.data.toJson();
      expect(f.view.dirty, isTrue);
      expect(f.view.data.sessions, hasLength(maxTimeSessions));
      expect(f.view.data.sessions.last.status, TimeSessionStatus.completed);
      store.failWrite = false;
      await f.n.retrySave();
      expect(f.view.data.toJson(), intent);
      expect(f.view.dirty, isFalse);
      expect(f.n.startPomodoro(), isFalse);
      expect(f.view.error, contains('10000'));
      expect(f.view.data.sessions, hasLength(maxTimeSessions));
    },
  );
  for (final rivalRevision in [2, 3]) {
    test(
      'stable cross-handle lock/CAS rivals revision$rivalRevision cannot publish; stale retry conflicts',
      () async {
        final dir = await temporaryFixture();
        final staged = Completer<void>(), release = Completer<void>();
        final base = TimeToolsState(revision: 1);
        await FileTimeToolsStore(directory: () => dir).put(base);
        final first = FileTimeToolsStore(
          directory: () => dir,
          nonce: () => 'held',
          beforeCommit: (tmp, target) async {
            staged.complete();
            await release.future;
          },
        );
        final second = FileTimeToolsStore(
          directory: () => dir,
          nonce: () => 'rival',
        );
        final winner = base.copyWith(
          revision: 2,
          tasks: [const TimeTask(id: 'winner', text: 'held writer')],
        );
        final loser = base.copyWith(
          revision: rivalRevision,
          tasks: [const TimeTask(id: 'loser', text: 'rival')],
        );
        final write = first.put(winner, expectedBase: base, checkBase: true);
        await staged.future;
        await expectLater(
          second.put(loser, expectedBase: base, checkBase: true),
          throwsA(isA<FileSystemException>()),
        );
        release.complete();
        await write;
        final bytes = await File('${dir.path}/state-r2.json').readAsString();
        await expectLater(
          second.put(loser, expectedBase: base, checkBase: true),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File('${dir.path}/state-r2.json').readAsString(), bytes);
        expect((await second.load()).value!.toJson(), winner.toJson());
        if (rivalRevision == 3)
          expect(await File('${dir.path}/state-r3.json').exists(), isFalse);
        await second.put(winner, expectedBase: base, checkBase: true);
        expect(await File('${dir.path}/state-r2.json').readAsString(), bytes);
      },
    );
  }
  test(
    'unlocked collision reaches native noReplace and preserves rogue winner',
    () async {
      final dir = await temporaryFixture();
      final rogue = TimeToolsState(
        revision: 1,
        tasks: [const TimeTask(id: 'rogue', text: 'external bytes')],
      );
      final bytes = jsonEncode(rogue.toJson());
      final store = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'native',
        beforePublish: (tmp, target) async {
          expect(await target.exists(), isFalse);
          await target.writeAsString(bytes, flush: true);
        },
      );
      try {
        await store.put(TimeToolsState(revision: 1), checkBase: true);
        fail('No-replace collision must fail');
      } on FileSystemException catch (e) {
        expect(e.osError!.errorCode, anyOf(80, 183));
        expect(
          e.path!.replaceAll('\\', '/'),
          '${dir.path.replaceAll('\\', '/')}/state-r1.json',
        );
      }
      expect(await File('${dir.path}/state-r1.json').readAsString(), bytes);
      expect((await store.load()).value!.toJson(), rogue.toJson());
    },
  );
  test(
    'postcommit readback fault keeps complete same intent; verified lost ACK retry reopens',
    () async {
      final dir = await temporaryFixture();
      var failed = true;
      final store = FileTimeToolsStore(
        directory: () => dir,
        nonce: () => 'ack',
        beforeReadback: (_) async {
          if (failed)
            throw const FileSystemException('synthetic readback failure');
        },
      );
      final f = SessionFixture(storage: store);
      await f.n.ensureLoaded();
      f.n.startPomodoro();
      await f.n.flush();
      final intent = f.view.data.toJson();
      expect(f.view.dirty, isTrue);
      expect(f.view.data.sessions, hasLength(1));
      failed = false;
      f.advance(const Duration(days: 1));
      await f.n.retrySave();
      expect(f.view.data.toJson(), intent);
      expect(f.view.dirty, isFalse);
      expect(
        (await FileTimeToolsStore(directory: () => dir).load()).value!.toJson(),
        intent,
      );
    },
  );
  test('unknown file is not mistaken for own stable lock metadata', () async {
    final dir = await temporaryFixture();
    final store = FileTimeToolsStore(directory: () => dir);
    await store.put(TimeToolsState(revision: 1));
    final unknown = File('${dir.path}/future-private-shaped.json');
    await unknown.writeAsString('synthetic future bytes');
    expect((await store.load()).blocked, isTrue);
    await expectLater(
      store.put(TimeToolsState(revision: 2)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await unknown.readAsString(), 'synthetic future bytes');
    expect(await File('${dir.path}/state-r2.json').exists(), isFalse);
  });
}
