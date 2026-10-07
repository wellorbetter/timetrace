import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/core/workspace/workspace_geometry.dart';

const policy = WorkspaceGeometryPolicy(cellHeight: 100, gap: 12, rowGap: 16);
WorkspaceGroupMeasure measure(
  WorkspaceSize size, {
  double? height,
  bool ready = true,
}) => WorkspaceGroupMeasure(
  size: size,
  contentHeight: height ?? policy.heightFor(size),
  ready: ready,
);
void main() {
  _acceptanceUsabilityTests();
  test('hole boundary requires complete same-chrome actual group fit', () {
    final groups = [
      ['a'],
      ['natural'],
      ['moving'],
    ];
    WorkspaceMeasurementSnapshot snapshot({
      double movingChrome = 48,
      bool missing = false,
    }) {
      final measures = [
        const WorkspaceGroupMeasure(
          size: WorkspaceSize.twoByTwo,
          contentHeight: 212,
          before: 48,
        ),
        const WorkspaceGroupMeasure(
          size: WorkspaceSize.fullNatural,
          contentHeight: 860,
          before: 48,
        ),
        WorkspaceGroupMeasure(
          size: WorkspaceSize.twoByTwo,
          contentHeight: 212,
          before: movingChrome,
        ),
      ];
      return WorkspaceMeasurementSnapshot(
        generation: 1,
        fingerprint: 'actual',
        width: 1200,
        groups: groups,
        measures: measures,
        members: {
          for (final id in ['a', 'natural', if (!missing) 'moving'])
            id: WorkspaceMemberMeasurement(
              id: id,
              width: id == 'natural' ? 1200 : 594,
              height: id == 'natural' ? 860 : 212,
              constraints: const BoxConstraints(maxWidth: 1200),
              contentRevision: 0,
            ),
        },
      );
    }

    final current = snapshot();
    final actual = workspaceGeometry(
      1200,
      current.measures,
      policy: policy,
      editing: true,
    );
    final boundaries = workspaceHoleBoundaries(
      current,
      WorkspaceDrag(['moving']),
      actual,
      policy,
    );
    expect(boundaries.values, contains(1));
    expect(
      workspaceHoleBoundaries(
        snapshot(missing: true),
        WorkspaceDrag(['moving']),
        actual,
        policy,
      ),
      isEmpty,
    );
    expect(
      workspaceHoleBoundaries(
        snapshot(movingChrome: 104),
        WorkspaceDrag(['moving']),
        actual,
        policy,
      ),
      isEmpty,
    );
    expect(
      workspaceHoleBoundaries(
        current,
        WorkspaceDrag(['neverMounted']),
        actual,
        policy,
      ),
      isEmpty,
    );
  });
  test('mixed first-fit fills lower short-card space beside tall cards', () {
    final layout = workspaceGeometry(
      1200,
      [
        measure(WorkspaceSize.oneByOne),
        measure(WorkspaceSize.twoByThree),
        measure(WorkspaceSize.twoByTwo),
        measure(WorkspaceSize.oneByOne),
        measure(WorkspaceSize.oneByOne),
      ],
      policy: policy,
      editing: true,
    );
    expect(layout.groups[4].left, layout.groups[0].left);
    expect(layout.groups[4].top, layout.groups[0].bottom + policy.gap);
    expect(layout.groups[4].top, lessThan(layout.groups[1].bottom));
    for (var i = 0; i < layout.groups.length; i++) {
      for (var j = i + 1; j < layout.groups.length; j++) {
        expect(layout.groups[i].overlaps(layout.groups[j]), isFalse);
      }
    }
  });
  test('hole slabs are stable disjoint and never target column gutters', () {
    final input = [
      measure(WorkspaceSize.twoByThree),
      measure(WorkspaceSize.oneByOne),
      measure(WorkspaceSize.oneByOne),
      measure(WorkspaceSize.twoByTwo),
    ];
    final first = workspaceGeometry(1200, input, policy: policy, editing: true);
    final again = workspaceGeometry(1200, input, policy: policy, editing: true);
    expect(first.slots.map((s) => s.key), again.slots.map((s) => s.key));
    for (var i = 0; i < first.slots.length; i++) {
      final slot = first.slots[i];
      expect(slot.rect.width, greaterThan(0));
      expect(slot.rect.height, greaterThan(0));
      for (var j = i + 1; j < first.slots.length; j++) {
        expect(slot.rect.overlaps(first.slots[j].rect), isFalse);
      }
      for (final occupied in first.groups) {
        expect(slot.rect.overlaps(occupied), isFalse);
      }
    }
    final unit = (1200 - 3 * policy.gap) / 4;
    for (var col = 0; col < 3; col++) {
      final x = (col + 1) * unit + col * policy.gap + policy.gap / 2;
      for (var y = 0.0; y < first.height; y += 17) {
        final point = Offset(x, y);
        if (!first.groups.any((r) => r.contains(point))) {
          expect(first.hit(point), isNull);
        }
      }
    }
  });
  test('original boundary simulation preserves complete source removal', () {
    final groups = [
      ['a'],
      ['b', 'c'],
      ['d'],
    ];
    for (var boundary = 0; boundary <= groups.length; boundary++) {
      final next = workspaceSimulatePlace(
        groups,
        WorkspaceDrag(['b', 'c']),
        boundary,
      );
      final source = groups.map((g) => List<String>.of(g)).toList();
      source.removeAt(1);
      source.insert(boundary > 1 ? boundary - 1 : boundary, ['b', 'c']);
      expect(next, source);
      expect(next.expand((g) => g).toSet(), {'a', 'b', 'c', 'd'});
    }
    expect(groups, [
      ['a'],
      ['b', 'c'],
      ['d'],
    ]);
  });
  for (final width in [480.0, 719.0, 720.0, 1200.0]) {
    for (final size in WorkspaceSize.values) {
      test('declared $size at parent $width', () {
        final geometry = workspaceGeometry(width, [
          measure(size, height: size.isNatural ? 860 : null),
        ], policy: policy);
        final group = geometry.groups.single;
        expect(group.width, policy.widthFor(width, size));
        expect(group.height, size.isNatural ? 860 : policy.heightFor(size));
        expect(geometry.columns, width < 720 ? 1 : 4);
      });
    }
  }
  test(
    'max group spans are independent of selected page; full always wins',
    () {
      expect(
        WorkspaceSize.maximum([
          WorkspaceSize.oneByOne,
          WorkspaceSize.twoByThree,
        ]).sameExtent(WorkspaceSize.twoByThree),
        isTrue,
      );
      expect(
        WorkspaceSize.maximum([
          WorkspaceSize.fullNatural,
          WorkspaceSize.twoByTwo,
        ]).isNatural,
        isTrue,
      );
    },
  );
  test(
    'mixed packing preserves logical indices and exposes actual lower whitespace',
    () {
      final layout = workspaceGeometry(
        1200,
        [
          measure(WorkspaceSize.oneByOne),
          measure(WorkspaceSize.twoByThree),
          measure(WorkspaceSize.twoByTwo),
          measure(WorkspaceSize.oneByOne),
        ],
        policy: policy,
        editing: true,
      );
      expect(layout.groups[0].top, layout.groups[1].top);
      expect(layout.groups[2].top, greaterThan(layout.groups[1].bottom));
      expect(layout.groups[3].top, layout.groups[0].top);
      final slot = layout.slots.first;
      expect(slot.insertionIndex, 2);
      expect(slot.rect.top, 112);
      expect(slot.rect.height, 212);
      for (final y in [slot.rect.top + 1, slot.rect.bottom - 1]) {
        final hit = layout.hit(Offset(slot.rect.center.dx, y))!;
        expect(hit.isSlot, isTrue);
        expect(hit.index, 2);
      }
      expect(
        layout.hit(Offset(layout.groups[0].center.dx, 200)),
        isNotNull,
        reason:
            'actual lower whitespace is a partition, not a reserved row band',
      );
      expect(
        layout.hit(Offset(layout.groups[0].right + 6, 20)),
        isNull,
        reason: 'inter-item gap is invalid',
      );
    },
  );
  test(
    'internal slot closes before natural; trailing and append both use groups.length',
    () {
      final layout = workspaceGeometry(
        1200,
        [
          measure(WorkspaceSize.twoByTwo),
          measure(WorkspaceSize.fullNatural, height: 860),
          measure(WorkspaceSize.oneByOne),
        ],
        policy: policy,
        editing: true,
      );
      expect(layout.slots.first.insertionIndex, 1);
      expect(layout.slots.first.rect.height, 212);
      expect(layout.groups[1].top, 228);
      expect(layout.groups[1].height, 860);
      expect(
        layout.hit(Offset(1190, layout.groups[1].bottom + 13)),
        isNull,
        reason:
            'natural rowGap is a full-width barrier, not a tiny trailing hole',
      );
      expect(layout.slots[1].rect.top, greaterThan(layout.groups[1].bottom));
      expect(layout.slots.last.insertionIndex, 3);
      for (final slot in layout.slots.skip(1)) {
        expect(
          layout.hit(Offset(slot.rect.left + 10, slot.rect.bottom - 1))!.index,
          slot.insertionIndex,
        );
      }
    },
  );
  test('empty editing append is320; compact has no phantom internal slot', () {
    expect(
      workspaceGeometry(
        480,
        [],
        policy: policy,
        editing: true,
      ).slots.single.rect.height,
      320,
    );
    final layout = workspaceGeometry(
      480,
      [
        measure(WorkspaceSize.oneByOne),
        measure(WorkspaceSize.fullNatural, height: 860),
      ],
      policy: policy,
      editing: true,
    );
    expect(layout.slots, hasLength(1));
    expect(layout.slots.single.insertionIndex, 2);
    expect(layout.slots.single.rect.height, 860);
  });
  test(
    'provisional natural disables its band and every affected later drop rect',
    () {
      final layout = workspaceGeometry(
        1200,
        [
          measure(WorkspaceSize.twoByTwo),
          measure(WorkspaceSize.fullNatural, height: 100, ready: false),
          measure(WorkspaceSize.twoByTwo),
        ],
        policy: policy,
        editing: true,
      );
      expect(layout.groupReady, [true, false, false]);
      expect(layout.hit(layout.groups[1].center), isNull);
      expect(layout.hit(layout.groups[2].center), isNull);
      expect(layout.slots.last.ready, isFalse);
    },
  );
  test(
    'chrome is outside content; all four edges and central zone are explicit',
    () {
      final layout = workspaceGeometry(1200, [
        const WorkspaceGroupMeasure(
          size: WorkspaceSize.twoByTwo,
          contentHeight: 212,
          before: 64,
          after: 56,
        ),
      ], policy: policy);
      expect(layout.groups.single.height, 332);
      expect(layout.contents.single.top, 64);
      expect(layout.contents.single.height, 212);
      const size = Size(400, 400);
      for (final sample in <(Offset, AxisDirection, bool)>[
        (const Offset(1, 200), AxisDirection.left, false),
        (const Offset(399, 200), AxisDirection.right, true),
        (const Offset(200, 1), AxisDirection.up, false),
        (const Offset(200, 399), AxisDirection.down, true),
      ]) {
        final intent = workspaceDropIntent(sample.$1, size, horizontal: true)!;
        expect(intent.edge, sample.$2);
        expect(intent.after, sample.$3);
        expect(intent.central, isFalse);
      }
      expect(
        workspaceDropIntent(
          const Offset(200, 200),
          size,
          horizontal: true,
        )!.central,
        isTrue,
      );
      expect(
        workspaceDropIntent(const Offset(401, 200), size, horizontal: true),
        isNull,
      );
    },
  );
}

