import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';

/// Reads the constant-time in-memory activity projection from Rust.
final class RustActivitySnapshotSource implements ActivitySnapshotSource {
  const RustActivitySnapshotSource(this._api);

  final TimeTraceApi _api;

  @override
  ActivitySnapshot readActivitySnapshot() {
    return activitySnapshotFromDto(_api.getActivitySnapshot());
  }
}

/// Defensively maps a generated bridge DTO to the privacy-minimal domain type.
ActivitySnapshot activitySnapshotFromDto(ActivitySnapshotDto dto) {
  final revision = dto.revision.toInt();
  final observedAt =
      DateTime.tryParse(dto.observedAt) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final state = dto.state.trim().toLowerCase();

  if (dto.trackingPaused || state == 'paused') {
    return ActivitySnapshot.paused(revision: revision, observedAt: observedAt);
  }
  if (dto.isIdle || state == 'idle') {
    return ActivitySnapshot.idle(revision: revision, observedAt: observedAt);
  }

  switch (state) {
    case 'active':
      final path = dto.appPath?.trim() ?? '';
      final name = dto.appName?.trim() ?? '';
      if (path.isEmpty || name.isEmpty) {
        return ActivitySnapshot.unavailable(
          revision: revision,
          observedAt: observedAt,
        );
      }
      return ActivitySnapshot.active(
        revision: revision,
        observedAt: observedAt,
        application: ActivityApplication(
          executablePath: path,
          displayName: safeDisplayLabel(name),
        ),
      );
    case 'excluded':
      return ActivitySnapshot.excluded(
        revision: revision,
        observedAt: observedAt,
      );
    case 'unavailable':
    default:
      return ActivitySnapshot.unavailable(
        revision: revision,
        observedAt: observedAt,
      );
  }
}
