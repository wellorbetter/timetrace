import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences/ui_preferences_store.dart';
import '../../../core/workspace/workspace_model.dart' as core;
import '../../../core/workspace/workspace_controller.dart' as controller;

enum WorkspaceComponent {
  bar,
  summary,
  apps,
  hourly,
  calendar,
  diary,
  pomodoro,
  tasks,
  countdown,
  dailyPoetry,
}

extension WorkspaceComponentLabel on WorkspaceComponent {
  String get label => switch (this) {
    WorkspaceComponent.bar => '应用时长',
    WorkspaceComponent.summary => '使用汇总',
    WorkspaceComponent.apps => '应用明细',
    WorkspaceComponent.hourly => '时段分布',
    WorkspaceComponent.calendar => '日历',
    WorkspaceComponent.diary => '日记',
    WorkspaceComponent.pomodoro => '番茄钟',
    WorkspaceComponent.tasks => '任务清单',
    WorkspaceComponent.countdown => '倒计时',
    WorkspaceComponent.dailyPoetry => '每日诗词',
  };
  bool get isData => defaultDataComponents.contains(this);
  core.WorkspaceSize get defaultSize => switch (this) {
    WorkspaceComponent.diary => core.WorkspaceSize.fullNatural,
    WorkspaceComponent.pomodoro ||
    WorkspaceComponent.countdown => core.WorkspaceSize.oneByOne,
    WorkspaceComponent.dailyPoetry => core.WorkspaceSize.twoByOne,
    _ => core.WorkspaceSize.twoByTwo,
  };
}

typedef WorkspaceGroups = List<List<WorkspaceComponent>>;

class WorkspaceDrag {
  WorkspaceDrag(Iterable<WorkspaceComponent> members)
    : members = List.unmodifiable(members);
  final List<WorkspaceComponent> members;
  WorkspaceComponent get first => members.first;
  core.WorkspaceDrag get coreDrag =>
      core.WorkspaceDrag(members.map((e) => e.name));
}

const defaultDataComponents = [
  WorkspaceComponent.bar,
  WorkspaceComponent.summary,
  WorkspaceComponent.apps,
  WorkspaceComponent.hourly,
];
final _defaults = core.WorkspaceDocument(
  groups: [
    ['calendar'],
    defaultDataComponents.map((e) => e.name),
    ['diary'],
  ],
);
const _dataIds = ['bar', 'summary', 'apps', 'hourly'];

core.WorkspaceDecode decodeDashboardWorkspace(Map<String, dynamic> root) =>
    core.decodeWorkspaceDocument(
      root,
      defaults: _defaults,
      legacyDataIds: _dataIds,
      legacyDataMarker: 'data',
    );

WorkspaceGroups projectWorkspaceGroups(core.WorkspaceDocument document) =>
    List.unmodifiable([
      for (final group in document.groups)
        if (group.any(
          (id) => WorkspaceComponent.values.any((e) => e.name == id),
        ))
          List<WorkspaceComponent>.unmodifiable([
            for (final id in group)
              for (final e in WorkspaceComponent.values)
                if (e.name == id) e,
          ]),
    ]);

WorkspaceGroups decodeWorkspaceGroups(Map<String, dynamic> prefs) {
  if (prefs.containsKey('workspaceLayoutV3')) {
    return projectWorkspaceGroups(decodeDashboardWorkspace(prefs).document);
  }
  final order = <WorkspaceComponent>{
    if (prefs['order'] is List)
      for (final name in prefs['order'] as List)
        for (final component in defaultDataComponents)
          if (component.name == name) component,
    ...defaultDataComponents,
  }.toList();
  final raw = prefs['workspaceGroupsV2'];
  final legacy = prefs['workspaceComponentsV1'];
  final List<dynamic> groups;
  if (raw is List) {
    groups = raw;
  } else if (legacy is List) {
    groups = [
      for (final name in legacy)
        if (name == 'data') order.map((item) => item.name).toList() else [name],
    ];
  } else {
    if (!prefs.containsKey('workspaceGroupsV2') &&
        !prefs.containsKey('workspaceComponentsV1') &&
        !prefs.containsKey('order')) {
      return projectWorkspaceGroups(_defaults);
    }
    return [List.unmodifiable(order)];
  }
  final seen = <WorkspaceComponent>{};
  return List.unmodifiable(
    [
          for (final group in groups)
            if (group is List)
              [
                for (final name in group)
                  for (final component in WorkspaceComponent.values)
                    if (name == component.name && seen.add(component))
                      component,
              ],
        ]
        .where((group) => group.isNotEmpty)
        .map((group) => List<WorkspaceComponent>.unmodifiable(group)),
  );
}

