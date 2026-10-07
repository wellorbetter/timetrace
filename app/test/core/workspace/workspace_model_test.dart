import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/core/workspace/workspace_controller.dart';

WorkspaceDocument document(List<List<String>> groups) =>
    WorkspaceDocument(groups: groups);

class MemoryStore implements WorkspaceLayoutStore {
  MemoryStore(this.root);
  WorkspaceRootOutcome root;
  final patches = <WorkspacePatch>[];
  Completer<WorkspaceRootOutcome>? pendingLoad;
  Completer<WorkspaceWriteOutcome>? pendingWrite;
  WorkspaceWriteOutcome? failure;
  int token = 0;
  @override
  Future<WorkspaceRootOutcome> loadRoot() async {
    final pending = pendingLoad;
    if (pending != null) return pending.future;
    return root;
  }

  @override
  Future<WorkspaceWriteOutcome> writePatch(WorkspacePatch patch) async {
    patches.add(patch);
    final pending = pendingWrite;
    pendingWrite = null;
    if (pending != null) return pending.future;
    if (failure != null) return failure!;
    final previous = root;
    if (previous is WorkspaceRootUnreadable || previous is WorkspaceRootFuture)
      return WorkspaceWriteBlocked(previous);
    final expected = previous is WorkspaceRootLoaded
        ? previous.targetToken
        : (previous as WorkspaceRootMissing).targetToken;
    if (expected != patch.expectedTargetToken)
      return const WorkspaceWriteConflict();
    final snapshot = WorkspaceRootLoaded({
      if (previous is WorkspaceRootLoaded) ...previous.root,
      ...patch.values,
    }, targetToken: 'token-${++token}');
    root = snapshot;
    return WorkspaceWriteCommitted(
      snapshot: snapshot,
      revision: patch.revision,
    );
  }
}

Future<WorkspaceController> controller(
  MemoryStore store, {
  List<List<String>> groups = const [
    ['a', 'b'],
  ],
  List<String> dataIds = const [],
}) async {
  final value = WorkspaceController(
    store: store,
    defaults: document(groups),
    legacyDataIds: dataIds,
  );
  addTearDown(value.dispose);
  await value.load();
  return value;
}

