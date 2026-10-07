import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/workspace/workspace_geometry.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import '../workspace_registry_integration_test.dart' show AdapterFixture;
import '../../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;

String dayKey(int day) => '2026-05-${day.toString().padLeft(2, '0')}';
void checkGlyphs(WidgetTester tester, Finder finder, Rect bounds) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = tester.widget<Text>(finder).data!;
  expect(paragraph.didExceedMaxLines, isFalse);
  for (var index = 0; index < text.length; index++) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + 1),
    );
    expect(boxes, isNotEmpty);
    for (final box in boxes) {
      final glyph = MatrixUtils.transformRect(
        paragraph.getTransformTo(null),
        box.toRect(),
      );
      expect(glyph.left, greaterThanOrEqualTo(bounds.left - .1));
      expect(glyph.right, lessThanOrEqualTo(bounds.right + .1));
      expect(glyph.top, greaterThanOrEqualTo(bounds.top - .1));
      expect(glyph.bottom, lessThanOrEqualTo(bounds.bottom + .1));
    }
  }
}

void main() {
  const policy = WorkspaceGeometryPolicy();
  final sizes = [
    const Size(478, 358),
    const Size(280, 320),
    const Size(440, 320),
    const Size(440, 480),
    const Size(232, 320),
    Size(
      policy.widthFor(1000, WorkspaceSize.twoByTwo),
      policy.heightFor(WorkspaceSize.twoByTwo),
    ),
    Size(
      policy.widthFor(1000, WorkspaceSize.twoByThree),
      policy.heightFor(WorkspaceSize.twoByThree),
    ),
  ];
  for (final scale in [1.0, 2.0]) {
    for (var i = 0; i < sizes.length; i++) {
      final size = sizes[i];
      testWidgets(
        'actual seven columns six weeks glyphs size $i $size scale $scale',
        (tester) async {
          final f = AdapterFixture(MemoryPreferencesBackend());
          DateTime? selected;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: f.container,
              child: MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: MediaQuery(
                      data: MediaQueryData(
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        key: const Key('calendar_actual_card'),
                        child: WorkspaceCalendarContent(
                          selected: DateTime(2026, 5, 1),
                          rangeLabel: '所选日',
                          onSelected: (date) => selected = date,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final body = tester.getRect(
            find.byKey(const Key('calendar_fit_body')),
          );
          for (var d = 1; d <= 31; d++) {
            final cell = tester.getRect(
              find.byKey(ValueKey('calendar_cell_' + dayKey(d))),
            );
            final number = find.byKey(ValueKey('calendar_date_' + dayKey(d)));
            checkGlyphs(tester, number, cell);
            final lunar = find.byKey(ValueKey('calendar_lunar_' + dayKey(d)));
            if (lunar.evaluate().isNotEmpty) {
              final p = tester.renderObject<RenderParagraph>(lunar);
              expect(
                tester.getRect(lunar).bottom,
                lessThanOrEqualTo(cell.bottom + .1),
              );
              if (p.didExceedMaxLines) {
                expect(
                  tester.widget<Text>(lunar).overflow,
                  TextOverflow.ellipsis,
                );
                final semantic = find
                    .ancestor(
                      of: lunar,
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is Semantics &&
                            widget.properties.label == dayKey(d),
                      ),
                    )
                    .first;
                expect(
                  tester.widget<Semantics>(semantic).properties.value,
                  contains(tester.widget<Text>(lunar).data!),
                );
              }
            }
            expect(
              find.ancestor(of: number, matching: find.byType(FittedBox)),
              findsNothing,
            );
            final p = tester.renderObject<RenderParagraph>(number);
            final transform = p.getTransformTo(null).storage;
            final painted = math.sqrt(
              transform[0] * transform[0] + transform[1] * transform[1],
            );
            expect(painted, closeTo(1, .001));
            final style = tester.widget<Text>(number).style!;
            final effective = MediaQuery.textScalerOf(
              tester.element(number),
            ).scale(style.fontSize!);
            final old =
                math.min((size.width - 16) / 280, body.height / 322) * 15;
            expect(effective, greaterThanOrEqualTo(old - .1));
            if (i == 0) expect(effective, greaterThanOrEqualTo(15));
          }
          for (var col = 0; col < 7; col++) {
            final cell = tester.getRect(
              find.byKey(ValueKey('calendar_cell_' + dayKey(3 + col))),
            );
            expect(cell.width, closeTo(body.width / 7, .1));
            expect(
              cell.center.dx,
              closeTo(body.left + (col + .5) * body.width / 7, .1),
            );
          }
          final first = tester.getRect(
            find.byKey(ValueKey('calendar_cell_' + dayKey(1))),
          );
          final last = tester.getRect(
            find.byKey(ValueKey('calendar_cell_' + dayKey(31))),
          );
          expect(last.top - first.top, closeTo(first.height * 5, .1));
          expect(last.bottom, closeTo(body.bottom, .1));
          for (final key in [
            'calendar_month_previous',
            'calendar_month_next',
          ]) {
            final action = find.byKey(Key(key));
            expect(tester.getSize(action), const Size(48, 48));
            expect(action.hitTestable(), findsOneWidget);
          }
          final title = find.byKey(const Key('calendar_month_title'));
          checkGlyphs(
            tester,
            title,
            tester.getRect(find.byKey(const Key('calendar_month_title_fit'))),
          );
          expect(find.byType(SingleChildScrollView), findsNothing);
          await tester.tap(find.byKey(ValueKey('calendar_date_' + dayKey(28))));
          await tester.pump();
          expect(
            (selected!.year, selected!.month, selected!.day),
            (2026, 5, 28),
          );
          await tester.tap(find.byKey(const Key('calendar_month_next')));
          await tester.pumpAndSettle();
          expect(find.text('2026年6月'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'bounded semantic keyboard and future prohibition preserve date identity',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend());
      final semantics = tester.ensureSemantics();
      DateTime? selected;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 440,
                height: 480,
                child: CalendarGrid(
                  selected: DateTime(2026, 5, 1),
                  boundedFit: true,
                  onSelected: (day) => selected = day,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final number = find.byKey(ValueKey('calendar_date_' + dayKey(28)));
      final focus = find
          .ancestor(of: number, matching: find.byType(FocusableActionDetector))
          .first;
      expect(focus, findsOneWidget);
      Focus.of(tester.element(number)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect((selected!.year, selected!.month, selected!.day), (2026, 5, 28));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 440,
                height: 480,
                child: CalendarGrid(
                  selected: DateTime(2099, 5, 1),
                  boundedFit: true,
                  onSelected: (day) => selected = day,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar_date_2099-05-28')));
      await tester.pump();
      expect((selected!.year, selected!.month, selected!.day), (2026, 5, 28));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
