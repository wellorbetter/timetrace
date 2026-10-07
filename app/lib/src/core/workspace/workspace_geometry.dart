import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../material/material_tokens.dart';
import 'workspace_model.dart';

class WorkspaceGeometryPolicy {
  const WorkspaceGeometryPolicy({
    this.cellHeight = 154,
    this.gap = MaterialTokens.spaceMd,
    this.rowGap = MaterialTokens.spaceLg,
    this.breakpoint = 720,
    this.emptyHeight = 320,
  });
  final double cellHeight, gap, rowGap, breakpoint, emptyHeight;
  int columns(double width) => width < breakpoint ? 1 : 4;
  double widthFor(double width, WorkspaceSize size) {
    if (!width.isFinite || width < 0)
      throw ArgumentError('Finite parent width required');
    final count = columns(width);
    if (count == 1 || size.isNatural) return width;
    return size.colSpan * ((width - 3 * gap) / 4) + (size.colSpan - 1) * gap;
  }

  double heightFor(WorkspaceSize size) =>
      size.rowSpan * cellHeight + (size.rowSpan - 1) * gap;
}

/// Optional presentation-only first-fold budget. Document sizes never change.
class WorkspacePrefixPresentationBudget {
  WorkspacePrefixPresentationBudget({
    required Iterable<Iterable<String>> prefixGroups,
    required Map<int, double> contentHeights,
    required this.firstFoldExtent,
    required this.minimumContentHeight,
    this.foldAfterGroupIndex = 2,
  }) : prefixGroups = List.unmodifiable(
         prefixGroups.map((g) => List<String>.unmodifiable(g))),
       contentHeights = Map.unmodifiable(contentHeights);
  final List<List<String>> prefixGroups;
  final Map<int, double> contentHeights;
  final double firstFoldExtent, minimumContentHeight;
  final int foldAfterGroupIndex;
  List<Object?> get signature => [
    prefixGroups, contentHeights.entries.map((e) => [e.key, e.value]).toList(),
    firstFoldExtent, minimumContentHeight, foldAfterGroupIndex,
  ];
  bool matches(List<List<String>> groups, List<WorkspaceSize> sizes) =>
      prefixGroups.length == 3 && foldAfterGroupIndex == 2 &&
      firstFoldExtent.isFinite && firstFoldExtent > 0 &&
      minimumContentHeight.isFinite && minimumContentHeight > 0 &&
      contentHeights.length == 2 &&
      [0, 1].every((i) => contentHeights[i]?.isFinite == true &&
          contentHeights[i]! >= minimumContentHeight) &&
      groups.length >= 3 && sizes.length == groups.length &&
      [0, 1, 2].every((i) => groups[i].length == prefixGroups[i].length &&
          List.generate(groups[i].length, (j) =>
            groups[i][j] == prefixGroups[i][j]).every((v) => v)) &&
      sizes[0].sameExtent(WorkspaceSize.twoByTwo) &&
      sizes[1].sameExtent(WorkspaceSize.twoByTwo) &&
      sizes[2].isNatural;

  /// Fold clearance comes from this generation's actual natural diary/chrome.
  List<WorkspaceGroupMeasure> applyClearance(
    double width, List<List<String>> groups,
    List<WorkspaceGroupMeasure> measures, WorkspaceGeometryPolicy policy,
  ) {
    if (!matches(groups, measures.map((m) => m.size).toList()) ||
        !measures.take(3).every((m) => m.ready) ||
        policy.columns(width) == 1) return measures;
    final actual = workspaceGeometry(width, measures, policy: policy);
    final extra = math.max(0.0,
        firstFoldExtent - actual.groups[2].bottom - policy.rowGap);
    if (extra == 0) return measures;
    return [
      for (var i = 0; i < measures.length; i++)
        if (i == foldAfterGroupIndex) WorkspaceGroupMeasure(
          size: measures[i].size, contentHeight: measures[i].contentHeight,
          before: measures[i].before, after: measures[i].after + extra,
          ready: measures[i].ready,
        ) else measures[i],
    ];
  }
}

class WorkspaceGroupMeasure {
  const WorkspaceGroupMeasure({
    required this.size,
    required this.contentHeight,
    this.before = 0,
    this.after = 0,
    this.ready = true,
  });
  final WorkspaceSize size;
  final double contentHeight, before, after;
  final bool ready;
  double get height => contentHeight + before + after;
}

class WorkspaceSlot {
  const WorkspaceSlot(this.rect, this.insertionIndex, {this.ready = true});
  final Rect rect;
  final int insertionIndex;
  final bool ready;
  String get key => '${rect.left}:${rect.top}:${rect.right}:${rect.bottom}';
}

