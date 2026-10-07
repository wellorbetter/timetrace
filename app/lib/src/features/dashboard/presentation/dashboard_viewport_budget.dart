import '../../../core/workspace/workspace_geometry.dart';
import '../../../core/workspace/workspace_model.dart';

const dashboardPreferredOuterWidth = 1280.0;
const dashboardPreferredOuterHeight = 800.0;
const _prefix = [
  ['calendar'],
  ['bar', 'summary', 'apps', 'hourly'],
  ['diary'],
];
const _known = {
  'calendar', 'bar', 'summary', 'apps', 'hourly', 'diary',
  'dailyPoetry', 'pomodoro', 'countdown', 'tasks',
};

/// Pure eligibility and maximum first-row budget. The renderer subtracts its
/// own actual natural diary/chrome heights; no guessed68px diary or cached size.
WorkspacePrefixPresentationBudget? dashboardPrefixBudget({
  required WorkspaceDocument document,
  required double width,
  required double viewportHeight,
  required double textScale,
  required bool writable,
  required bool loading,
  required bool dirty,
  required bool editing,
  required bool diaryExpanded,
  bool hasError = false,
}) {
  if (!writable || loading || dirty || editing || diaryExpanded || hasError ||
      !width.isFinite || width < 720 ||
      !viewportHeight.isFinite || viewportHeight <= 0 ||
      !textScale.isFinite || textScale <= 0 ||
      document.metadata.isNotEmpty || document.groups.length < 3 ||
      document.groups.expand((g) => g).any((id) => !_known.contains(id))) {
    return null;
  }
  for (var i = 0; i < 3; i++) {
    final group = document.groups[i];
    if (group.length != _prefix[i].length ||
        List.generate(group.length, (j) =>
            group[j] != _prefix[i][j]).any((v) => v)) return null;
    // An explicit prefix size is a user-owned choice, including metadata.
    if (group.any(document.sizes.containsKey)) return null;
  }
  // Readable calendar target, not scaling the calendar down to fit. When
  // this plus measured diary/navigation cannot fit the host uses natural scroll.
  final minimum = 360.0 * textScale.clamp(1.0, 2.0);
  if (viewportHeight < minimum) return null;
  return WorkspacePrefixPresentationBudget(
    prefixGroups: _prefix,
    contentHeights: {0: viewportHeight, 1: viewportHeight},
    firstFoldExtent: viewportHeight,
    minimumContentHeight: minimum,
  );
}
