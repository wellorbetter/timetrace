import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/format/app_identity.dart';
import 'package:timetrace_app/src/features/browsing/domain/local_recap.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';

void main() {
  test('known aliases match paths without changing unknown names', () {
    expect(appIdentityKey('msedge.exe'), appIdentityKey('Microsoft Edge'));
    expect(
      appIdentityKey('LeagueClientUx.exe'),
      appIdentityKey('League of Legends (TM) Client'),
    );
    expect(appDisplayLabel('League of Legends'), '英雄联盟');
    expect(appDisplayLabel('Ani'), 'Ani');
    expect(appIdentityKey('wt.exe'), appIdentityKey('WindowsTerminal'));
    expect(appDisplayLabel('WindowsTerminal'), 'Windows Terminal');
    expect(appDisplayLabel('cmd.exe'), '命令提示符');
    expect(isTerminalApp('pwsh.exe'), isTrue);
  });
  test('local recap ranks active apps and discloses incomplete coverage', () {
    final state = DashboardState(
      apps: const [
        AppUsageItem(appName: 'msedge', activeSeconds: 30, idleSeconds: 0),
        AppUsageItem(
          appName: 'League of Legends',
          activeSeconds: 600,
          idleSeconds: 0,
        ),
        AppUsageItem(appName: 'idle-only', activeSeconds: 0, idleSeconds: 30),
      ],
      appAttribution: const [],
      windows: const [],
      pages: const [],
      hours: const [],
      totalActiveSeconds: 630,
      totalIdleSeconds: 60,
      pausedSeconds: 0,
      privacyExcludedSeconds: 0,
      systemGapSeconds: 120,
      unknownSeconds: 0,
      accountedSeconds: 810,
      integrity: SnapshotIntegrityDto.complete,
      requestedStartUtc: '2026-10-02T00:00:00Z',
      requestedEndUtc: '2026-10-03T00:00:00Z',
      effectiveStartUtc: '2026-10-02T00:00:00Z',
      effectiveEndUtc: '2026-10-03T00:00:00Z',
      observedThroughUtc: '2026-10-03T00:00:00Z',
    );
    final text = localRecap(state);
    expect(text, contains('2 个应用'));
    expect(text.indexOf('英雄联盟'), lessThan(text.indexOf('Microsoft Edge')));
    expect(text, contains('记录不完整'));
    expect(text, isNot(contains('idle-only')));
  });
}
