import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_body.dart';

void main() {
  testWidgets('compact recap keeps all primary information and opens detail', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(fontFamily: 'Microsoft YaHei UI'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 980,
              height: 60,
              child: RecapPreviewBody(
                key: const ValueKey('compact-recap-body'),
                eyebrow: 'AI RECAP · deepseek-v4-flash',
                title: '今天主要时间花在 Visual Studio Code',
                summary: '活跃时长 2h 20m，记录到 36 次应用切换。',
                aiEnhanced: true,
                compact: true,
                onOpen: () => opened = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('deepseek-v4-flash'), findsOneWidget);
    expect(find.textContaining('Visual Studio Code'), findsOneWidget);
    expect(find.textContaining('36 次应用切换'), findsOneWidget);
    expect(find.text('完整回顾'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('compact-recap-body'))).height,
      equals(60),
    );

    await tester.tap(find.text('完整回顾'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });
}
