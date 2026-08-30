/// The canonical foreground/activity lifecycle exposed to reminder features.
enum ActivitySnapshotState { active, idle, excluded, paused, unavailable }

/// A privacy-minimal application identity.
///
/// [executablePath] is already normalized by the Rust boundary. Window titles
/// are intentionally not part of this contract.
final class ActivityApplication {
  const ActivityApplication({
    required this.executablePath,
    required this.displayName,
  });

  final String executablePath;
  final String displayName;

  @override
  bool operator ==(Object other) {
    return other is ActivityApplication &&
        other.executablePath == executablePath &&
        other.displayName == displayName;
  }

  @override
  int get hashCode => Object.hash(executablePath, displayName);
}

/// An immutable point-in-time projection of TimeTrace's activity lifecycle.
final class ActivitySnapshot {
  factory ActivitySnapshot.active({
    required int revision,
    required DateTime observedAt,
    required ActivityApplication application,
  }) {
    return ActivitySnapshot._active(
      revision: revision,
      observedAt: observedAt,
      application: application,
    );
  }

  const ActivitySnapshot._active({
    required this.revision,
    required this.observedAt,
    required this.application,
  }) : state = ActivitySnapshotState.active,
       assert(application != null);

  const ActivitySnapshot.idle({
    required this.revision,
    required this.observedAt,
  }) : state = ActivitySnapshotState.idle,
       application = null;

  const ActivitySnapshot.excluded({
    required this.revision,
    required this.observedAt,
  }) : state = ActivitySnapshotState.excluded,
       application = null;

  const ActivitySnapshot.paused({
    required this.revision,
    required this.observedAt,
  }) : state = ActivitySnapshotState.paused,
       application = null;

  const ActivitySnapshot.unavailable({
    required this.revision,
    required this.observedAt,
  }) : state = ActivitySnapshotState.unavailable,
       application = null;

  final int revision;
  final ActivitySnapshotState state;
  final ActivityApplication? application;
  final DateTime observedAt;

  bool get isActive =>
      state == ActivitySnapshotState.active && application != null;

  @override
  bool operator ==(Object other) {
    return other is ActivitySnapshot &&
        other.revision == revision &&
        other.state == state &&
        other.application == application &&
        other.observedAt == observedAt;
  }

  @override
  int get hashCode => Object.hash(revision, state, application, observedAt);
}
