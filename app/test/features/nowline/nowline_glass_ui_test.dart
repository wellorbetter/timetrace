import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_glass_surface.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_timeline_view.dart';

void main() {
  testWidgets(
    'functional glass uses blur with an opaque high-contrast fallback',
    (tester) async {
      await tester.pumpWidget(_glassHarness(highContrast: false));
      expect(find.byType(BackdropFilter), findsOneWidget);

      await tester.pumpWidget(_glassHarness(highContrast: true));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timeline stays readable at narrow desktop widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: NowlineTimelineView(
                timeline: _timeline,
                preferences: NowlinePreferences(),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('玻璃边界'), findsOneWidget);
    expect(find.textContaining('当前活动'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current activity is announced as one contextual live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: TimetraceTheme.light(),
          home: Scaffold(
            body: NowlineTimelineView(
              timeline: _timeline,
              preferences: NowlinePreferences(),
            ),
          ),
        ),
      );

      expect(
        find.bySemanticsLabel(RegExp('当前活动.*10:08.*当前活动')),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });
}

Widget _glassHarness({required bool highContrast}) => MaterialApp(
  theme: TimetraceTheme.dark(),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(highContrast: highContrast),
      child: const Center(
        child: NowlineGlassSurface(
          role: NowlineGlassRole.functional,
          child: Text('Nowline'),
        ),
      ),
    ),
  ),
);

final _timeline = NowlineTimeline(
  revision: 2,
  paused: false,
  lines: [
    NowlineLine(
      id: 1,
      text: '调整桌面端玻璃边界与暗色对比度',
      detail: '18 分钟 · feature/nowline-overlay',
      startedAt: DateTime(2026, 8, 30, 9, 50),
      duration: const Duration(minutes: 18),
      isCurrent: false,
      isIdle: false,
    ),
    NowlineLine(
      id: 2,
      text: '当前活动正在检查响应式布局',
      detail: '本地 · 不调用模型',
      startedAt: DateTime(2026, 8, 30, 10, 8),
      duration: const Duration(minutes: 4),
      isCurrent: true,
      isIdle: false,
    ),
  ],
);
