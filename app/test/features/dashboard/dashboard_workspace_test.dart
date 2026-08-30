import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_section.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  testWidgets('wide Overview keeps main workspace and equal-height cards', (
    tester,
  ) async {
    await _pumpDashboard(tester, const Size(1400, 1000));

    expect(find.byKey(const ValueKey('dashboard-summary-rail')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-calendar')), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-carousel')), findsOneWidget);
    expect(find.byType(DiarySection), findsOneWidget);

    final calendarCard = find.descendant(
      of: find.byKey(const ValueKey('dashboard-calendar')),
      matching: find.byType(Card),
    );
    final pageCard = find.byKey(const ValueKey('dashboard-app-bars'));
    expect(calendarCard, findsOneWidget);
    expect(pageCard, findsOneWidget);

    final calendarRect = tester.getRect(calendarCard);
    final pageRect = tester.getRect(pageCard);
    expect((calendarRect.height - pageRect.height).abs(), lessThan(1));

    final indicatorRect = tester.getRect(
      find.byKey(const ValueKey('dashboard-carousel-indicator')),
    );
    expect(indicatorRect.top, greaterThanOrEqualTo(pageRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Overview follows main carousel-before-calendar order', (
    tester,
  ) async {
    await _pumpDashboard(tester, const Size(700, 980));

    final carouselTop = tester
        .getTopLeft(find.byKey(const ValueKey('dashboard-carousel')))
        .dy;
    final calendarTop = tester
        .getTopLeft(find.byKey(const ValueKey('dashboard-calendar')))
        .dy;
    expect(carouselTop, lessThan(calendarTop));
    expect(find.byType(DiarySection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrows and dots target the visible carousel pages', (
    tester,
  ) async {
    await _pumpDashboard(tester, const Size(1400, 1000));

    expect(find.text('按应用'), findsOneWidget);
    await tester.tap(find.byTooltip('下一个视图'));
    await tester.pumpAndSettle();
    expect(find.text('占比'), findsOneWidget);

    await _tapCarouselDot(tester, '汇总');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-summary-card')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message == 'TFTTencentClient-Win64-Shipping',
        ),
      ),
      findsOneWidget,
    );

    final historyTooltip = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == '使用历史',
    );
    final historyDot = find.descendant(
      of: historyTooltip,
      matching: find.byType(InkWell),
    );
    expect(historyDot, findsOneWidget);
    await tester.tap(historyDot);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('dashboard-usage-history')),
      findsOneWidget,
    );
    expect(find.text('7s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('week summary and hourly pages use the whole selected range', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    await _pumpDashboard(tester, const Size(1400, 1000), api: api);

    await tester.tap(find.text('本周'));
    await tester.pumpAndSettle();

    await _tapCarouselDot(tester, '汇总');
    expect(
      find.byKey(const ValueKey('dashboard-range-summary')),
      findsOneWidget,
    );
    expect(find.text('范围汇总'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-range-summary')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message == 'TFTTencentClient-Win64-Shipping',
        ),
      ),
      findsOneWidget,
    );

    await _tapCarouselDot(tester, '时段');
    expect(find.text('时段分布 · 本周累计'), findsOneWidget);

    final selection = const DateRangeSelection(DateRange.week);
    final (start, end) = dashboardRangeDateBounds(selection);
    final expectedDates = <String>{};
    for (
      var day = start;
      !day.isAfter(end);
      day = day.add(const Duration(days: 1))
    ) {
      expectedDates.add(_formatDate(day));
    }
    expect(api.hourlyDates.toSet(), expectedDates);
    expect(api.hourAppDates.toSet(), expectedDates);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus carousel entry binds the process reminder runtime', (
    tester,
  ) async {
    final api = _FakeTimeTraceApi();
    await _pumpDashboard(tester, const Size(1400, 1000), api: api);

    await _tapCarouselDot(tester, '专注提醒');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('dashboard-focus-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);
    expect(api.activityReads, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pump();
    expect(find.text('活动暂停中'), findsOneWidget);

    api.activityState = 'excluded';
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('活动暂停中'), findsNothing);
    expect(find.text('24:59'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('English carousel controls include the Focus view', (
    tester,
  ) async {
    await _pumpDashboard(tester, const Size(1400, 1000), englishLocale: true);

    expect(find.byTooltip('Previous view'), findsOneWidget);
    expect(find.byTooltip('Next view'), findsOneWidget);
    await _tapCarouselDot(tester, 'Focus reminders');
    expect(find.byKey(const ValueKey('dashboard-focus-page')), findsOneWidget);
  });
}

Future<void> _tapCarouselDot(WidgetTester tester, String label) async {
  final tooltip = find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == label,
  );
  await tester.tap(
    find.descendant(of: tooltip, matching: find.byType(InkWell)),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  Size size, {
  _FakeTimeTraceApi? api,
  bool englishLocale = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api ?? _FakeTimeTraceApi()),
        if (englishLocale)
          localeProvider.overrideWith(_EnglishLocaleNotifier.new),
      ],
      child: MaterialApp(
        theme: TimetraceTheme.light(),
        home: const DashboardScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _EnglishLocaleNotifier extends LocaleNotifier {
  @override
  AppLocale build() => AppLocale.en;
}

class _FakeTimeTraceApi implements TimeTraceApi {
  final List<String> hourlyDates = [];
  final List<String> hourAppDates = [];
  String activityState = 'idle';
  int activityReads = 0;

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
      notificationsEnabled: true,
      notificationSound: false,
    ),
    appTimeout: AppTimeoutConfigDto(
      enabled: false,
      defaultThresholdMinutes: BigInt.from(60),
      defaultCooldownMinutes: BigInt.from(30),
      notificationsEnabled: true,
      notificationSound: false,
    ),
  );

  @override
  List<AppTimeoutRuleDto> listAppTimeoutRules() => const [];

  @override
  ActivitySnapshotDto getActivitySnapshot() {
    activityReads++;
    return ActivitySnapshotDto(
      revision: activityReads,
      state: activityState,
      trackingPaused: false,
      isIdle: activityState == 'idle',
      observedAt: '2026-08-31T12:00:00Z',
    );
  }

  @override
  DashboardDataDto getDashboardData({
    required String start,
    required String end,
  }) => const DashboardDataDto(
    apps: [
      AppUsageDto(
        appName: 'TFTTencentClient-Win64-Shipping',
        activeSeconds: 3600,
        idleSeconds: 0,
        exePath: '',
      ),
      AppUsageDto(
        appName: 'Edge',
        activeSeconds: 600,
        idleSeconds: 0,
        exePath: '',
      ),
    ],
    activeSeconds: 4200,
    idleSeconds: 0,
    totalSeconds: 4200,
  );

  @override
  bool isDatabaseDegraded() => false;

  @override
  (int, int) getWeekTotals() => (4200, 3600);

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
  String exportCsv({required String start, required String end}) => '';

  @override
  String? getDiaryDraft({required String date}) => null;

  @override
  DayDetailDto getDayDetail({required String date}) => DayDetailDto(
    date: date,
    activeSeconds: 7,
    idleSeconds: 0,
    sessionCount: 1,
    diary: '',
    sessions: const [
      DaySessionDto(
        appName: 'TFTTencentClient-Win64-Shipping',
        isIdle: false,
        durationSecs: 7,
        startedAt: '10:00:00',
      ),
    ],
  );

  @override
  Int64List getDayHourly({required String date}) {
    hourlyDates.add(date);
    final values = List<int>.filled(24, 0)..[9] = 10;
    return Int64List.fromList(values);
  }

  @override
  List<AppUsageDto> getHourApps({required String date, required int hour}) {
    hourAppDates.add(date);
    return const [
      AppUsageDto(
        appName: 'TFTTencentClient-Win64-Shipping',
        activeSeconds: 10,
        idleSeconds: 0,
        exePath: '',
      ),
    ];
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