class WorkspaceGeometry {
  const WorkspaceGeometry({
    required this.groups,
    required this.contents,
    required this.groupReady,
    required this.slots,
    required this.height,
    required this.columns,
    this.parentWidth = 0,
    this.gap = MaterialTokens.spaceMd,
  });
  final List<Rect> groups, contents;
  final List<bool> groupReady;
  final List<WorkspaceSlot> slots;
  final double height;
  final int columns;
  WorkspaceHit? hit(Offset point) {
    // A gutter inside a spanning occupied card belongs to that card.
    for (var i = 0; i < groups.length; i++) {
      if (groupReady[i] && groups[i].contains(point))
        return WorkspaceHit.group(i);
    }
    // Gutters are not drop targets, even when a multi-column hole spans them.
    if (columns == 4 && groups.isNotEmpty) {
      // The complete four-column width is recorded below, including empty columns.
      final unit = (parentWidth - 3 * gap) / 4;
      if (unit > 0) {
        for (var column = 0; column < 3; column++) {
          final edge = (column + 1) * unit + column * gap;
          if (point.dx >= edge && point.dx < edge + gap) return null;
        }
      }
    }
    for (final slot in slots) {
      if (slot.ready && slot.rect.contains(point))
        return WorkspaceHit.slot(slot.insertionIndex);
    }
    for (var i = 0; i < groups.length; i++) {
      if (groupReady[i] && groups[i].contains(point))
        return WorkspaceHit.group(i);
    }
    return null;
  }

  final double parentWidth, gap;
}

class WorkspaceHit {
  const WorkspaceHit.group(this.index) : isSlot = false;
  const WorkspaceHit.slot(this.index) : isSlot = true;
  final int index;
  final bool isSlot;
}