class WorkspaceLayoutStore implements core.WorkspaceLayoutStore {
  WorkspaceLayoutStore({this.backend});
  final UiPreferencesFileBackend? backend;
  UiPreferencesReadOutcome? lastRead;
  UiPreferencesLoaded? _unverified;
  Object? _unverifiedOriginalToken;

  core.WorkspaceRootOutcome _root(UiPreferencesReadOutcome result) =>
      switch (result) {
        UiPreferencesMissing() => core.WorkspaceRootMissing(
          targetToken: result.token,
        ),
        UiPreferencesLoaded() => core.WorkspaceRootLoaded(
          result.root,
          targetToken: result.token,
          originalBytes: result.originalBytes,
        ),
        UiPreferencesUnreadable() => core.WorkspaceRootUnreadable(
          result.reason,
        ),
        UiPreferencesFuture() => core.WorkspaceRootFuture(result.version),
      };

  @override
  core.WorkspaceRootOutcome loadRoot() {
    lastRead = UiPreferencesStore.readOutcome(backend: backend);
    return _root(lastRead!);
  }

  @override
  FutureOr<core.WorkspaceWriteOutcome> writePatch(core.WorkspacePatch patch) {
    if (patch.values.keys.any(
      (key) => key != 'workspaceLayoutV3' && key != 'order',
    )) {
      return const core.WorkspaceWriteFailed('Unexpected workspace patch');
    }
    var expected = patch.expectedTargetToken;
    if (_unverified != null && expected == _unverifiedOriginalToken) {
      final current = UiPreferencesStore.readOutcome(backend: backend);
      lastRead = current;
      if (current is UiPreferencesUnreadable) {
        return const core.WorkspaceWriteFailed('verify');
      }
      if (current is UiPreferencesFuture) {
        return core.WorkspaceWriteBlocked(_root(current));
      }
      if (current is! UiPreferencesLoaded ||
          current.token != _unverified!.token ||
          !decodeDashboardWorkspace(current.root).writable) {
        return const core.WorkspaceWriteConflict();
      }
      expected = current.token;
    }
    final values = Map<String, dynamic>.from(patch.values);
    // The core knows only the four data IDs. Legacy order may also contain
    // future IDs; retain their original relative slots while replacing known
    // entries with the current visible known order.
    final orderRoot = UiPreferencesStore.readOutcome(backend: backend);
    if (orderRoot is UiPreferencesLoaded &&
        orderRoot.root['order'] is List &&
        values['order'] is List) {
      final known = (values['order'] as List)
          .whereType<String>()
          .where(_dataIds.contains)
          .toList();
      var index = 0;
      values['order'] = <String>[
        for (final id in orderRoot.root['order'] as List)
          if (id is String)
            if (!_dataIds.contains(id))
              id
            else if (index < known.length)
              known[index++],
        ...known.skip(index),
      ];
    }
    final result = UiPreferencesStore.tryPatch(
      values,
      expectedTargetToken: expected,
      backend: backend,
      validateRoot: (root) => decodeDashboardWorkspace(root).writable,
    );
    if (result is UiPreferencesFailed && result.unverifiedSnapshot != null) {
      _unverified = result.unverifiedSnapshot;
      _unverifiedOriginalToken = patch.expectedTargetToken;
    } else if (result is UiPreferencesCommitted) {
      _unverified = null;
      _unverifiedOriginalToken = null;
    }
    lastRead = result is UiPreferencesCommitted
        ? result.snapshot
        : UiPreferencesStore.readOutcome(backend: backend);
    return switch (result) {
      UiPreferencesCommitted() => core.WorkspaceWriteCommitted(
        snapshot: _root(result.snapshot) as core.WorkspaceRootLoaded,
        revision: patch.revision,
      ),
      UiPreferencesBlocked() => core.WorkspaceWriteBlocked(
        _root(result.reason),
      ),
      UiPreferencesConflict() => const core.WorkspaceWriteConflict(),
      UiPreferencesFailed() => core.WorkspaceWriteFailed(result.stage),
    };
  }

