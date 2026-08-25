import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  testWidgets(
    'dashboard opens on the linked report and top chips own its range',
    (tester) async {
      final port = _CountingPort();
      await tester.binding.setSurfaceSize(const Size(1100, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardProvider.overrideWith(_StaticDashboardNotifier.new),
            dashboardOrderProvider.overrideWith(_StaticOrderNotifier.new),
            aiRecapPortProvider.overrideWithValue(port),
          ],
          child: const MaterialApp(home: DashboardScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('ai-recap-dashboard-section')),
        findsOneWidget,
      );
      expect(find.text('今日'), findsOneWidget);
      expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
      expect(port.generateCalls, 0);

      await tester.tap(find.widgetWithText(ChoiceChip, '本周'));
      await tester.pumpAndSettle();

      expect(find.text('本周（截至今日）'), findsOneWidget);
      expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
      expect(port.generateCalls, 0);
    },
  );

  testWidgets('report scroll offset survives a complete carousel wrap', (
    tester,
  ) async {
    final now = DateTime.now();
    final report = AiRecapResult(
      rangeKey: AiRecapRangeKey(
        scope: AiRecapScope.daily,
        startDate: now,
        endDate: now,
      ),
      generatedAt: now,
      providerId: AiRecapProviderId.localSummary,
      model: AiRecapModel.localSummary,
      summary: AiRecapStatement(
        text: List.filled(80, '这是用于验证轮播阅读位置恢复的本地总结。').join(),
        evidence: const [],
      ),
      highlights: const [],
      suggestions: const [],
      totalActiveSeconds: 3600,
      applicationCount: 1,
    );
    final port = _CountingPort(reports: [report]);
    await tester.binding.setSurfaceSize(const Size(1100, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardProvider.overrideWith(_StaticDashboardNotifier.new),
          dashboardOrderProvider.overrideWith(_StaticOrderNotifier.new),
          aiRecapPortProvider.overrideWithValue(port),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final reportScroll = find.byKey(const Key('ai-recap-linked-scroll'));
    expect(reportScroll, findsOneWidget);
    await tester.drag(reportScroll, const Offset(0, -220));
    await tester.pumpAndSettle();
    final offsetBeforeWrap = tester
        .widget<SingleChildScrollView>(reportScroll)
        .controller!
        .offset;
    expect(offsetBeforeWrap, greaterThan(0));

    for (var i = 0; i < kDefaultOrder.length; i++) {
      await tester.tap(find.byTooltip('下一个视图'));
      await tester.pumpAndSettle();
    }

    expect(reportScroll, findsOneWidget);
    final offsetAfterWrap = tester
        .widget<SingleChildScrollView>(reportScroll)
        .controller!
        .offset;
    expect(offsetAfterWrap, moreOrLessEquals(offsetBeforeWrap, epsilon: 1));
    expect(port.generateCalls, 0);
  });
}

class _StaticDashboardNotifier extends DashboardNotifier {
  @override
  Future<DashboardState> build() async => const DashboardState(
    apps: [],
    totalActiveSeconds: 0,
    totalIdleSeconds: 0,
    lifetimeSeconds: 0,
  );
}

class _StaticOrderNotifier extends DashboardOrderNotifier {
  @override
  List<String> build() => List.of(kDefaultOrder);
}

class _CountingPort implements AiRecapPort {
  _CountingPort({this.reports = const []});

  final List<AiRecapResult> reports;
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() => const AiRecapProviderStatus();

  @override
  List<AiRecapResult> latestReports() => reports;

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) {
    generateCalls++;
    throw StateError('Generation is not expected in this test');
  }
}
