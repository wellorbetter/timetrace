import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';

void main() {
  const apps = [
    AppUsageItem(
      appName: 'Visual Studio Code',
      activeSeconds: 3600,
      idleSeconds: 0,
    ),
    AppUsageItem(appName: 'Chrome', activeSeconds: 1800, idleSeconds: 0),
    AppUsageItem(appName: 'Terminal', activeSeconds: 600, idleSeconds: 0),
  ];

  testWidgets('legend selection links a pie segment to its app index', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 400,
            child: PieChartCard(
              apps: apps,
              onSelectApp: (index) => selected = index,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('pie-legend-1')));
    await tester.pumpAndSettle();

    expect(selected, 1);
  });

  testWidgets('selected app is exposed without hiding any legend entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 330,
            child: PieChartCard(apps: apps, selectedIndex: 0),
          ),
        ),
      ),
    );

    expect(find.text('Visual Studio Code'), findsOneWidget);
    expect(find.text('Chrome'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
