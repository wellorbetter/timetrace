import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/reminders/data/rust_activity_snapshot_source.dart';

void main() {
  test('active DTO maps only path and display name', () {
    final snapshot = activitySnapshotFromDto(
      _dto(state: 'active', appPath: r'c:\apps\editor.exe', appName: 'Editor'),
    );

    expect(snapshot.state, ActivitySnapshotState.active);
    expect(snapshot.revision, 8);
    expect(snapshot.observedAt, DateTime.parse('2026-08-31T12:30:00Z'));
    expect(snapshot.application!.executablePath, r'c:\apps\editor.exe');
    expect(snapshot.application!.displayName, 'Editor');
  });

  test('tracking pause and idle flags defensively override active state', () {
    final paused = activitySnapshotFromDto(
      _dto(state: 'active', trackingPaused: true),
    );
    final idle = activitySnapshotFromDto(_dto(state: 'active', isIdle: true));

    expect(paused.state, ActivitySnapshotState.paused);
    expect(paused.application, isNull);
    expect(idle.state, ActivitySnapshotState.idle);
    expect(idle.application, isNull);
  });

  test('path-shaped app name is replaced at the DTO domain boundary', () {
    final snapshot = activitySnapshotFromDto(
      _dto(
        state: 'active',
        appPath: r'c:\apps\editor.exe',
        appName: r'C:\Users\private\editor.exe',
      ),
    );

    expect(snapshot.state, ActivitySnapshotState.active);
    expect(snapshot.application!.executablePath, r'c:\apps\editor.exe');
    expect(snapshot.application!.displayName, '未命名应用');
    expect(
      snapshot.application!.displayName,
      isNot(contains(r'C:\Users\private')),
    );
  });

  test('known ineligible states map without application identity', () {
    final states = {
      'idle': ActivitySnapshotState.idle,
      'excluded': ActivitySnapshotState.excluded,
      'paused': ActivitySnapshotState.paused,
      'unavailable': ActivitySnapshotState.unavailable,
    };

    for (final entry in states.entries) {
      final snapshot = activitySnapshotFromDto(_dto(state: entry.key));
      expect(snapshot.state, entry.value);
      expect(snapshot.application, isNull);
    }
  });

  test('unknown or incomplete active DTO fails closed to unavailable', () {
    final samples = [
      _dto(state: 'future-state'),
      _dto(state: 'active', appPath: '', appName: 'Editor'),
      _dto(state: 'active', appPath: r'c:\app.exe', appName: '  '),
    ];

    for (final dto in samples) {
      final snapshot = activitySnapshotFromDto(dto);
      expect(snapshot.state, ActivitySnapshotState.unavailable);
      expect(snapshot.application, isNull);
    }
  });

  test('invalid observed timestamp uses a deterministic safe epoch', () {
    final snapshot = activitySnapshotFromDto(
      _dto(state: 'unavailable', observedAt: 'not-a-date'),
    );

    expect(
      snapshot.observedAt,
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  });

  test('Rust source performs exactly one generated API call', () {
    final api = _FakeApi(_dto(state: 'idle'));
    final snapshot = RustActivitySnapshotSource(api).readActivitySnapshot();

    expect(api.reads, 1);
    expect(snapshot.state, ActivitySnapshotState.idle);
  });
}

ActivitySnapshotDto _dto({
  required String state,
  bool trackingPaused = false,
  bool isIdle = false,
  String? appPath,
  String? appName,
  String observedAt = '2026-08-31T12:30:00Z',
}) {
  return ActivitySnapshotDto(
    revision: 8,
    state: state,
    trackingPaused: trackingPaused,
    isIdle: isIdle,
    appPath: appPath,
    appName: appName,
    observedAt: observedAt,
  );
}

final class _FakeApi implements TimeTraceApi {
  _FakeApi(this.snapshot);

  final ActivitySnapshotDto snapshot;
  int reads = 0;

  @override
  ActivitySnapshotDto getActivitySnapshot() {
    reads++;
    return snapshot;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