void main() {
  test('complete missing defaults do not bleed sizes into legacy intentions', () {
    final defaults = WorkspaceDocument(
      groups: [
        ['calendar'],
        ['a', 'b'],
        ['diary'],
        ['dailyPoetry'],
      ],
      sizes: {'dailyPoetry': WorkspaceSize.fullNatural},
    );
    WorkspaceDecode decode(Map<String, Object?> root) => decodeWorkspaceDocument(
      root,
      defaults: defaults,
      legacyDataIds: ['a', 'b'],
      legacyDataMarker: 'data',
    );
    for (final root in <Map<String, Object?>>[{}, {'version': 1}]) {
      final decoded = decode(root);
      expect(decoded.writable, isTrue);
      expect(decoded.document.groups, defaults.groups);
      expect(
        decoded.document.sizes['dailyPoetry']!.sameExtent(WorkspaceSize.fullNatural),
        isTrue,
      );
    }
    for (final root in <Map<String, Object?>>[
      {'order': ['b']},
      {'order': []},
      {'workspaceGroupsV2': [['dailyPoetry'], ['foreign']]},
      {'workspaceComponentsV1': ['dailyPoetry', 'data', 'foreign']},
      {'workspaceGroupsV2': []},
      {'workspaceComponentsV1': []},
    ]) {
      final decoded = decode(root);
      expect(decoded.writable, isTrue);
      expect(decoded.document.sizes, isEmpty);
      if (root.containsKey('order')) {
        expect(decoded.document.groups, [
          root['order'] is List && (root['order'] as List).isNotEmpty
              ? ['b', 'a']
              : ['a', 'b'],
        ]);
      } else if ((root.values.single as List).isEmpty) {
        expect(decoded.document.groups, isEmpty);
      }
    }
    final custom = WorkspaceDocument(
      groups: [['dailyPoetry', 'foreign']],
      sizes: {'foreign': const WorkspaceSize(2, 3, metadata: {'retain': 7})},
      metadata: {'opaque': [1, 2]},
    );
    final v3 = decode({'workspaceLayoutV3': custom.toJson()});
    expect(v3.document.toJson(), custom.toJson());
    expect(v3.document.sizes.containsKey('dailyPoetry'), isFalse);
    for (final invalid in <Object?>[
      null,
      {'version': 4, 'groups': [], 'sizes': {}},
      {'version': 3, 'groups': [['calendar', 'calendar']], 'sizes': {}},
    ]) {
      final result = decode({
        'workspaceLayoutV3': invalid,
        'workspaceGroupsV2': [['a']],
      });
      expect(result.writable, isFalse);
    }
  });
  for (final missing in [true, false]) {
    test('new four-group missing default load performs zero writes $missing', () async {
      final defaults = WorkspaceDocument(
        groups: [['calendar'], ['a', 'b'], ['diary'], ['dailyPoetry']],
        sizes: {'dailyPoetry': WorkspaceSize.fullNatural},
      );
      final store = MemoryStore(
        missing
            ? const WorkspaceRootMissing()
            : WorkspaceRootLoaded({'version': 1, 'other': {'keep': 7}}, targetToken: 'old'),
      );
      final value = WorkspaceController(
        store: store,
        defaults: defaults,
        legacyDataIds: ['a', 'b'],
      );
      addTearDown(value.dispose);
      await value.load();
      expect(value.state.document.toJson(), defaults.toJson());
      expect(value.state.writable, isTrue);
      expect(value.state.dirty, isFalse);
      expect(store.patches, isEmpty);
      if (!missing) {
        expect((store.root as WorkspaceRootLoaded).root['other'], {'keep': 7});
      }
    });
  }

  test(
    'V3 roundtrip preserves unknown IDs and nested opaque metadata immutably',
    () {
      final metadata = <String, Object?>{
        'foreign': [
          1,
          {'keep': true},
        ],
      };
      final doc = WorkspaceDocument(
        groups: [
          ['third-party', 'a'],
        ],
        sizes: {'third-party': WorkspaceSize(2, 3, metadata: metadata)},
        metadata: {
          'layoutExtra': {'yes': true},
        },
      );
      (metadata['foreign'] as List).add(9);
      final restored = WorkspaceDocument.fromJson(doc.toJson());
      expect(restored.groups, [
        ['third-party', 'a'],
      ]);
      expect(restored.sizes['third-party']!.metadata['foreign'], hasLength(2));
      expect(restored.metadata, doc.metadata);
      expect(() => doc.groups.first.add('x'), throwsUnsupportedError);
      expect(
        () => (doc.sizes['third-party']!.metadata['foreign'] as List).add(3),
        throwsUnsupportedError,
      );
    },
  );
  test('legacy order/V1 expansion is injected; unknown IDs and explicit empty survive', () {
    final defaults = document([
      ['a', 'b'],
    ]);
    final result = decodeWorkspaceDocument(
      {
        'order': ['b'],
        'workspaceComponentsV1': ['foreign', 'data', 'last'],
      },
      defaults: defaults,
      legacyDataIds: ['a', 'b'],
      legacyDataMarker: 'data',
    );
    expect(result.document.groups, [
      ['foreign'],
      ['b', 'a'],
      ['last'],
    ]);
    expect(
      decodeWorkspaceDocument({
        'workspaceGroupsV2': [],
        'workspaceComponentsV1': ['data'],
      }, defaults: defaults).document.groups,
      isEmpty,
    );
    expect(
      decodeWorkspaceDocument({
        'workspaceComponentsV1': [],
      }, defaults: defaults).document.groups,
      isEmpty,
    );
    expect(
      decodeWorkspaceDocument({
        'workspaceGroupsV2': [
          ['alien', 'a', 'alien'],
          ['a', 'b'],
        ],
      }, defaults: defaults).document.groups,
      [
        ['alien', 'a'],
        ['b'],
      ],
    );
  });
  for (final raw in [
    null,
    [],
    {'version': 4, 'groups': [], 'sizes': {}},
    {
      'version': 3,
      'groups': [
        ['a', 'a'],
      ],
      'sizes': {},
    },
    {
      'version': 3,
      'groups': [],
      'sizes': {
        'a': {'colSpan': 9, 'rowSpan': 1},
      },
    },
  ]) {
    test(
      'invalid/future V3 cannot silently fall through to writable V2: $raw',
      () {
        final result = decodeWorkspaceDocument({
          'workspaceLayoutV3': raw,
          'workspaceGroupsV2': [
            ['a'],
          ],
        }, defaults: document([]));
        expect(result.writable, isFalse);
      },
    );
  }
  for (final root in [
    const WorkspaceRootUnreadable('corrupt'),
    const WorkspaceRootUnreadable('io'),
    const WorkspaceRootFuture(9),
    WorkspaceRootLoaded({'workspaceGroupsV2': 'bad'}, targetToken: 't'),
  ]) {
    test('unsafe root/layout blocks all actions including reset', () async {
      final store = MemoryStore(root);
      final value = await controller(store);
      expect(value.state.writable, isFalse);
      await value.placeGroup(WorkspaceDrag(['x']), 0);
      await value.hideGroup(WorkspaceDrag(['a']));
      await value.reset();
      await value.setSize('a', WorkspaceSize.oneByOne);
      expect(store.patches, isEmpty);
      expect(value.state.dirty, isFalse);
    });
  }
  test('missing permits first explicit action, but load/migration performs zero writes', () async {
    final store = MemoryStore(const WorkspaceRootMissing());
    final value = await controller(store);
    expect(store.patches, isEmpty);
    await value.reveal('x');
    expect(store.patches, hasLength(1));
    expect(value.state.document.groups, [
      ['a', 'b'],
      ['x'],
    ]);
    expect(value.state.dirty, isFalse);
  });
  test(
    'index source deduction before/after/clamp/self preserves whole group',
    () async {
      final store = MemoryStore(
        WorkspaceRootLoaded({
          'workspaceGroupsV2': [
            ['a', 'b'],
            ['c'],
            ['d', 'e'],
            ['z'],
          ],
        }, targetToken: 't'),
      );
      final value = await controller(store);
      final drag = WorkspaceDrag(['a', 'b']);
      await value.placeGroup(drag, 2);
      expect(value.state.document.groups, [
        ['c'],
        ['a', 'b'],
        ['d', 'e'],
        ['z'],
      ]);
      await value.placeGroup(drag, 999);
      expect(value.state.document.groups.last, ['a', 'b']);
      await value.placeGroup(drag, -10);
      expect(value.state.document.groups.first, ['a', 'b']);
      final count = store.patches.length;
      await value.placeGroup(drag, 0);
      await value.stackGroup(drag, 'a');
      expect(store.patches.length, count);
      await value.stackGroup(drag, 'd');
      expect(value.state.document.groups, [
        ['c'],
        ['d', 'e', 'a', 'b'],
        ['z'],
      ]);
      await value.detach('a', 2);
      expect(value.state.document.groups, [
        ['c'],
        ['d', 'e', 'b'],
        ['a'],
        ['z'],
      ]);
      await value.moveGroup(2, -1);
      expect(value.state.document.groups[1], ['a']);
      await value.hideGroup(WorkspaceDrag(['d', 'e', 'b']));
      expect(value.state.document.groups, [
        ['c'],
        ['a'],
        ['z'],
      ]);
      await value.reveal('d');
      expect(value.state.document.groups.last, ['d']);
    },
  );
  test(
    'data ordering delegates pure IDs and leaves unknown/nondata slots intact',
    () async {
      final store = MemoryStore(
        WorkspaceRootLoaded({
          'background': {'keep': 1},
          'workspaceGroupsV2': [
            ['foreign', 'a'],
            ['middle', 'b', 'last'],
          ],
        }, targetToken: 't'),
      );
      final value = await controller(store, dataIds: ['a', 'b']);
      await value.reorderData(['b', 'a']);
      expect(value.state.document.groups, [
        ['foreign', 'b'],
        ['middle', 'a', 'last'],
      ]);
      expect(
        store.patches.single.values.keys,
        unorderedEquals(['workspaceLayoutV3', 'order']),
      );
      expect((store.root as WorkspaceRootLoaded).root['background'], {
        'keep': 1,
      });
    },
  );
  test('failed write retains latest dirty document; retry only commits current revision', () async {
    final store = MemoryStore(const WorkspaceRootMissing())
      ..failure = const WorkspaceWriteFailed('fixture');
    final value = await controller(store);
    await value.reveal('x');
    await value.reveal('y');
    expect(value.state.dirty, isTrue);
    expect(value.state.error, isNotNull);
    final revision = value.state.revision;
    store.failure = null;
    await value.retrySave();
    expect(store.patches.last.revision, revision);
    expect(value.state.document.groups.last, ['y']);
    expect(value.state.dirty, isFalse);
  });
  test('late ack cannot clear newer dirty revision and next patch uses returned token', () async {
    final store = MemoryStore(const WorkspaceRootMissing());
    final value = await controller(store);
    store.pendingWrite = Completer<WorkspaceWriteOutcome>();
    final pending = store.pendingWrite!;
    final first = value.reveal('x');
    final snapshot = store.patches.single;
    final second = value.reveal('y');
    expect(value.state.dirty, isTrue);
    final ack = WorkspaceRootLoaded(snapshot.values, targetToken: 'ack');
    store.root = ack;
    pending.complete(
      WorkspaceWriteCommitted(snapshot: ack, revision: snapshot.revision),
    );
    await first;
    await second;
    expect(store.patches, hasLength(2));
    expect(store.patches.last.expectedTargetToken, 'ack');
    expect(value.state.document.groups, [
      ['a', 'b'],
      ['x'],
      ['y'],
    ]);
    expect(value.state.dirty, isFalse);
  });
  test(
    'late load during acknowledged write cannot replace newer document',
    () async {
      final store = MemoryStore(const WorkspaceRootMissing());
      final value = await controller(store);
      store.pendingWrite = Completer<WorkspaceWriteOutcome>();
      final write = store.pendingWrite!;
      final saving = value.reveal('x');
      final patch = store.patches.single;
      store.pendingLoad = Completer<WorkspaceRootOutcome>();
      final loading = value.load();
      final ack = WorkspaceRootLoaded(patch.values, targetToken: 'ack');
      store.root = ack;
      write.complete(
        WorkspaceWriteCommitted(snapshot: ack, revision: patch.revision),
      );
      await saving;
      store.pendingLoad!.complete(const WorkspaceRootMissing());
      await loading;
      expect(value.state.document.groups.last, ['x']);
      expect(value.state.writable, isTrue);
    },
  );
  test('blocked/conflict leave dirty and retry load needs explicit conflict resolution', () async {
    final store = MemoryStore(const WorkspaceRootMissing())
      ..failure = const WorkspaceWriteConflict();
    final value = await controller(store);
    await value.reveal('x');
    expect(value.state.dirty, isTrue);
    expect(value.state.writable, isFalse);
    store.root = WorkspaceRootLoaded({
      'workspaceGroupsV2': [
        ['external'],
      ],
    }, targetToken: 'changed');
    await value.load();
    expect(value.state.writable, isFalse);
    expect(value.state.document.groups.last, ['x']);
    await value.load(discardChanges: true);
    expect(value.state.document.groups, [
      ['external'],
    ]);
    expect(value.state.dirty, isFalse);
  });
  test('disposed pending load/write never notify or continue writes', () async {
    final store = MemoryStore(const WorkspaceRootMissing());
    var changes = 0;
    final value = WorkspaceController(
      store: store,
      defaults: document([]),
      onChanged: (_) => changes++,
    );
    store.pendingLoad = Completer<WorkspaceRootOutcome>();
    final loading = value.load();
    value.dispose();
    final count = changes;
    store.pendingLoad!.complete(const WorkspaceRootMissing());
    await loading;
    expect(changes, count);
    expect(store.patches, isEmpty);
    final liveStore = MemoryStore(const WorkspaceRootMissing());
    final live = await controller(liveStore);
    liveStore.pendingWrite = Completer<WorkspaceWriteOutcome>();
    final write = liveStore.pendingWrite!;
    final saving = live.reveal('x');
    live.dispose();
    write.complete(
      WorkspaceWriteCommitted(
        snapshot: WorkspaceRootLoaded({}, targetToken: 'x'),
        revision: live.state.revision,
      ),
    );
    await saving;
    expect(liveStore.patches, hasLength(1));
  });
}
