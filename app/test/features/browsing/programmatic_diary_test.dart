import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/browsing/domain/local_recap.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';

LocalHourBucketDto hour(int number, {bool privacy = false}) =>
    LocalHourBucketDto(
      stableId: '$number',
      localDate: '2026-10-03',
      localHour: number + 8,
      utcOffsetSeconds: 28800,
      fold: 0,
      startUtc: '2026-10-03T0$number:00:00Z',
      endUtc: '2026-10-03T0${number + 1}:00:00Z',
      totals: AccountingTotalsDto(
        activeSeconds: privacy ? 0 : 120,
        idleSeconds: privacy ? 0 : 30,
        pausedSeconds: 0,
        privacyExcludedSeconds: privacy ? 150 : 0,
        systemGapSeconds: 0,
        unknownSeconds: 0,
        accountedSeconds: 150,
      ),
      apps: [
        AttributionTotalDto(
          id: privacy ? 'PRIVATE' : 'WindowsTerminal',
          seconds: 120,
        ),
      ],
    );

DashboardState fixture() => DashboardState(
  apps: const [
    AppUsageItem(
      appName: 'WindowsTerminal',
      activeSeconds: 240,
      idleSeconds: 0,
    ),
  ],
  appAttribution: const [],
  windows: [
    AttributionTotalDto(
      id: '[local](https://example.test)\nwindow',
      parentId: 'WindowsTerminal',
      seconds: 120,
    ),
  ],
  pages: const [],
  hours: [hour(2), hour(1), hour(3, privacy: true)],
  totalActiveSeconds: 240,
  totalIdleSeconds: 60,
  pausedSeconds: 0,
  privacyExcludedSeconds: 150,
  systemGapSeconds: 0,
  unknownSeconds: 0,
  accountedSeconds: 450,
  integrity: SnapshotIntegrityDto.complete,
  requestedStartUtc: '2026-10-03T00:00:00Z',
  requestedEndUtc: '2026-10-04T00:00:00Z',
  effectiveStartUtc: '2026-10-03T00:00:00Z',
  effectiveEndUtc: '2026-10-03T04:00:00Z',
  observedThroughUtc: '2026-10-03T04:00:00Z',
);

void main() {
  test(
    'local diary is chronological, offset-aware and honest about aggregation',
    () {
      final state = fixture();
      final text = programmaticDiary(state);
      expect(text.indexOf('09:00'), lessThan(text.indexOf('10:00')));
      expect(text, contains('Windows Terminal'));
      expect(text, contains('活动间歇'));
      expect(text, contains('隐私排除'));
      expect(text, isNot(contains('PRIVATE')));
      expect(text, contains('整个范围里出现的窗口'));
      expect(text, contains('我主要在'));
      expect(text, isNot(contains('记录到')));
      expect(text, isNot(contains('[local](https://example.test)')));
      expect(text, isNot(contains('写代码')));
      expect(identical(text, programmaticDiary(state)), isTrue);
    },
  );
  test('rich window/hour details never enter coarse AI summary', () {
    final summary = localRecap(fixture());
    expect(summary, isNot(contains('https://example.test')));
    expect(summary, isNot(contains('09:00')));
    final facts = aiDiaryFacts(fixture());
    expect(facts, contains('9点'));
    expect(facts, isNot(contains('https://example.test')));
    expect(facts, isNot(contains('PRIVATE')));
  });
}
