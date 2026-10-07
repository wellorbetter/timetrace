import 'dart:async';

/// Opaque JSON metadata is retained, but cannot alias a caller's mutable map.
Object? workspaceFreeze(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    if (value is num && !value.isFinite)
      throw const FormatException('Nonfinite JSON');
    return value;
  }
  if (value is List)
    return List<Object?>.unmodifiable(value.map(workspaceFreeze));
  if (value is Map) {
    if (value.keys.any((key) => key is! String))
      throw const FormatException('JSON key');
    return Map<String, Object?>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, workspaceFreeze(item))),
    );
  }
  throw const FormatException('Unsupported JSON');
}

Map<String, Object?> workspaceMap(Map value) =>
    workspaceFreeze(value) as Map<String, Object?>;
bool workspaceValidId(Object? id) => id is String && id.trim().isNotEmpty;

class WorkspaceSize {
  const WorkspaceSize(
    this.colSpan,
    this.rowSpan, {
    this.isNatural = false,
    this.metadata = const {},
  });
  static const oneByOne = WorkspaceSize(1, 1);
  static const twoByOne = WorkspaceSize(2, 1);
  static const twoByTwo = WorkspaceSize(2, 2);
  static const twoByThree = WorkspaceSize(2, 3);
  static const fullNatural = WorkspaceSize(4, 0, isNatural: true);
  static const values = [oneByOne, twoByOne, twoByTwo, twoByThree, fullNatural];
  final int colSpan;
  final int rowSpan;
  final bool isNatural;
  final Map<String, Object?> metadata;
  String get label => isNatural ? '整行自然高度' : '$colSpan × $rowSpan';
  bool get valid => isNatural
      ? colSpan == 4 && rowSpan == 0
      : (colSpan == 1 && rowSpan == 1) ||
            (colSpan == 2 && rowSpan >= 1 && rowSpan <= 3);
  bool sameExtent(WorkspaceSize other) =>
      colSpan == other.colSpan &&
      rowSpan == other.rowSpan &&
      isNatural == other.isNatural;
  Map<String, Object?> toJson() => {
    ...metadata,
    'colSpan': colSpan,
    'rowSpan': rowSpan,
    'fullNatural': isNatural,
  };
  factory WorkspaceSize.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['colSpan'] is! int ||
        raw['rowSpan'] is! int ||
        (raw['fullNatural'] != null && raw['fullNatural'] is! bool))
      throw const FormatException('Invalid size');
    final metadata = Map<String, Object?>.from(workspaceMap(raw))
      ..remove('colSpan')
      ..remove('rowSpan')
      ..remove('fullNatural');
    final size = WorkspaceSize(
      raw['colSpan'] as int,
      raw['rowSpan'] as int,
      isNatural: raw['fullNatural'] == true,
      metadata: workspaceMap(metadata),
    );
    if (!size.valid) throw const FormatException('Unsupported size');
    return size;
  }
  static WorkspaceSize maximum(Iterable<WorkspaceSize> sizes) {
    var columns = 1, rows = 1;
    for (final size in sizes) {
      if (!size.valid) throw const FormatException('Unsupported size');
      if (size.isNatural) return fullNatural;
      if (size.colSpan > columns) columns = size.colSpan;
      if (size.rowSpan > rows) rows = size.rowSpan;
    }
    return WorkspaceSize(columns, rows);
  }
}

class WorkspaceDrag {
  WorkspaceDrag(Iterable<String> ids)
    : members = List.unmodifiable(ids.toSet()) {
    if (members.isEmpty || members.any((id) => !workspaceValidId(id)))
      throw ArgumentError('Nonempty stable IDs required');
  }
  final List<String> members;
  String get first => members.first;
}

