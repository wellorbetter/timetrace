import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/accounting_summary_strip.dart';

DashboardState _state({required int activeSeconds, required int idleSeconds}) {
  return DashboardState(
    apps: const [],
    appAttribution: const [],
    windows: const [],
    pages: const [],
    hours: const [],
    totalActiveSeconds: activeSeconds,
    totalIdleSeconds: idleSeconds,
    pausedSeconds: 0,
    privacyExcludedSeconds: 0,
    systemGapSeconds: 0,
    unknownSeconds: 0,
    accountedSeconds: activeSeconds + idleSeconds,
    integrity: SnapshotIntegrityDto.complete,
    requestedStartUtc: '2026-09-30T00:00:00Z',
    requestedEndUtc: '2026-10-01T00:00:00Z',
    effectiveStartUtc: '2026-09-30T00:00:00Z',
    effectiveEndUtc: '2026-10-01T00:00:00Z',
    observedThroughUtc: '2026-10-01T00:00:00Z',
  );
}

Widget _stripFor(DashboardState state) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 720,
        child: AccountingSummaryStrip.fromState(state),
      ),
    ),
  );
}

void main() {
  testWidgets('formats conserved active, idle, and accounted totals', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _stripFor(_state(activeSeconds: 3000, idleSeconds: 600)),
      );

      expect(find.text('活跃'), findsOneWidget);
      expect(find.text('离开'), findsOneWidget);
      expect(find.text('已计入'), findsOneWidget);
      expect(find.text('50 分钟'), findsOneWidget);
      expect(find.text('10 分钟'), findsOneWidget);
      expect(find.text('1 小时'), findsOneWidget);
      expect(find.bySemanticsLabel('活跃时间，50 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('离开时间，10 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('已计入时间，1 小时'), findsOneWidget);
      expect(find.textContaining('数据完整性'), findsNothing);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('shows only non-zero completeness details without overflow', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(280, 420));
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountingSummaryStrip(
                activeSeconds: 3000,
                idleSeconds: 600,
                accountedSeconds: 3780,
                pausedSeconds: 0,
                privacyExcludedSeconds: 0,
                systemGapSeconds: 120,
                unknownSeconds: 60,
                integrity: SnapshotIntegrityDto.partial,
              ),
            ),
          ),
        ),
      );

      expect(find.text('数据完整性：系统间隔 2 分钟，未知 1 分钟'), findsOneWidget);
      expect(
        find.bySemanticsLabel('数据完整性提示。系统间隔时间，2 分钟；未知时间，1 分钟'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('summary refresh keeps visible totals monotonic', (tester) async {
    final initial = _state(activeSeconds: 1200, idleSeconds: 600);
    final grown = _state(activeSeconds: 3000, idleSeconds: 600);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_stripFor(initial));

      expect(find.bySemanticsLabel('活跃时间，20 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('离开时间，10 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('已计入时间，30 分钟'), findsOneWidget);

      await tester.pumpWidget(_stripFor(grown));

      expect(find.bySemanticsLabel('活跃时间，20 分钟'), findsNothing);
      expect(find.bySemanticsLabel('活跃时间，50 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('离开时间，10 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('已计入时间，1 小时'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
