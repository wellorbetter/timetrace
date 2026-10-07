import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/accounting_summary_strip.dart';

Widget _surface(AccountingSummaryStrip strip) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 520, child: strip)),
);

void main() {
  testWidgets(
    'partial summary uses Rust accounted total and every nonzero gap',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _surface(
            const AccountingSummaryStrip(
              activeSeconds: 3000,
              idleSeconds: 600,
              accountedSeconds: 3840,
              pausedSeconds: 120,
              privacyExcludedSeconds: 60,
              systemGapSeconds: 40,
              unknownSeconds: 20,
              integrity: SnapshotIntegrityDto.partial,
            ),
          ),
        );
        expect(find.bySemanticsLabel('已计入时间，1 小时 4 分钟'), findsOneWidget);
        expect(
          find.text('数据完整性：暂停 2 分钟，隐私排除 1 分钟，系统间隔 40 秒，未知 20 秒'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('complete snapshot does not show an integrity notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      _surface(
        const AccountingSummaryStrip(
          activeSeconds: 3000,
          idleSeconds: 600,
          accountedSeconds: 3840,
          pausedSeconds: 120,
          privacyExcludedSeconds: 60,
          systemGapSeconds: 40,
          unknownSeconds: 20,
          integrity: SnapshotIntegrityDto.complete,
        ),
      ),
    );
    expect(find.textContaining('数据完整性'), findsNothing);
  });

  testWidgets('partial snapshot remains visible when all gap totals are zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      _surface(
        const AccountingSummaryStrip(
          activeSeconds: 3000,
          idleSeconds: 600,
          accountedSeconds: 3600,
          pausedSeconds: 0,
          privacyExcludedSeconds: 0,
          systemGapSeconds: 0,
          unknownSeconds: 0,
          integrity: SnapshotIntegrityDto.partial,
        ),
      ),
    );
    expect(find.text('数据完整性：部分时段未确认'), findsOneWidget);
  });
}
