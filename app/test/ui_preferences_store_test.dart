import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

/// All bytes are synthetic memory. No APPDATA/Directory/File is evaluated.
class MemoryPreferencesBackend
    implements UiPreferencesFileBackend, UiPreferencesAtomicBackend {
  MemoryPreferencesBackend([String? initial]) {
    if (initial != null) files[canonicalPath] = initial;
  }
  @override
  final String canonicalPath = 'C:/synthetic-only/ui_config.json';
  final files = <String, String>{};
  final faults = <String>{};
  void Function()? afterFlush;
  void Function()? beforeBackup;
  int serial = 0, commits = 0;
  final committedRoots = <Map<String, dynamic>>[];
  bool _locked = false;
  @override
  T withWriterLock<T>(T Function() action) {
    _fail('lock');
    if (_locked) throw StateError('synthetic lock contention');
    _locked = true;
    try {
      return action();
    } finally {
      _locked = false;
    }
  }

  @override
  void renameNoReplace(String source, String target) => rename(source, target);
  void _fail(String stage) {
    if (faults.contains(stage)) throw StateError('synthetic ' + stage);
  }

  @override
  bool exists(String path) {
    _fail('exists');
    return files.containsKey(path);
  }

  @override
  String read(String path) {
    _fail('read');
    if (commits > 0 && path == canonicalPath) _fail('verify');
    return files[path]!;
  }

  @override
  List<String> backups() {
    _fail('backups');
    return files.keys
        .where((p) => p.startsWith(canonicalPath + '.timetrace-backup-'))
        .toList()
      ..sort();
  }

  @override
  void ensureParent() => _fail('prepare');
  @override
  void writeAndFlush(String path, String bytes) {
    _fail('writeAndFlush');
    files[path] = bytes;
    afterFlush?.call();
  }

  @override
  void rename(String source, String target) {
    final stage = source == canonicalPath
        ? 'backup'
        : source.contains('.timetrace-tmp-')
        ? 'commit'
        : 'rollback';
    _fail(stage);
    if (stage == 'backup') beforeBackup?.call();
    if (files.containsKey(target) || !files.containsKey(source)) {
      throw StateError('Refusing overwrite/missing source');
    }
    files[target] = files.remove(source)!;
    if (stage == 'commit') {
      commits++;
      committedRoots.add(jsonDecode(files[target]!) as Map<String, dynamic>);
    }
  }

  @override
  String nonce() => (++serial).toString().padLeft(8, '0');
}

Object? preferencesToken(MemoryPreferencesBackend backend) =>
    switch (UiPreferencesStore.readOutcome(backend: backend)) {
      UiPreferencesMissing(:final token) => token,
      UiPreferencesLoaded(:final token) => token,
      _ => null,
    };