  UiPreferencesWriteOutcome restoreRecovery() {
    final current = lastRead = UiPreferencesStore.readOutcome(backend: backend);
    return current is UiPreferencesUnreadable
        ? UiPreferencesStore.restoreRecovery(current, backend: backend)
        : const UiPreferencesConflict();
  }
}

final workspaceLayoutStoreProvider = Provider<WorkspaceLayoutStore>(
  (ref) => WorkspaceLayoutStore(),
);

/// The sole write authority is the approved core controller.
class WorkspaceDocumentNotifier
    extends Notifier<controller.WorkspaceControllerState> {
  late controller.WorkspaceController _controller;
  Future<void>? _initialLoad;
  @override
  controller.WorkspaceControllerState build() {
    _controller = controller.WorkspaceController(
      store: ref.read(workspaceLayoutStoreProvider),
      defaults: _defaults,
      legacyDataIds: _dataIds,
      legacyDataMarker: 'data',
      onChanged: (next) {
        if (ref.mounted) state = _visibleState(next);
      },
    );
    ref.onDispose(_controller.dispose);
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(ensureLoaded());
    });
    return _controller.state;
  }

  controller.WorkspaceControllerState _visibleState(
    controller.WorkspaceControllerState next,
  ) {
    final root = ref.read(workspaceLayoutStoreProvider).lastRead;
    if (!next.writable &&
        root is UiPreferencesUnreadable &&
        root.recoverable != null) {
      final decoded = decodeDashboardWorkspace(root.recoverable!.root);
      if (decoded.writable && !next.dirty) {
        return controller.WorkspaceControllerState(
          document: decoded.document,
          revision: next.revision,
          loading: next.loading,
          writable: false,
          dirty: false,
          error: next.error,
        );
      }
    }
    return next;
  }

  Future<void> ensureLoaded() => _initialLoad ??= _controller.load();
  Future<void> reload({bool discardChanges = false}) async {
    await ensureLoaded();
    if (ref.mounted) await _controller.load(discardChanges: discardChanges);
  }

  Future<void> retrySave() => _controller.retrySave();
  Future<void> restoreRecovery() async {
    final result = ref.read(workspaceLayoutStoreProvider).restoreRecovery();
    if (ref.mounted && result is UiPreferencesCommitted) {
      await _controller.load();
    }
  }

  Future<void> perform(core.WorkspaceAction action) async {
    await ensureLoaded();
    if (ref.mounted) await _controller.perform(action);
  }

  Future<void> reorderData(List<String> order) async {
    await ensureLoaded();
    if (ref.mounted) await _controller.reorderData(order);
  }

  Future<void> resetKnown() async {
    await ensureLoaded();
    if (!ref.mounted) return;
    // Establish the complete user intent before the first asynchronous ack.
    // All actions still use the sole controller and preserve foreign IDs.
    final hiding = _controller.hideGroup(
      core.WorkspaceDrag(WorkspaceComponent.values.map((e) => e.name)),
    );
    final placing = [
      for (var i = 0; i < _defaults.groups.length; i++)
        _controller.placeGroup(core.WorkspaceDrag(_defaults.groups[i]), i),
    ];
    final resizing = [
      for (final component in WorkspaceComponent.values)
        _controller.setSize(
          component.name,
          _defaults.sizes[component.name] ?? component.defaultSize,
        ),
    ];
    await Future.wait([hiding, ...placing, ...resizing]);
  }

  int fullBoundary(int projectionIndex) {
    final groups = _controller.state.document.groups;
    final visible = groups
        .where(
          (g) =>
              g.any((id) => WorkspaceComponent.values.any((e) => e.name == id)),
        )
        .toList();
    if (projectionIndex >= visible.length) return groups.length;
    if (projectionIndex < 0) return 0;
    return groups.indexOf(visible[projectionIndex]);
  }
}

