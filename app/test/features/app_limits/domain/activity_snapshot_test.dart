import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';

void main() {
  final observedAt = DateTime.utc(2026, 8, 31, 12);

  test('active snapshot carries only stable application identity', () {
    final snapshot = ActivitySnapshot.active(
      revision: 7,
      observedAt: observedAt,
      application: const ActivityApplication(
        executablePath: r'c:\apps\editor.exe',
        displayName: 'Editor',
      ),
    );

    expect(snapshot.state, ActivitySnapshotState.active);
    expect(snapshot.isActive, isTrue);
    expect(snapshot.application!.executablePath, r'c:\apps\editor.exe');
    expect(snapshot.application!.displayName, 'Editor');
  });

  test('every ineligible lifecycle state omits application identity', () {
    final snapshots = [
      ActivitySnapshot.idle(revision: 1, observedAt: observedAt),
      ActivitySnapshot.excluded(revision: 2, observedAt: observedAt),
      ActivitySnapshot.paused(revision: 3, observedAt: observedAt),
      ActivitySnapshot.unavailable(revision: 4, observedAt: observedAt),
    ];

    expect(
      snapshots.map((snapshot) => snapshot.state),
      ActivitySnapshotState.values.where(
        (state) => state != ActivitySnapshotState.active,
      ),
    );
    for (final snapshot in snapshots) {
      expect(snapshot.isActive, isFalse);
      expect(snapshot.application, isNull);
    }
  });

  test('snapshots and identities have deterministic value equality', () {
    final left = ActivitySnapshot.active(
      revision: 9,
      observedAt: observedAt,
      application: const ActivityApplication(
        executablePath: r'c:\apps\same.exe',
        displayName: 'Same',
      ),
    );
    final right = ActivitySnapshot.active(
      revision: 9,
      observedAt: observedAt,
      application: const ActivityApplication(
        executablePath: r'c:\apps\same.exe',
        displayName: 'Same',
      ),
    );

    expect(left, right);
    expect(left.hashCode, right.hashCode);
  });
}