void _acceptanceUsabilityTests() {
  final groups = <List<String>>[
    ['calendar'], ['bar'], ['diary'], ['poetry'], ['tasks'],
  ];
  WorkspacePrefixPresentationBudget budget(double extent) =>
    WorkspacePrefixPresentationBudget(
      prefixGroups: groups.take(3),
      contentHeights: {0: 300, 1: 300},
      firstFoldExtent: extent, minimumContentHeight: 180);
  test('prefix clearance changes only natural barrier not extras dimensions', () {
    final measures = [
      measure(WorkspaceSize.twoByTwo, height: 300),
      WorkspaceGroupMeasure(size: WorkspaceSize.twoByTwo,
        contentHeight: 300, after: 48),
      measure(WorkspaceSize.fullNatural, height: 85),
      measure(WorkspaceSize.twoByOne),
      measure(WorkspaceSize.twoByThree),
    ];
    final old = workspaceGeometry(1200, measures, policy: policy);
    final adjusted = budget(600).applyClearance(1200, groups, measures, policy);
    final actual = workspaceGeometry(1200, adjusted, policy: policy);
    expect(actual.contents[2].height, 85);
    expect(actual.groups[3].top, greaterThanOrEqualTo(600));
    for (final i in [3, 4]) {
      expect(actual.contents[i].size, old.contents[i].size);
      expect(actual.groups[i].size, old.groups[i].size);
      expect(adjusted[i], same(measures[i]));
    }
    expect(measures[2].after, 0);
    expect(actual.groupReady, old.groupReady);
  });
  test('invalid mismatch compact or unready prefix never adds clearance', () {
    final measures = [
      measure(WorkspaceSize.twoByTwo),
      measure(WorkspaceSize.twoByTwo),
      measure(WorkspaceSize.fullNatural, height: 85),
      measure(WorkspaceSize.twoByOne),
      measure(WorkspaceSize.twoByThree),
    ];
    final b = budget(600);
    expect(b.matches([['other'], ...groups.skip(1)],
      measures.map((m) => m.size).toList()), isFalse);
    expect(b.applyClearance(719, groups, measures, policy), same(measures));
    final unready = [...measures];
    unready[2] = measure(WorkspaceSize.fullNatural, height: 85, ready: false);
    expect(b.applyClearance(1200, groups, unready, policy), same(unready));
    final invalid = budget(double.nan);
    expect(invalid.applyClearance(1200, groups, measures, policy), same(measures));
    final legacy = workspaceGeometry(1200, measures, policy: policy);
    final again = workspaceGeometry(1200, measures, policy: policy);
    expect(again.groups, legacy.groups);
    expect(again.contents, legacy.contents);
    expect(again.height, legacy.height);
    expect(again.groupReady, legacy.groupReady);
  });
}
