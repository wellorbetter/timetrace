import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/dashboard_summary_strip.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  test('dashboard hides optional charts by default', () {
    expect(dashboardVisibleOrder(kDefaultOrder, kDefaultHiddenViews), [
      'summary',
      'apps',
      'hourly',
    ]);
    expect(dashboardVisibleOrder(kDefaultOrder, const {}), kDefaultOrder);
  });

  testWidgets('summary rail keeps the long top application readable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(),
        home: const Scaffold(
          body: SizedBox(
            width: 1080,
            child: DashboardSummaryStrip(
              state: _state,
              apps: _apps,
              compact: true,
            ),
          ),
        ),
      ),
    );

    final appName = find.text('TFTTencentClient-Win64-Shipping');
    expect(appName, findsOneWidget);
    expect(tester.widget<Text>(appName).maxLines, 2);
    expect(
      find.byKey(const ValueKey('dashboard-summary-rail')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('application bars cap dense data without shrinking labels', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 620,
            height: 360,
            child: AppChartSection(
              apps: _manyApps,
              selected: null,
              onSelect: (index) => selected = index,
              tall: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('前 6 / 10 个 · 点击查看会话'), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(6));

    await tester.tap(find.text('应用 01'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded page sessions use a fixed internal viewport', (
    tester,
  ) async {
    final rowKeys = List.generate(_apps.length, (_) => GlobalKey());
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 620,
            height: 420,
            child: SingleChildScrollView(
              child: AppListSection(
                apps: _apps,
                selected: 0,
                pages: _pages,
                loading: false,
                onSelect: (_) {},
                rowKeys: rowKeys,
              ),
            ),
          ),
        ),
      ),
    );

    final detailList = find.byKey(const ValueKey('app-page-detail-list'));
    expect(detailList, findsOneWidget);
    expect(tester.getSize(detailList).height, 120);

    await tester.drag(detailList, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('页面 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _apps = [
  AppUsageItem(
    appName: 'TFTTencentClient-Win64-Shipping',
    activeSeconds: 14400,
    idleSeconds: 0,
  ),
  AppUsageItem(appName: 'Edge', activeSeconds: 1200, idleSeconds: 0),
];

const _state = DashboardState(
  apps: _apps,
  totalActiveSeconds: 15600,
  totalIdleSeconds: 300,
  lifetimeSeconds: 50000,
);

final _manyApps = List.generate(
  10,
  (index) => AppUsageItem(
    appName: index == 0
        ? 'TFTTencentClient-Win64-Shipping'
        : '应用 ${index.toString().padLeft(2, '0')}',
    activeSeconds: 7200 - index * 500,
    idleSeconds: 0,
  ),
);

final _pages = List.generate(
  8,
  (index) => PageDto(title: '页面 $index', seconds: 900 - index * 60),
);