final workspaceDocumentProvider =
    NotifierProvider<
      WorkspaceDocumentNotifier,
      controller.WorkspaceControllerState
    >(WorkspaceDocumentNotifier.new);

/// Public legacy projection: unknown IDs remain in the authoritative document.
class WorkspaceLayoutNotifier extends Notifier<WorkspaceGroups> {
  @override
  WorkspaceGroups build() =>
      projectWorkspaceGroups(ref.watch(workspaceDocumentProvider).document);
  WorkspaceDocumentNotifier get _document =>
      ref.read(workspaceDocumentProvider.notifier);

  Future<void> placeGroup(WorkspaceDrag drag, int position) async {
    await _document.ensureLoaded();
    await _document.perform(
      core.WorkspaceAction(
        core.WorkspaceActionKind.place,
        drag: drag.coreDrag,
        index: _document.fullBoundary(position),
      ),
    );
  }

  Future<void> stackGroup(WorkspaceDrag drag, WorkspaceComponent target) =>
      _document.perform(
        core.WorkspaceAction(
          core.WorkspaceActionKind.stack,
          drag: drag.coreDrag,
          id: target.name,
        ),
      );
  Future<void> hideGroup(WorkspaceDrag drag) => _document.perform(
    core.WorkspaceAction(core.WorkspaceActionKind.hide, drag: drag.coreDrag),
  );
  Future<void> place(WorkspaceComponent component, int position) =>
      placeGroup(WorkspaceDrag([component]), position);
  Future<void> stack(WorkspaceComponent component, WorkspaceComponent target) =>
      stackGroup(WorkspaceDrag([component]), target);
  Future<void> hide(WorkspaceComponent component) =>
      hideGroup(WorkspaceDrag([component]));
  Future<void> moveGroup(int from, int delta) async {
    await _document.ensureLoaded();
    final groups = state;
    final to = from + delta;
    if (from < 0 || from >= groups.length || to < 0 || to >= groups.length)
      return;
    await placeGroup(WorkspaceDrag(groups[from]), to + (delta > 0 ? 1 : 0));
  }

  Future<void> reveal(WorkspaceComponent component) => _document.perform(
    core.WorkspaceAction(core.WorkspaceActionKind.reveal, id: component.name),
  );
  Future<void> setSize(WorkspaceComponent component, core.WorkspaceSize size) =>
      _document.perform(
        core.WorkspaceAction(
          core.WorkspaceActionKind.resize,
          id: component.name,
          size: size,
        ),
      );
  Future<void> reorderData(List<String> order) => _document.reorderData(order);
  Future<void> reset() async {
    await _document.resetKnown();
  }
}

final workspaceLayoutProvider =
    NotifierProvider<WorkspaceLayoutNotifier, WorkspaceGroups>(
      WorkspaceLayoutNotifier.new,
    );

class WorkspaceEditNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void start() => state = true;
}

final workspaceEditProvider = NotifierProvider<WorkspaceEditNotifier, bool>(
  WorkspaceEditNotifier.new,
);

class WorkspaceShelfNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

/// Browsing visibility is independent of editing and component placement.
final workspaceShelfOpenProvider =
    NotifierProvider<WorkspaceShelfNotifier, bool>(WorkspaceShelfNotifier.new);

typedef WorkspaceFocus = ({WorkspaceComponent component, int revision});

class WorkspaceFocusNotifier extends Notifier<WorkspaceFocus?> {
  @override
  WorkspaceFocus? build() => null;
  void select(WorkspaceComponent component) =>
      state = (component: component, revision: (state?.revision ?? 0) + 1);
}

final workspaceFocusProvider =
    NotifierProvider<WorkspaceFocusNotifier, WorkspaceFocus?>(
      WorkspaceFocusNotifier.new,
    );
