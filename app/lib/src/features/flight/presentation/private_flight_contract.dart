import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_state.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';

/// Load state projected by the host into the private-flight renderer.
enum PrivateFlightLoadStatus { loading, data, error }

/// Immutable result of one host-owned private-flight query.
@immutable
final class PrivateFlightLoad<T> {
  const PrivateFlightLoad._({
    required this.status,
    required this.value,
    required this.errorCode,
  });

  /// Creates a pending query projection.
  const PrivateFlightLoad.loading()
    : this._(
        status: PrivateFlightLoadStatus.loading,
        value: null,
        errorCode: null,
      );

  /// Creates a successful query projection.
  const PrivateFlightLoad.data(T value)
    : this._(
        status: PrivateFlightLoadStatus.data,
        value: value,
        errorCode: null,
      );

  /// Creates a privacy-safe failed query projection.
  const PrivateFlightLoad.error(String errorCode)
    : this._(
        status: PrivateFlightLoadStatus.error,
        value: null,
        errorCode: errorCode,
      );

  /// Current query status.
  final PrivateFlightLoadStatus status;

  /// Host-projected value when [status] is [PrivateFlightLoadStatus.data].
  final T? value;

  /// Stable non-sensitive error code when loading failed.
  final String? errorCode;
}

/// Immutable data required to render the complete private-flight page.
@immutable
final class PrivateFlightViewModel {
  /// Creates a page snapshot without exposing host implementation objects.
  PrivateFlightViewModel({
    required this.controller,
    required this.today,
    required PrivateFlightLoad<List<PrivateFlightSession>> recent,
  }) : recent = _freezeRecent(recent);

  /// Active-session controller snapshot.
  final FlightControllerState controller;

  /// Today's completed-flight statistics.
  final PrivateFlightLoad<FlightTodayStats> today;

  /// Recent immutable completed-flight records.
  final PrivateFlightLoad<List<PrivateFlightSession>> recent;

  static PrivateFlightLoad<List<PrivateFlightSession>> _freezeRecent(
    PrivateFlightLoad<List<PrivateFlightSession>> source,
  ) {
    final value = source.value;
    if (value == null) return source;
    return PrivateFlightLoad.data(
      UnmodifiableListView<PrivateFlightSession>(
        List<PrivateFlightSession>.of(value, growable: false),
      ),
    );
  }
}

/// User-entered landing data passed to the host as one typed operation.
@immutable
final class FlightCompletionDraft {
  /// Creates an immutable landing draft.
  const FlightCompletionDraft({
    required this.note,
    required this.satisfaction,
    required this.skipMaterial,
    required this.materialTitle,
    required this.materialKind,
    required this.materialUrl,
    required this.materialTags,
  });

  /// Optional private note.
  final String note;

  /// Optional satisfaction score from one through five.
  final int? satisfaction;

  /// Whether material creation must be skipped.
  final bool skipMaterial;

  /// Optional linked material title.
  final String materialTitle;

  /// Linked material kind when a title is supplied.
  final String materialKind;

  /// Optional linked material source URL.
  final String materialUrl;

  /// Optional comma-separated material tags.
  final String materialTags;
}

/// Narrow host capability surface available to the private-flight view.
abstract interface class PrivateFlightActions {
  /// Starts a new private-flight session.
  Future<void> start();

  /// Permanently discards the active session.
  Future<void> discard();

  /// Completes the specified active session with user-entered data.
  Future<bool> complete(
    PrivateFlightSession session,
    FlightCompletionDraft draft,
  );

  /// Loads linked materials for a completed session.
  Future<List<PrivateFlightMaterialLink>> loadMaterials(
    PrivateFlightSession session,
  );

  /// Requests a host-owned refresh of today's statistics.
  void refreshToday();

  /// Requests a host-owned refresh of recent sessions.
  void refreshRecent();
}