/// Deterministic first-fit of actual occupied outer rectangles, in logical order.
WorkspaceGeometry workspaceGeometry(
  double width,
  List<WorkspaceGroupMeasure> measures, {
  WorkspaceGeometryPolicy policy = const WorkspaceGeometryPolicy(),
  bool editing = false,
}) {
  if (!width.isFinite || width < 0)
    throw ArgumentError('Finite width required');
  final columns = policy.columns(width);
  final unit = columns == 1 ? width : (width - 3 * policy.gap) / 4;
  final groups = <Rect>[], contents = <Rect>[], ready = <bool>[];
  var barrier = 0.0, bottom = 0.0;
  var stable = true;
  for (final item in measures) {
    if (!item.height.isFinite ||
        item.height < 0 ||
        !item.size.valid ||
        !item.before.isFinite ||
        !item.after.isFinite ||
        item.before < 0 ||
        item.after < 0) {
      throw ArgumentError('Valid finite measurements required');
    }
    final span = columns == 1 || item.size.isNatural
        ? columns
        : item.size.colSpan;
    final itemWidth = policy.widthFor(width, item.size);
    var x = 0.0, y = barrier;
    if (columns == 1 || item.size.isNatural) {
      y = groups.isEmpty ? barrier : math.max(barrier, bottom + policy.rowGap);
    } else {
      final candidates = <double>{barrier};
      for (final rect in groups) {
        if (rect.bottom + policy.gap >= barrier)
          candidates.add(rect.bottom + policy.gap);
      }
      final ys = candidates.toList()..sort();
      var found = false;
      for (final candidate in ys) {
        for (var column = 0; column <= columns - span; column++) {
          final left = column * (unit + policy.gap);
          final rect = Rect.fromLTWH(left, candidate, itemWidth, item.height);
          final blocked = groups.any(
            (other) =>
                rect.left < other.right &&
                rect.right > other.left &&
                rect.top < other.bottom + policy.gap &&
                rect.bottom + policy.gap > other.top,
          );
          if (!blocked) {
            x = left;
            y = candidate;
            found = true;
            break;
          }
        }
        if (found) break;
      }
      if (!found) y = math.max(barrier, bottom + policy.gap);
    }
    final rect = Rect.fromLTWH(x, y, itemWidth, item.height);
    groups.add(rect);
    contents.add(
      Rect.fromLTWH(x, y + item.before, itemWidth, item.contentHeight),
    );
    stable = stable && item.ready;
    ready.add(stable && item.height > 0);
    bottom = math.max(bottom, rect.bottom);
    if (columns == 1 || item.size.isNatural) barrier = bottom + policy.rowGap;
  }
  final slots = <WorkspaceSlot>[];
  if (editing && columns == 4 && groups.isNotEmpty) {
    final naturalGaps = <Rect>[];
    for (var i = 0; i < measures.length; i++) {
      if (measures[i].size.isNatural) {
        naturalGaps.add(
          Rect.fromLTRB(
            0,
            groups[i].bottom,
            width,
            groups[i].bottom + policy.rowGap,
          ),
        );
      }
      if (measures[i].size.isNatural && i > 0) {
        final previousBottom = groups
            .take(i)
            .fold<double>(0, (v, r) => math.max(v, r.bottom));
        naturalGaps.add(Rect.fromLTRB(0, previousBottom, width, groups[i].top));
      }
    }
    // Partition y-slabs into disjoint empty column runs; no maximal-rectangle
    // enumeration, overlapping targets, or targets inside reserved clearance.
    final events = <double>{0, bottom};
    for (final gap in naturalGaps) {
      events.add(gap.top);
      events.add(gap.bottom);
    }
    for (final rect in groups) {
      events.add(rect.top);
      events.add(rect.bottom);
      events.add(math.max(0, rect.top - policy.gap));
      events.add(math.min(bottom, rect.bottom + policy.gap));
    }
    final ys = events.toList()..sort();
    for (var row = 0; row + 1 < ys.length; row++) {
      final top = ys[row], end = ys[row + 1];
      if (end <= top) continue;
      var column = 0;
      while (column < 4) {
        bool free(int col) {
          final x = col * (unit + policy.gap);
          if (naturalGaps.any((gap) => top < gap.bottom && end > gap.top))
            return false;
          return !groups.any(
            (rect) =>
                x < rect.right &&
                x + unit > rect.left &&
                top < rect.bottom + policy.gap &&
                end > rect.top - policy.gap,
          );
        }

        if (!free(column)) {
          column++;
          continue;
        }
        final start = column;
        while (column < 4 && free(column)) column++;
        final rect = Rect.fromLTWH(
          start * (unit + policy.gap),
          top,
          (column - start) * unit + (column - start - 1) * policy.gap,
          end - top,
        );
        final following = groups.indexWhere((group) => group.top >= end);
        slots.add(
          WorkspaceSlot(
            rect,
            following < 0 ? measures.length : following,
            ready: stable,
          ),
        );
      }
    }
    // Only identical adjacent runs can merge. Their union stays a disjoint
    // partition; it never crosses a clearance slab or natural barrier.
    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        final a = slots[i], b = slots[j];
        if (a.rect.left == b.rect.left &&
            a.rect.right == b.rect.right &&
            a.rect.bottom == b.rect.top &&
            a.ready == b.ready) {
          slots[i] = WorkspaceSlot(
            Rect.fromLTRB(a.rect.left, a.rect.top, a.rect.right, b.rect.bottom),
            math.min(a.insertionIndex, b.insertionIndex),
            ready: a.ready,
          );
          slots.removeAt(j);
          j = i; // bounded number of finite partition runs
        }
      }
    }
    slots.sort(
      (a, b) => a.rect.top == b.rect.top
          ? a.rect.left.compareTo(b.rect.left)
          : a.rect.top.compareTo(b.rect.top),
    );
  }
  if (editing) {
    final appendTop = measures.isEmpty ? 0.0 : bottom + policy.rowGap;
    final appendHeight = measures.isEmpty
        ? policy.emptyHeight
        : measures.last.height;
    slots.add(
      WorkspaceSlot(
        Rect.fromLTWH(0, appendTop, width, appendHeight),
        measures.length,
        ready: stable,
      ),
    );
    bottom = appendTop + appendHeight;
  }
  return WorkspaceGeometry(
    groups: List.unmodifiable(groups),
    contents: List.unmodifiable(contents),
    groupReady: List.unmodifiable(ready),
    slots: List.unmodifiable(slots),
    height: bottom,
    columns: columns,
    parentWidth: width,
    gap: policy.gap,
  );
}

/// The same original-boundary removal arithmetic as WorkspaceController.
/// Pure simulation only: it never writes the document or invokes business code.
List<List<String>> workspaceSimulatePlace(
  List<List<String>> groups,
  WorkspaceDrag drag,
  int index,
) {
  final sourceBoundary = index.clamp(0, groups.length);
  var boundary = sourceBoundary;
  final moving = drag.members.toSet(), next = <List<String>>[];
  for (var i = 0; i < groups.length; i++) {
    final rest = groups[i].where((id) => !moving.contains(id)).toList();
    if (rest.isEmpty) {
      if (i < sourceBoundary) boundary--;
    } else {
      next.add(rest);
    }
  }
  next.insert(boundary.clamp(0, next.length), drag.members);
  return List.unmodifiable(next.map((g) => List<String>.unmodifiable(g)));
}