class WorkspaceDocument {
  WorkspaceDocument({
    required Iterable<Iterable<String>> groups,
    Map<String, WorkspaceSize> sizes = const {},
    Map<String, Object?> metadata = const {},
  }) : groups = List.unmodifiable(
         groups.map((group) => List<String>.unmodifiable(group)),
       ),
       sizes = Map.unmodifiable(
         sizes.map(
           (id, size) => MapEntry(
             id,
             WorkspaceSize(
               size.colSpan,
               size.rowSpan,
               isNatural: size.isNatural,
               metadata: workspaceMap(size.metadata),
             ),
           ),
         ),
       ),
       metadata = workspaceMap(metadata) {
    final ids = this.groups.expand((group) => group).toList();
    if (this.groups.any((group) => group.isEmpty) ||
        ids.any((id) => !workspaceValidId(id)) ||
        ids.toSet().length != ids.length ||
        sizes.entries.any(
          (entry) => !workspaceValidId(entry.key) || !entry.value.valid,
        ))
      throw const FormatException('Invalid document');
  }
  int get version => 3;
  final List<List<String>> groups;
  final Map<String, WorkspaceSize> sizes;
  final Map<String, Object?> metadata;
  WorkspaceDocument copyWith({
    Iterable<Iterable<String>>? groups,
    Map<String, WorkspaceSize>? sizes,
  }) => WorkspaceDocument(
    groups: groups ?? this.groups,
    sizes: sizes ?? this.sizes,
    metadata: metadata,
  );
  Map<String, Object?> toJson() => {
    ...metadata,
    'version': 3,
    'groups': groups,
    'sizes': sizes.map((id, size) => MapEntry(id, size.toJson())),
  };
  factory WorkspaceDocument.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['version'] != 3 ||
        raw['groups'] is! List ||
        raw['sizes'] is! Map)
      throw const FormatException('Invalid layout');
    final groups = <List<String>>[];
    for (final group in raw['groups'] as List) {
      if (group is! List ||
          group.isEmpty ||
          group.any((id) => !workspaceValidId(id)))
        throw const FormatException('Invalid group');
      groups.add(group.cast<String>());
    }
    final sizes = <String, WorkspaceSize>{};
    for (final entry in (raw['sizes'] as Map).entries) {
      if (!workspaceValidId(entry.key))
        throw const FormatException('Invalid size ID');
      sizes[entry.key as String] = WorkspaceSize.fromJson(entry.value);
    }
    final metadata = Map<String, Object?>.from(workspaceMap(raw))
      ..remove('version')
      ..remove('groups')
      ..remove('sizes');
    return WorkspaceDocument(groups: groups, sizes: sizes, metadata: metadata);
  }
}

class WorkspaceDecode {
  const WorkspaceDecode(this.document, {this.writable = true, this.error});
  final WorkspaceDocument document;
  final bool writable;
  final String? error;
}

/// Legacy expansion/defaults are supplied by the adapter, never business IDs.
WorkspaceDecode decodeWorkspaceDocument(
  Map<String, Object?> root, {
  required WorkspaceDocument defaults,
  List<String> legacyDataIds = const [],
  String? legacyDataMarker,
}) {
  try {
    if (root.containsKey('workspaceLayoutV3')) {
      final raw = root['workspaceLayoutV3'];
      if (raw is Map && raw['version'] is int && (raw['version'] as int) > 3)
        return WorkspaceDecode(
          defaults,
          writable: false,
          error: '布局来自较新版本，请更新后再编辑',
        );
      return WorkspaceDecode(WorkspaceDocument.fromJson(raw));
    }
    final ordered = <String>[];
    if (root.containsKey('order')) {
      final raw = root['order'];
      if (raw is! List || raw.any((id) => !workspaceValidId(id)))
        throw const FormatException('Invalid order');
      for (final id in raw.cast<String>()) {
        if (legacyDataIds.contains(id) && !ordered.contains(id))
          ordered.add(id);
      }
    }
    for (final id in legacyDataIds) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    List rawGroups;
    if (root.containsKey('workspaceGroupsV2')) {
      if (root['workspaceGroupsV2'] is! List)
        throw const FormatException('Invalid V2');
      rawGroups = root['workspaceGroupsV2'] as List;
    } else if (root.containsKey('workspaceComponentsV1')) {
      final raw = root['workspaceComponentsV1'];
      if (raw is! List || raw.any((id) => !workspaceValidId(id)))
        throw const FormatException('Invalid V1');
      rawGroups = [
        for (final id in raw)
          if (legacyDataMarker != null && id == legacyDataMarker)
            ordered
          else
            [id],
      ];
    } else {
      return WorkspaceDecode(
        root.containsKey('order') && legacyDataIds.isNotEmpty
            ? defaults.copyWith(groups: [ordered], sizes: const {})
            : defaults,
      );
    }
    final seen = <String>{};
    final groups = <List<String>>[];
    for (final group in rawGroups) {
      if (group is! List || group.any((id) => !workspaceValidId(id)))
        throw const FormatException('Invalid legacy group');
      final members = [
        for (final id in group.cast<String>())
          if (seen.add(id)) id,
      ];
      if (members.isNotEmpty) groups.add(members);
    }
    return WorkspaceDecode(defaults.copyWith(groups: groups, sizes: const {}));
  } catch (_) {
    return WorkspaceDecode(defaults, writable: false, error: '布局暂时无法读取，请重试');
  }
}

