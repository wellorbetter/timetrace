import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_viewport_budget.dart';

WorkspaceDocument document({bool extras = false,
  Map<String, WorkspaceSize> sizes = const {}, bool foreign = false}) =>
  WorkspaceDocument(groups: [
    ['calendar'], ['bar', 'summary', 'apps', 'hourly'], ['diary'],
    if (extras) ['dailyPoetry'],
    if (extras) ['tasks'],
    if (foreign) ['foreign'],
  ], sizes: sizes);
void main() {
  test('preferred initial dimensions are finite and reduced not reapplied', () {
    expect(dashboardPreferredOuterWidth, 1280);
    expect(dashboardPreferredOuterHeight, 800);
  });
  for (final width in [719.0,720.0,1099.0,1100.0,1200.0]) {
    for (final scale in [1.0,2.0]) {
      for (final dpr in [1.0,1.25,1.5,2.0]) {
        test('pure saved prefix eligibility $width scale$scale dpr$dpr', () {
          // DPR is converted once to logical client size before local budget.
          final budget = dashboardPrefixBudget(
            document: document(extras: true), width: width*dpr/dpr,
            viewportHeight: 1000, textScale: scale, writable: true,
            loading: false, dirty: false, editing: false, diaryExpanded: false);
          expect(budget == null, width < 720);
          if (budget != null) {
            expect(budget.prefixGroups.length, 3);
            expect(budget.firstFoldExtent, 1000);
            expect(budget.contentHeights.keys, [0,1]);
          }
        });
      }
    }
  }
  test('custom size unknown dirty readonly editing expanded error cannot fit', () {
    Object? fit(WorkspaceDocument d, {bool dirty=false, bool writable=true,
      bool editing=false, bool expanded=false, bool loading=false,
      bool error=false, double height=800}) => dashboardPrefixBudget(
        document:d,width:1200,viewportHeight:height,textScale:1,
        writable:writable,loading:loading,dirty:dirty,editing:editing,
        diaryExpanded:expanded,hasError:error);
    expect(fit(document()), isNotNull);
    expect(fit(document(extras:true)), isNotNull);
    expect(fit(document(sizes:{'calendar':WorkspaceSize.twoByThree})), isNull);
    expect(fit(document(foreign:true)), isNull);
    expect(fit(WorkspaceDocument(groups:[['tasks'],['diary']])), isNull);
    expect(fit(document(),dirty:true), isNull);
    expect(fit(document(),writable:false), isNull);
    expect(fit(document(),editing:true), isNull);
    expect(fit(document(),expanded:true), isNull);
    expect(fit(document(),loading:true), isNull);
    expect(fit(document(),error:true), isNull);
    expect(fit(document(),height:200), isNull);
  });
}
