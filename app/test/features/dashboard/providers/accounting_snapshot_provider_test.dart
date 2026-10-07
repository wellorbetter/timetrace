import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';

AccountingTotalsDto _totals({
  int active = 3000,
  int idle = 600,
  int paused = 0,
  int privacy = 0,
  int gap = 0,
  int unknown = 0,
  int? accounted,
}) => AccountingTotalsDto(
  activeSeconds: active,
  idleSeconds: idle,
  pausedSeconds: paused,
  privacyExcludedSeconds: privacy,
  systemGapSeconds: gap,
  unknownSeconds: unknown,
  accountedSeconds:
      accounted ?? active + idle + paused + privacy + gap + unknown,
);

AccountingSnapshotDto _snapshot({
  AccountingTotalsDto? totals,
  SnapshotIntegrityDto integrity = SnapshotIntegrityDto.complete,
  String effectiveEnd = '2026-09-30T10:00:00Z',
  String observedThrough = '2026-09-30T10:00:00Z',
  List<LocalHourBucketDto> hours = const [],
}) => AccountingSnapshotDto(
  requestedStartUtc: '2026-09-30T00:00:00Z',
  requestedEndUtc: '2026-10-01T00:00:00Z',
  effectiveStartUtc: '2026-09-30T00:00:00Z',
  effectiveEndUtc: effectiveEnd,
  observedThroughUtc: observedThrough,
  totals: totals ?? _totals(),
  intervals: const [],
  apps: const [AttributionTotalDto(id: 'editor', seconds: 3000)],
  windows: const [
    AttributionTotalDto(id: 'main', parentId: 'editor', seconds: 2000),
  ],
  pages: const [
    AttributionTotalDto(id: 'document', parentId: 'main', seconds: 500),
  ],
  integrity: integrity,
  hours: hours,
);

List<LocalHourBucketDto> _hours(int count) => [
  for (var index = 0; index < count; index++)
    LocalHourBucketDto(
      stableId: '2026-11-01/$index/fold-${index == 2 ? 1 : 0}',
      localDate: '2026-11-01',
      localHour: index == 2 ? 1 : index % 24,
      utcOffsetSeconds: index == 2 ? -18000 : -14400,
      fold: index == 2 ? 1 : 0,
      startUtc: '2026-11-01T${index.toString().padLeft(2, '0')}:00:00Z',
      endUtc: '2026-11-01T${(index + 1).toString().padLeft(2, '0')}:00:00Z',
      totals: _totals(active: 60, idle: 0),
      apps: const [AttributionTotalDto(id: 'editor', seconds: 60)],
    ),
];