bool workspaceSameMembers(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class WorkspaceMemberMeasurement {
  const WorkspaceMemberMeasurement({
    required this.id,
    required this.width,
    required this.height,
    required this.constraints,
    required this.contentRevision,
  });
  final String id;
  final double width, height;
  final BoxConstraints constraints;
  final Object? contentRevision;
}

/// One complete actual layout generation. All lists/maps are immutable and no
/// previous-width/natural cached height or hidden replacement State is used.
class WorkspaceMeasurementSnapshot {
  WorkspaceMeasurementSnapshot({
    required this.generation,
    required this.fingerprint,
    required this.width,
    required List<List<String>> groups,
    required List<WorkspaceGroupMeasure> measures,
    required Map<String, WorkspaceMemberMeasurement> members,
  }) : groups = List.unmodifiable(
         groups.map((g) => List<String>.unmodifiable(g)),
       ),
       measures = List.unmodifiable(measures),
       members = Map.unmodifiable(members);
  final int generation;
  final String fingerprint;
  final double width;
  final List<List<String>> groups;
  final List<WorkspaceGroupMeasure> measures;
  final Map<String, WorkspaceMemberMeasurement> members;
  bool get complete =>
      groups.length == measures.length &&
      width.isFinite &&
      width > 0 &&
      measures.every((m) => m.ready && m.height.isFinite && m.height > 0) &&
      groups.expand((g) => g).every((id) {
        final member = members[id];
        return member != null &&
            member.width.isFinite &&
            member.width > 0 &&
            member.height.isFinite &&
            member.height >= 0;
      });
  int? groupOf(List<String> ids) {
    final index = groups.indexWhere((g) => workspaceSameMembers(g, ids));
    return index < 0 ? null : index;
  }
}

/// Map an actual hole to the lowest original place boundary whose complete
/// fixed moving group lands inside it. New/partial/unmeasured groups fail closed.
/// This is computed once per snapshot+drag; pointer movement only hits the map.
Map<String, int> workspaceHoleBoundaries(
  WorkspaceMeasurementSnapshot snapshot,
  WorkspaceDrag drag,
  WorkspaceGeometry actual,
  WorkspaceGeometryPolicy policy,
) {
  final index = snapshot.groupOf(drag.members);
  if (!snapshot.complete ||
      snapshot.width != actual.parentWidth ||
      snapshot.groups.length != actual.groups.length ||
      index == null ||
      snapshot.measures[index].size.isNatural)
    return const {};
  for (var i = 0; i < snapshot.groups.length; i++) {
    final expectedWidth = policy.widthFor(
      snapshot.width,
      snapshot.measures[i].size,
    );
    if (snapshot.groups[i].any(
      (id) => snapshot.members[id]!.width != expectedWidth,
    )) {
      return const {};
    }
  }
  final result = <String, int>{};
  for (var boundary = 0; boundary <= snapshot.groups.length; boundary++) {
    final next = workspaceSimulatePlace(snapshot.groups, drag, boundary);
    final nextMeasures = <WorkspaceGroupMeasure>[];
    var valid = true;
    for (final group in next) {
      final previous = snapshot.groupOf(group);
      if (previous == null) {
        valid = false;
        break;
      }
      nextMeasures.add(snapshot.measures[previous]);
    }
    if (!valid) continue;
    final candidate = workspaceGeometry(
      snapshot.width,
      nextMeasures,
      policy: policy,
      editing: true,
    );
    final moving = candidate
        .groups[next.indexWhere((g) => workspaceSameMembers(g, drag.members))];
    for (final hole in actual.slots.where((s) => s.ready)) {
      // The terminal blank slot is a semantic append fallback, not an internal
      // rectangle prediction. New unknown groups use the pinned48dp target.
      if (hole.rect.top >=
          actual.groups.fold<double>(0, (v, r) => math.max(v, r.bottom)))
        continue;
      if (hole.rect.left <= moving.left &&
          hole.rect.top <= moving.top &&
          hole.rect.right >= moving.right &&
          hole.rect.bottom >= moving.bottom) {
        result.putIfAbsent(hole.key, () => boundary);
      }
    }
  }
  return Map.unmodifiable(result);
}

typedef WorkspaceDropIntent = ({bool after, bool central, AxisDirection edge});
WorkspaceDropIntent? workspaceDropIntent(
  Offset point,
  Size size, {
  required bool horizontal,
}) {
  if (size.isEmpty || !(Offset.zero & size).contains(point)) return null;
  final x = point.dx / size.width, y = point.dy / size.height;
  final central = x >= .25 && x <= .75 && y >= .25 && y <= .75;
  if (!horizontal)
    return (
      after: y >= .5,
      central: central,
      edge: y >= .5 ? AxisDirection.down : AxisDirection.up,
    );
  if (central)
    return (
      after: x >= .5,
      central: true,
      edge: x >= .5 ? AxisDirection.right : AxisDirection.left,
    );
  final edges = <AxisDirection, double>{
    AxisDirection.left: x,
    AxisDirection.right: 1 - x,
    AxisDirection.up: y,
    AxisDirection.down: 1 - y,
  };
  final edge = edges.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  return (
    after: edge == AxisDirection.right || edge == AxisDirection.down,
    central: false,
    edge: edge,
  );
}
