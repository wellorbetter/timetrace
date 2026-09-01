import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';

void main() {
  testWidgets('Dashboard Pomodoro gear deep-links to its Settings section', (
    tester,
  ) async {
    final router = _router('/dashboard');
    addTearDown(router.dispose);
    await _pumpApp(tester, router);

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('focus-quick-settings')));
    await _pumpUi(tester);

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/settings?section=focus',
    );
    final section = find.byKey(const ValueKey('focus-settings-section'));
    expect(section, findsOneWidget);
    final sectionRect = tester.getRect(section);
    expect(sectionRect.top, lessThan(180));
    expect(sectionRect.bottom, greaterThan(kToolbarHeight));
    expect(find.byKey(const ValueKey('focus-quick-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings Pomodoro gear scrolls back to its own section', (
    tester,
  ) async {
    final router = _router('/settings');
    addTearDown(router.dispose);
    await _pumpApp(tester, router);

    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -1600));
    await _pumpUi(tester);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('focus-settings-section')))
          .dy,
      lessThan(56),
    );

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('focus-quick-settings')));
    await _pumpUi(tester);

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/settings?section=focus',
    );
    final sectionRect = tester.getRect(
      find.byKey(const ValueKey('focus-settings-section')),
    );
    expect(sectionRect.top, lessThan(180));
    expect(sectionRect.bottom, greaterThan(kToolbarHeight));
    expect(tester.takeException(), isNull);
  });
}

GoRouter _router(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/dashboard', builder: (_, _) => const DashboardScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
  ],
);

Future<void> _pumpApp(WidgetTester tester, GoRouter router) async {
  await tester.binding.setSurfaceSize(const Size(1200, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(_FakeApi()),
        reminderRuntimeProvider.overrideWith(_FakeRuntimeNotifier.new),
      ],
      child: MaterialApp.router(
        theme: TimetraceTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await _pumpUi(tester);
}

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

final class _FakeRuntimeNotifier extends ReminderRuntimeNotifier {
  @override
  ReminderRuntimeState build() => ReminderRuntimeState(
    pomodoro: const PomodoroState(
      phase: PomodoroPhase.focus,
      intent: PomodoroIntent.running,
      remaining: Duration(minutes: 24, seconds: 59),
      phaseDuration: Duration(minutes: 25),
      completedFocusCount: 1,
    ),
    continuousUse: const ContinuousUseState.empty(),
    activity: null,
    configuration: ReminderConfigurationSnapshot(
      pomodoro: const PomodoroConfig(enabled: true),
      appTimeoutEnabled: false,
      appTimeoutNotificationsEnabled: false,
      appTimeoutNotificationSound: false,
      rulesRevision: 0,
    ),
    notificationHealth: const NotificationHealth.uninitialized(),
    tickCount: 0,
    lastCallbackWasGap: false,
  );
}

final class _FakeApi implements TimeTraceApi {
  @override
  ConfigDto getConfig() => ConfigDto(
    pollIntervalMs: BigInt.from(1000),
    idleThresholdMinutes: BigInt.from(5),
    minimizeToTray: true,
    startMinimized: false,
    autoStartTracking: true,
    excludedApps: const [],
    dbPath: '',
    pomodoro: PomodoroConfigDto(
      enabled: true,
      focusMinutes: BigInt.from(25),
      shortBreakMinutes: BigInt.from(5),
      longBreakMinutes: BigInt.from(15),
      longBreakInterval: BigInt.from(4),
      autoStartNext: false,
      notificationsEnabled: false,
      notificationSound: false,
    ),
    appTimeout: AppTimeoutConfigDto(
      enabled: false,
      defaultThresholdMinutes: BigInt.from(60),
      defaultCooldownMinutes: BigInt.from(30),
      notificationsEnabled: false,
      notificationSound: false,
    ),
  );

  @override
  void setConfig({required ConfigDto config}) {}

  @override
  List<AppTimeoutRuleDto> listAppTimeoutRules() => const [];

  @override
  DashboardDataDto getDashboardData({
    required String start,
    required String end,
  }) => const DashboardDataDto(
    apps: [
      AppUsageDto(
        appName: 'Visual Studio Code',
        activeSeconds: 1800,
        idleSeconds: 0,
        exePath: '',
      ),
      AppUsageDto(
        appName: 'Edge',
        activeSeconds: 900,
        idleSeconds: 0,
        exePath: '',
      ),
    ],
    activeSeconds: 2700,
    idleSeconds: 0,
    totalSeconds: 2700,
  );

  @override
  bool isDatabaseDegraded() => false;

  @override
  (int, int) getWeekTotals() => (2700, 1800);

  @override
  List<(String, int?, String)> getDiaryImagesDetailed({
    required String start,
    required String end,
  }) => const [];

  @override
  List<(String, String)> getDiaryEntries({
    required String start,
    required String end,
  }) => const [];

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) => const [];

  @override
  DayDetailDto getDayDetail({required String date}) => DayDetailDto(
    date: date,
    activeSeconds: 0,
    idleSeconds: 0,
    sessionCount: 0,
    diary: '',
    sessions: const [],
  );

  @override
  Int64List getDayHourly({required String date}) =>
      Int64List.fromList(List<int>.filled(24, 0));

  @override
  List<AppUsageDto> getHourApps({required String date, required int hour}) =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
