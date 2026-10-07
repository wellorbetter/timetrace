import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/tray/tray_panel.dart';
import 'package:timetrace_app/src/core/window/window_presentation.dart';
import '../../core/window_presentation_test.dart' show FakeWindowPort, fakeMainSnapshot;
import 'package:timetrace_app/src/features/browsing/domain/canonical_feed_projection.dart';

TrayOverview fixture({bool paused = false, bool activity = false}) =>
    TrayOverview(
      paused: paused,
      projection: CanonicalFeedProjection.fromSnapshot(
        AccountingSnapshotDto(
          requestedStartUtc: '2026-10-03T00:00:00Z',
          requestedEndUtc: '2026-10-04T00:00:00Z',
          effectiveStartUtc: '2026-10-03T00:00:00Z',
          effectiveEndUtc: '2026-10-03T01:00:00Z',
          observedThroughUtc: '2026-10-03T01:00:00Z',
          totals: AccountingTotalsDto(
            activeSeconds: activity ? 20 : 0,
            idleSeconds: 0,
            pausedSeconds: 0,
            privacyExcludedSeconds: 0,
            systemGapSeconds: 0,
            unknownSeconds: 0,
            accountedSeconds: activity ? 20 : 0,
          ),
          intervals: activity
              ? [
                  AccountingIntervalDto(
                    startUtc: '2026-10-03T00:00:00Z',
                    endUtc: '2026-10-03T00:00:20Z',
                    state: AccountingStateDto.active,
                    appId: 'WindowsTerminal',
                    sourceIdentity: 'fixture',
                    sourceRevision: 1,
                  ),
                ]
              : [],
          apps: const [],
          windows: const [],
          pages: const [],
          hours: const [],
          integrity: SnapshotIntegrityDto.complete,
        ),
      ),
    );

void main() {
  test(
    'panel stays within negative-coordinate monitor and small work area',
    () {
      for (final area in [
        const Rect.fromLTWH(-1920, 0, 1920, 1040),
        const Rect.fromLTWH(0, 0, 320, 480),
      ]) {
        final panel = trayPanelBounds(
          area,
          Rect.fromLTWH(area.right - 30, area.bottom, 20, 20),
        );
        expect(panel.left, greaterThanOrEqualTo(area.left));
        expect(panel.top, greaterThanOrEqualTo(area.top));
        expect(panel.right, lessThanOrEqualTo(area.right));
        expect(panel.bottom, lessThanOrEqualTo(area.bottom));
      }
    },
  );
  for (final activity in [false, true]) {
    testWidgets('tray compact content and actions, activity=$activity', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(380, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var opened = false, dismissed = false, paused = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trayOverviewProvider.overrideWith(
              (ref) async => fixture(paused: true, activity: activity),
            ),
          ],
          child: MaterialApp(
            home: TrayPanel(
              onOpenWorkspace: () => opened = true,
              onSettings: () {},
              onDismiss: () => dismissed = true,
              onTogglePaused: () async {
                paused = true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text(activity ? '20 秒' : '今天还没有活动记录'), findsOneWidget);
      if (activity) expect(find.text('Windows Terminal'), findsNWidgets(2));
      await tester.tap(find.text('恢复追踪'));
      await tester.pump();
      expect(paused, isTrue);
      await tester.tap(find.byKey(const Key('tray_open_workspace')));
      expect(opened, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(dismissed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('panel Escape restores manual main state using latest desired, no native service', (tester) async {
    final port = FakeWindowPort();
    final p = WindowPresentation(port);
    addTearDown(p.dispose);
    await p.activate();
    await p.setDesired(true);
    expect(await p.enterPanel((_) async => trayPanelBounds(
      const Rect.fromLTWH(-1920, 0, 1920, 1040),
      const Rect.fromLTWH(-30, 1030, 20, 20),
    )), isTrue);
    await p.setDesired(false);
    var opened = false, paused = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [trayOverviewProvider.overrideWith(
        (ref) async => fixture(paused: true, activity: false),
      )],
      child: MaterialApp(home: TrayPanel(
        onOpenWorkspace: () => opened = true,
        onSettings: () {},
        onDismiss: () { p.leavePanel(); },
        onTogglePaused: () async { paused = true; },
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复追踪'));
    await tester.pump();
    expect(paused, isTrue);
    await tester.tap(find.byKey(const Key('tray_open_workspace')));
    expect(opened, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(port.restored, same(fakeMainSnapshot));
    expect(p.panelVisible, isFalse);
    expect(p.effectiveImmersive, isFalse);
    expect(p.maximized, isTrue);
    expect(p.resizable, isFalse);
    expect(port.calls, containsAllInOrder(['capture', 'hide', 'frame:true',
      'panel', 'hide', 'frame:false', 'restore']));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 10),
      EnginePhase.sendSemanticsUpdate, const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
