import 'dart:convert';

import 'workspace_model.dart';

class WorkspaceControllerState {
  const WorkspaceControllerState({
    required this.document,
    this.revision = 0,
    this.loading = true,
    this.writable = false,
    this.dirty = false,
    this.error,
  });
  final WorkspaceDocument document;
  final int revision;
  final bool loading, writable, dirty;
  final String? error;
}

/// The adapter owns one controller. There is no file/provider/business default.
class WorkspaceController {
  WorkspaceController({
    required this.store,
    required this.defaults,
    this.legacyDataIds = const [],
    this.legacyDataMarker,
    this.onChanged,
  }) : state = WorkspaceControllerState(document: defaults);
  final WorkspaceLayoutStore store;
  final WorkspaceDocument defaults;
  final List<String> legacyDataIds;
  final String? legacyDataMarker;
  final void Function(WorkspaceControllerState)? onChanged;
  WorkspaceControllerState state;
  Object? _token;
  int _loadEpoch = 0;
  bool _disposed = false;
  Future<void>? _writing;
  void dispose() {
    _disposed = true;
    _loadEpoch++;
  }

  void _set(WorkspaceControllerState value) {
    if (!_disposed) {
      state = value;
      onChanged?.call(value);
    }
  }

  WorkspaceControllerState _with({
    WorkspaceDocument? document,
    int? revision,
    bool? loading,
    bool? writable,
    bool? dirty,
    String? error,
  }) => WorkspaceControllerState(
    document: document ?? state.document,
    revision: revision ?? state.revision,
    loading: loading ?? state.loading,
    writable: writable ?? state.writable,
    dirty: dirty ?? state.dirty,
    error: error,
  );

  Future<void> load({bool discardChanges = false}) async {
    if (_disposed) return;
    final epoch = ++_loadEpoch;
    final previousToken = _token;
    final previousRevision = state.revision;
    _set(_with(loading: true, writable: false));
    WorkspaceRootOutcome root;
    try {
      root = await store.loadRoot();
    } catch (_) {
      root = const WorkspaceRootUnreadable('读取失败');
    }
    if (_disposed || epoch != _loadEpoch) return;
    if (root is WorkspaceRootUnreadable || root is WorkspaceRootFuture) {
      _set(
        _with(
          loading: false,
          writable: false,
          error: root is WorkspaceRootFuture
              ? '配置来自较新版本，请更新后再编辑'
              : '配置暂时无法读取，请重试',
        ),
      );
      return;
    }
    final snapshot = root is WorkspaceRootLoaded
        ? root.root
        : <String, Object?>{};
    final nextToken = root is WorkspaceRootLoaded
        ? root.targetToken
        : (root as WorkspaceRootMissing).targetToken;
    final decoded = decodeWorkspaceDocument(
      snapshot,
      defaults: defaults,
      legacyDataIds: legacyDataIds,
      legacyDataMarker: legacyDataMarker,
    );
    if (!decoded.writable) {
      _set(_with(loading: false, writable: false, error: decoded.error));
      return;
    }
    // A write may acknowledge while this read is suspended. An older snapshot
    // must not roll the acknowledged document or target precondition back.
    if (!discardChanges &&
        (_token != previousToken || state.revision != previousRevision)) {
      _set(
        _with(
          loading: false,
          writable: true,
          error: nextToken == _token ? null : '忽略较旧读取，当前布局已保留',
        ),
      );
      return;
    }
    if (state.dirty && !discardChanges) {
      if (previousToken != nextToken) {
        _set(
          _with(loading: false, writable: false, error: '布局已在别处变化，请刷新或保留修改后处理'),
        );
      } else {
        _token = nextToken;
        _set(_with(loading: false, writable: true));
      }
      return;
    }
    _token = nextToken;
    _set(
      _with(
        document: decoded.document,
        loading: false,
        writable: true,
        dirty: false,
        revision: state.revision + 1,
      ),
    );
  }

  Future<void> retrySave() => _save();
  Future<void> _change(WorkspaceDocument next) {
    if (_disposed || !state.writable || state.loading) return Future.value();
    if (jsonEncode(next.toJson()) == jsonEncode(state.document.toJson()))
      return Future.value();
    _set(_with(document: next, revision: state.revision + 1, dirty: true));
    return _save();
  }

  Future<void> _save() {
    if (_disposed || !state.writable || !state.dirty) return Future.value();
    return _writing ??= _drain().whenComplete(() => _writing = null);
  }