void main() {
  test(
    'IANA source fails closed without native init and supports override',
    () {
      final defaultContainer = ProviderContainer();
      addTearDown(defaultContainer.dispose);
      expect(defaultContainer.read(dashboardIanaTimezoneProvider), isNull);

      final overridden = ProviderContainer(
        overrides: [
          dashboardIanaTimezoneProvider.overrideWithValue('America/New_York'),
        ],
      );
      addTearDown(overridden.dispose);
      expect(
        overridden.read(dashboardIanaTimezoneProvider),
        'America/New_York',
      );
    },
  );

  test('projects six Rust states and conserves the 3000/600 baseline', () {
    final state = projectAccountingSnapshot(_snapshot());
    expect(state.totalActiveSeconds, 3000);
    expect(state.totalIdleSeconds, 600);
    expect(state.accountedSeconds, 3600);
    expect(state.integrity, SnapshotIntegrityDto.complete);
    expect(state.apps.single.activeSeconds, 3000);
    expect(state.apps.single.idleSeconds, 0);
    expect(state.appAttribution.single.seconds, 3000);
    expect(state.windows.single.parentId, 'editor');
    expect(state.pages.single.parentId, 'main');
    expect(state.requestedEndUtc, '2026-10-01T00:00:00Z');
    expect(state.observedThroughUtc, '2026-09-30T10:00:00Z');
  });

  test('preserves partial integrity and Rust-supplied accounted seconds', () {
    final state = projectAccountingSnapshot(
      _snapshot(
        totals: _totals(paused: 120, privacy: 60, gap: 40, unknown: 20),
        integrity: SnapshotIntegrityDto.partial,
      ),
      databaseDegraded: true,
    );
    expect(
      [
        state.totalActiveSeconds,
        state.totalIdleSeconds,
        state.pausedSeconds,
        state.privacyExcludedSeconds,
        state.systemGapSeconds,
        state.unknownSeconds,
      ],
      [3000, 600, 120, 60, 40, 20],
    );
    expect(state.accountedSeconds, 3840);
    expect(state.databaseDegraded, isTrue);
    expect(
      projectAccountingSnapshot(
        _snapshot(totals: _totals(accounted: 9999)),
      ).accountedSeconds,
      9999,
    );
  });

  test('keeps all stable hour IDs through 23 and 25 bucket projections', () {
    for (final count in [23, 25]) {
      final buckets = _hours(count);
      final state = projectAccountingSnapshot(_snapshot(hours: buckets));
      expect(state.hours.length, count);
      expect(
        state.hours.map((hour) => hour.stableId),
        buckets.map((hour) => hour.stableId),
      );
      if (count == 25) expect(state.hours[2].fold, 1);
    }
  });

  test('repeated local hour keeps distinct stable focus identity', () {
    final buckets = _hours(25);
    final repeated = buckets.where((bucket) => bucket.localHour == 1).toList();
    expect(repeated, hasLength(2));

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(hourlyFocusProvider.notifier);
    notifier.focus(DateTime(2026, 11, 1), repeated.first);
    final first = container.read(hourlyFocusProvider)!;
    notifier.focus(DateTime(2026, 11, 1), repeated.last);
    final second = container.read(hourlyFocusProvider)!;

    expect(first.stableId, isNot(second.stableId));
    expect(first.fold, 0);
    expect(second.fold, 1);
    expect(first.localHour, second.localHour);
  });

  test('window drill-down filters snapshot windows by parent app id', () {
    final windows = <AttributionTotalDto>[
      const AttributionTotalDto(
        id: 'editor.dart',
        parentId: 'editor',
        seconds: 30,
      ),
      const AttributionTotalDto(id: 'browser', parentId: 'web', seconds: 20),
      const AttributionTotalDto(
        id: 'terminal',
        parentId: 'editor',
        seconds: 10,
      ),
    ];

    expect(windowsForApp(windows, 'editor').map((window) => window.id), [
      'editor.dart',
      'terminal',
    ]);
  });

  test('rejects older observed-through or effective boundary', () {
    final current = projectAccountingSnapshot(_snapshot());
    final newer = projectAccountingSnapshot(
      _snapshot(
        effectiveEnd: '2026-09-30T11:00:00Z',
        observedThrough: '2026-09-30T11:00:00Z',
      ),
    );
    var visible = current;
    for (final response in [newer, current]) {
      if (snapshotIsNewer(response, visible)) visible = response;
    }
    expect(visible, newer);
    expect(
      snapshotIsNewer(
        projectAccountingSnapshot(
          _snapshot(observedThrough: '2026-09-30T09:00:00Z'),
        ),
        current,
      ),
      isFalse,
    );
    expect(
      snapshotIsNewer(
        projectAccountingSnapshot(
          _snapshot(effectiveEnd: '2026-09-30T09:00:00Z'),
        ),
        current,
      ),
      isFalse,
    );
    expect(snapshotIsNewer(newer, current), isTrue);
  });

  test('accepts Rust local-date bounds without matching Dart UTC guesses', () {
    final now = DateTime(2026, 9, 30, 12);
    final query = accountingQueryFor(
      DateRangeSelection(DateRange.custom, day: DateTime(2026, 3, 8)),
      now,
      timezone: 'America/New_York',
    );
    final response = projectAccountingSnapshot(_snapshot());
    expect(response.requestedStartUtc, isNot(query.startUtc));
    expect(
      shouldAcceptSnapshot(query: query, selected: query, incoming: response),
      isTrue,
    );
    final otherSelection = accountingQueryFor(
      const DateRangeSelection(DateRange.today),
      now,
      timezone: 'America/New_York',
    );
    expect(
      shouldAcceptSnapshot(
        query: query,
        selected: otherSelection,
        incoming: response,
      ),
      isFalse,
    );
  });

  test('uses Current only for ranges containing now and At for history', () {
    final now = DateTime(2026, 9, 30, 12);
    final today = accountingQueryFor(
      const DateRangeSelection(DateRange.today),
      now,
    );
    final yesterday = accountingQueryFor(
      const DateRangeSelection(DateRange.yesterday),
      now,
      timezone: 'Asia/Hong_Kong',
    );
    final week = accountingQueryFor(
      const DateRangeSelection(DateRange.week),
      now,
    );
    final historicalCustom = accountingQueryFor(
      DateRangeSelection(DateRange.custom, day: DateTime(2026, 9, 28)),
      now,
    );
    expect(today.asOf, isA<AccountingAsOfRequest_Current>());
    expect(today.startUtc, endsWith(':00Z'));
    expect(week.asOf, isA<AccountingAsOfRequest_Current>());
    expect(yesterday.asOf, isA<AccountingAsOfRequest_At>());
    expect(yesterday.range, isA<AccountingRangeRequest_LocalDate>());
    expect(
      (yesterday.asOf as AccountingAsOfRequest_At).asOfUtc,
      now.toUtc().toIso8601String().replaceFirst('.000Z', 'Z'),
    );
    expect(historicalCustom.asOf, isA<AccountingAsOfRequest_At>());
    expect(
      (historicalCustom.asOf as AccountingAsOfRequest_At).asOfUtc,
      historicalCustom.endUtc,
    );
  });
}
