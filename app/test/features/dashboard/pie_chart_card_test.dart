import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';

void main() {
  testWidgets('original donut keeps a readable legend with full-name tooltip', (
    tester,
  ) async {
    const longName = 'TFTTencentClient-Win64-Shipping';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 400,
            child: PieChartCard(
              apps: [
                AppUsageItem(
                  appName: longName,
                  activeSeconds: 3600,
                  idleSeconds: 0,
                ),
                AppUsageItem(
                  appName: 'Edge',
                  activeSeconds: 1800,
                  idleSeconds: 0,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('占比'), findsOneWidget);
    expect(find.text(longName), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == longName,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('many applications remain five slices plus other', (
    tester,
  ) async {
    final apps = List.generate(
      8,
      (index) => AppUsageItem(
        appName: '应用 $index',
        activeSeconds: 3600 - index * 300,
        idleSeconds: 0,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 620,
            height: 380,
            child: PieChartCard(apps: apps),
          ),
        ),
      ),
    );

    expect(find.text('应用 0'), findsOneWidget);
    expect(find.text('应用 4'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
    expect(find.text('应用 5'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