  Future<void> _drain() async {
    while (!_disposed && state.writable && state.dirty) {
      final revision = state.revision;
      final document = state.document;
      final order = document.groups
          .expand((group) => group)
          .where(legacyDataIds.contains)
          .toList();
      final patch = WorkspacePatch(
        values: {
          'workspaceLayoutV3': document.toJson(),
          if (legacyDataIds.isNotEmpty) 'order': order,
        },
        expectedTargetToken: _token,
        revision: revision,
      );
      WorkspaceWriteOutcome result;
      try {
        result = await store.writePatch(patch);
      } catch (_) {
        result = const WorkspaceWriteFailed('保存失败');
      }
      if (_disposed) return;
      if (result is WorkspaceWriteCommitted && result.revision == revision) {
        _token = result.snapshot.targetToken;
        _set(_with(dirty: state.revision != revision));
      } else {
        final blocked =
            result is WorkspaceWriteBlocked || result is WorkspaceWriteConflict;
        _set(
          _with(
            writable: !blocked && state.writable,
            error: result is WorkspaceWriteConflict
                ? '布局已变化，请刷新后处理'
                : blocked
                ? '配置不可写，请重试读取'
                : '布局未保存，修改仍在本次会话',
          ),
        );
        return;
      }
    }
  }

  Future<void> placeGroup(WorkspaceDrag drag, int index) {
    final groups = state.document.groups;
    final sourceBoundary = index.clamp(0, groups.length);
    var boundary = sourceBoundary;
    final moving = drag.members.toSet();
    final next = <List<String>>[];
    for (var i = 0; i < groups.length; i++) {
      final rest = groups[i].where((id) => !moving.contains(id)).toList();
      if (rest.isEmpty) {
        if (i < sourceBoundary) boundary--;
      } else {
        next.add(rest);
      }
    }
    next.insert(boundary.clamp(0, next.length), drag.members);
    return _change(state.document.copyWith(groups: next));
  }

  Future<void> stackGroup(WorkspaceDrag drag, String targetId) {
    if (drag.members.contains(targetId) ||
        !state.document.groups.any((group) => group.contains(targetId)))
      return Future.value();
    final next = state.document.groups
        .map(
          (group) => group.where((id) => !drag.members.contains(id)).toList(),
        )
        .where((group) => group.isNotEmpty)
        .toList();
    next.firstWhere((group) => group.contains(targetId)).addAll(drag.members);
    return _change(state.document.copyWith(groups: next));
  }

  Future<void> detach(String id, int index) =>
      placeGroup(WorkspaceDrag([id]), index);
  Future<void> hideGroup(WorkspaceDrag drag) => _change(
    state.document.copyWith(
      groups: state.document.groups
          .map(
            (group) => group.where((id) => !drag.members.contains(id)).toList(),
          )
          .where((group) => group.isNotEmpty),
    ),
  );
  Future<void> moveGroup(int from, int delta) {
    final next = state.document.groups.map((group) => group.toList()).toList();
    final to = from + delta;
    if (from < 0 || from >= next.length || to < 0 || to >= next.length)
      return Future.value();
    next.insert(to, next.removeAt(from));
    return _change(state.document.copyWith(groups: next));
  }

  Future<void> reveal(String id) =>
      state.document.groups.any((group) => group.contains(id))
      ? Future.value()
      : placeGroup(WorkspaceDrag([id]), state.document.groups.length);
  Future<void> setSize(String id, WorkspaceSize size) {
    if (!workspaceValidId(id) || !size.valid) return Future.value();
    final old = state.document.sizes[id];
    final nextSize = WorkspaceSize(
      size.colSpan,
      size.rowSpan,
      isNatural: size.isNatural,
      metadata: old?.metadata ?? size.metadata,
    );
    return _change(
      state.document.copyWith(sizes: {...state.document.sizes, id: nextSize}),
    );
  }

  Future<void> reset() {
    final known = defaults.groups.expand((group) => group).toSet();
    final unknown = state.document.groups
        .map((group) => group.where((id) => !known.contains(id)).toList())
        .where((group) => group.isNotEmpty);
    return _change(
      state.document.copyWith(groups: [...defaults.groups, ...unknown]),
    );
  }

  Future<void> reorderData(List<String> order) {
    final ranked = <String>{
      ...order.where(legacyDataIds.contains),
      ...state.document.groups
          .expand((group) => group)
          .where(legacyDataIds.contains),
    }.toList();
    final present =
        state.document.groups
            .expand((group) => group)
            .where(legacyDataIds.contains)
            .toList()
          ..sort((a, b) => ranked.indexOf(a).compareTo(ranked.indexOf(b)));
    var index = 0;
    return _change(
      state.document.copyWith(
        groups: state.document.groups.map(
          (group) => group.map(
            (id) => legacyDataIds.contains(id) ? present[index++] : id,
          ),
        ),
      ),
    );
  }

  Future<void> perform(WorkspaceAction action) => switch (action.kind) {
    WorkspaceActionKind.place => placeGroup(action.drag!, action.index),
    WorkspaceActionKind.stack => stackGroup(action.drag!, action.id!),
    WorkspaceActionKind.detach => detach(action.id!, action.index),
    WorkspaceActionKind.hide => hideGroup(action.drag!),
    WorkspaceActionKind.move => moveGroup(action.index, action.delta),
    WorkspaceActionKind.reveal => reveal(action.id!),
    WorkspaceActionKind.resize => setSize(action.id!, action.size!),
    WorkspaceActionKind.reset => reset(),
  };
}