void main() {
  test(
    'writer racing recheck is preserved from actual captured backup bytes',
    () {
      final backend = MemoryPreferencesBackend('{"version":1,"theme":"old"}');
      final token = preferencesToken(backend);
      const newer = '{"version":1,"theme":"new","external":{"keep":8}}';
      backend.beforeBackup = () => backend.files[backend.canonicalPath] = newer;
      final outcome = UiPreferencesStore.tryPatch(
        {'locale': 'zh'},
        expectedTargetToken: token,
        backend: backend,
      );
      expect(outcome, isA<UiPreferencesConflict>());
      expect(backend.files[backend.canonicalPath], newer);
      expect(backend.commits, 0);
    },
  );
  test('decodes a valid preferences document', () {
    expect(UiPreferencesStore.decode('{"version":1,"locale":"zh"}'), {
      'version': 1,
      'locale': 'zh',
    });
  });
  test('ignores malformed preferences documents', () {
    expect(UiPreferencesStore.decode('{not-json'), isEmpty);
    expect(UiPreferencesStore.decode('[]'), isEmpty);
  });
  test(
    'strict outcomes distinguish missing legacy loaded corrupt and future',
    () {
      final backend = MemoryPreferencesBackend();
      expect(
        UiPreferencesStore.readOutcome(backend: backend),
        isA<UiPreferencesMissing>(),
      );
      expect(
        UiPreferencesStore.decodeOutcome('{"extra":{"nested":[1]}}'),
        isA<UiPreferencesLoaded>(),
      );
      final loaded =
          UiPreferencesStore.decodeOutcome('{"extra":{"nested":[1]}}')
              as UiPreferencesLoaded;
      expect(
        () => (loaded.root['extra']['nested'] as List).add(2),
        throwsUnsupportedError,
      );
      expect(
        UiPreferencesStore.decodeOutcome('{"version":2}'),
        isA<UiPreferencesFuture>(),
      );
    },
  );
  for (final raw in [
    '',
    '{broken',
    '[]',
    'null',
    '{"version":0}',
    '{"version":"1"}',
    '{"version":1.5}',
    '{"version":2}',
  ]) {
    test('blocked root never overwrites bytes: ' + raw, () {
      final backend = MemoryPreferencesBackend(raw);
      final original = Map.of(backend.files);
      final result = UiPreferencesStore.tryPatch(
        {
          'order': ['bar'],
        },
        expectedTargetToken: '{}',
        backend: backend,
      );
      expect(result, isA<UiPreferencesBlocked>());
      UiPreferencesStore.update({'dark': true}, backend: backend);
      expect(backend.files, original);
      expect(backend.commits, 0);
    });
  }
  for (final fault in ['exists', 'read', 'backups']) {
    test('read fault not confused with missing: ' + fault, () {
      final backend = MemoryPreferencesBackend(
        fault == 'backups' ? null : '{"version":1}',
      );
      backend.faults.add(fault);
      final original = Map.of(backend.files);
      expect(
        UiPreferencesStore.readOutcome(backend: backend),
        isA<UiPreferencesUnreadable>(),
      );
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: '{}',
          backend: backend,
        ),
        isA<UiPreferencesBlocked>(),
      );
      UiPreferencesStore.update({'dark': true}, backend: backend);
      expect(backend.files, original);
    });
  }
  for (final fault in ['prepare', 'writeAndFlush', 'backup', 'commit']) {
    test('commit stage failure preserves preimage and retry: ' + fault, () {
      const original =
          '{"version":1,"wallpaper":"synthetic","unknown":{"a":[1,2]}}';
      final backend = MemoryPreferencesBackend(original);
      final token = preferencesToken(backend);
      backend.faults.add(fault);
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesFailed>(),
      );
      expect(backend.files[backend.canonicalPath], original);
      backend.faults.clear();
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesCommitted>(),
      );
      final root = UiPreferencesStore.read(backend: backend);
      expect(root['unknown'], {
        'a': [1, 2],
      });
      expect(root['wallpaper'], 'synthetic');
      expect(root['dark'], true);
    });
  }
  test(
    'rollback failure leaves recovery bytes and cannot initialize missing',
    () {
      const original = '{"version":1,"wallpaper":"synthetic","unknown":9}';
      final backend = MemoryPreferencesBackend(original);
      final token = preferencesToken(backend);
      backend.faults.addAll(['commit', 'rollback']);
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesFailed>(),
      );
      expect(backend.files.containsKey(backend.canonicalPath), isFalse);
      final outcome =
          UiPreferencesStore.readOutcome(backend: backend)
              as UiPreferencesUnreadable;
      expect(outcome.reason, 'recoveryRequired');
      expect(outcome.recoverable!.originalBytes, original);
      final retained = Map.of(backend.files);
      UiPreferencesStore.update({'dark': false}, backend: backend);
      expect(backend.files, retained);
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesBlocked>(),
      );
      backend.faults.clear();
      expect(
        UiPreferencesStore.restoreRecovery(outcome, backend: backend),
        isA<UiPreferencesCommitted>(),
      );
      expect(backend.files[backend.canonicalPath], original);
    },
  );
  test('recovery cannot overwrite a later canonical file', () {
    final backend = MemoryPreferencesBackend();
    backend.files[backend.canonicalPath + '.timetrace-backup-1'] =
        '{"version":1,"old":1}';
    final recovery =
        UiPreferencesStore.readOutcome(backend: backend)
            as UiPreferencesUnreadable;
    backend.files[backend.canonicalPath] = '{"version":1,"new":2}';
    expect(
      UiPreferencesStore.restoreRecovery(recovery, backend: backend),
      isA<UiPreferencesConflict>(),
    );
    expect(backend.files[backend.canonicalPath], '{"version":1,"new":2}');
  });
  test('unrelated fresh root keys merged; target changes conflict', () {
    final backend = MemoryPreferencesBackend(
      '{"version":1,"wallpaper":"old","order":["bar"]}',
    );
    final token = preferencesToken(backend);
    backend.files[backend.canonicalPath] =
        '{"version":1,"wallpaper":"new","order":["bar"],"unknown":[1]}';
    expect(
      UiPreferencesStore.tryPatch(
        {'dark': true},
        expectedTargetToken: token,
        backend: backend,
      ),
      isA<UiPreferencesCommitted>(),
    );
    expect(UiPreferencesStore.read(backend: backend)['wallpaper'], 'new');
    backend.files[backend.canonicalPath] = '{"version":1,"order":["apps"]}';
    final bytes = backend.files[backend.canonicalPath];
    expect(
      UiPreferencesStore.tryPatch(
        {'dark': false},
        expectedTargetToken: token,
        backend: backend,
      ),
      isA<UiPreferencesConflict>(),
    );
    expect(backend.files[backend.canonicalPath], bytes);
  });
  for (final key in ['workspaceComponentsV1', 'workspaceGroupsV2']) {
    test('first migration token binds changed legacy source: ' + key, () {
      final value = key.endsWith('V1') ? '["data"]' : '[["bar"]]';
      final changed = key.endsWith('V1') ? '["calendar"]' : '[["calendar"]]';
      final backend = MemoryPreferencesBackend(
        '{"version":1,"' + key + '":' + value + '}',
      );
      final token = preferencesToken(backend);
      backend.files[backend.canonicalPath] =
          '{"version":1,"' + key + '":' + changed + '}';
      final original = Map.of(backend.files);
      expect(
        UiPreferencesStore.tryPatch(
          {'workspaceLayoutV3': {}},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesConflict>(),
      );
      expect(backend.files, original);
    });
  }
  test('root changes during flush abort final commit without overwriting', () {
    final backend = MemoryPreferencesBackend('{"version":1,"order":["bar"]}');
    final token = preferencesToken(backend);
    backend.afterFlush = () => backend.files[backend.canonicalPath] =
        '{"version":1,"order":["bar"],"new":9}';
    expect(
      UiPreferencesStore.tryPatch(
        {'dark': true},
        expectedTargetToken: token,
        backend: backend,
      ),
      isA<UiPreferencesConflict>(),
    );
    expect(
      backend.files[backend.canonicalPath],
      '{"version":1,"order":["bar"],"new":9}',
    );
    expect(backend.commits, 0);
  });
  test(
    'verification read failure is not a successful ack, preimage survives',
    () {
      final backend = MemoryPreferencesBackend('{"version":1,"old":1}');
      final token = preferencesToken(backend);
      backend.faults.add('verify');
      expect(
        UiPreferencesStore.tryPatch(
          {'dark': true},
          expectedTargetToken: token,
          backend: backend,
        ),
        isA<UiPreferencesFailed>(),
      );
      expect(
        backend.backups().map((p) => backend.files[p]),
        contains('{"version":1,"old":1}'),
      );
    },
  );
}
