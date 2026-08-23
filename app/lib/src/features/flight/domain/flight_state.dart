import 'private_flight_models.dart';

/// Today's flight statistics: session count and total duration.
class FlightTodayStats {
  const FlightTodayStats({required this.count, required this.totalSeconds});

  final int count;
  final int totalSeconds;

  static const zero = FlightTodayStats(count: 0, totalSeconds: 0);
}

/// Immutable snapshot of the flight controller state.
class FlightControllerState {
  const FlightControllerState({
    required this.activeSession,
    this.isLoading = false,
    this.error,
  });

  /// Non-null when a flight is currently in progress.
  final PrivateFlightSession? activeSession;

  final bool isLoading;
  final String? error;

  FlightControllerState copyWith({
    PrivateFlightSession? activeSession,
    bool? isLoading,
    String? error,
    bool clearError = false,
    bool clearSession = false,
  }) {
    return FlightControllerState(
      activeSession: clearSession
          ? null
          : (activeSession ?? this.activeSession),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