sealed class WorkspaceRootOutcome {
  const WorkspaceRootOutcome();
}

class WorkspaceRootMissing extends WorkspaceRootOutcome {
  const WorkspaceRootMissing({this.targetToken});
  final Object? targetToken;
}

class WorkspaceRootLoaded extends WorkspaceRootOutcome {
  WorkspaceRootLoaded(
    Map<String, Object?> root, {
    required this.targetToken,
    this.originalBytes,
  }) : root = workspaceMap(root);
  final Map<String, Object?> root;
  final Object targetToken;
  final String? originalBytes;
}

class WorkspaceRootUnreadable extends WorkspaceRootOutcome {
  const WorkspaceRootUnreadable(this.reason);
  final String reason;
}

class WorkspaceRootFuture extends WorkspaceRootOutcome {
  const WorkspaceRootFuture(this.version);
  final int version;
}

class WorkspacePatch {
  WorkspacePatch({
    required Map<String, Object?> values,
    required this.expectedTargetToken,
    required this.revision,
  }) : values = workspaceMap(values);
  final Map<String, Object?> values;
  final Object? expectedTargetToken;
  final int revision;
}

sealed class WorkspaceWriteOutcome {
  const WorkspaceWriteOutcome();
}

class WorkspaceWriteCommitted extends WorkspaceWriteOutcome {
  const WorkspaceWriteCommitted({
    required this.snapshot,
    required this.revision,
  });
  final WorkspaceRootLoaded snapshot;
  final int revision;
}

class WorkspaceWriteBlocked extends WorkspaceWriteOutcome {
  const WorkspaceWriteBlocked(this.outcome);
  final WorkspaceRootOutcome outcome;
}

class WorkspaceWriteConflict extends WorkspaceWriteOutcome {
  const WorkspaceWriteConflict();
}

class WorkspaceWriteFailed extends WorkspaceWriteOutcome {
  const WorkspaceWriteFailed(this.reason);
  final String reason;
}

abstract interface class WorkspaceLayoutStore {
  FutureOr<WorkspaceRootOutcome> loadRoot();
  FutureOr<WorkspaceWriteOutcome> writePatch(WorkspacePatch patch);
}

enum WorkspaceActionKind {
  place,
  stack,
  detach,
  hide,
  move,
  reveal,
  resize,
  reset,
}

class WorkspaceAction {
  const WorkspaceAction(
    this.kind, {
    this.drag,
    this.id,
    this.index = 0,
    this.delta = 0,
    this.size,
  });
  final WorkspaceActionKind kind;
  final WorkspaceDrag? drag;
  final String? id;
  final int index;
  final int delta;
  final WorkspaceSize? size;
}
