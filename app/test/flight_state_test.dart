import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_state.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';

const testSession = PrivateFlightSession(
  id: 1,
  startedAt: '2026-08-16T08:00:00Z',
  endedAt: null,
  durationSecs: null,
  status: 'active',
  satisfaction: null,
  note: '',
  date: '2026-08-16',
);

void main() {
  group('FlightTodayStats', () {
    test('zero constant has count 0 and totalSeconds 0', () {
      expect(FlightTodayStats.zero.count, 0);
      expect(FlightTodayStats.zero.totalSeconds, 0);
    });

    test('constructor creates instance with provided values', () {
      const stats = FlightTodayStats(count: 5, totalSeconds: 3600);
      expect(stats.count, 5);
      expect(stats.totalSeconds, 3600);
    });
  });

  group('FlightControllerState', () {
    test('initial state has no active session and no error', () {
      const state = FlightControllerState(activeSession: null);
      expect(state.activeSession, isNull);
      expect(state.isLoading, false);
      expect(state.error, isNull);
    });

    test('copyWith updates isLoading', () {
      const state = FlightControllerState(activeSession: null);
      final updated = state.copyWith(isLoading: true);
      expect(updated.isLoading, true);
      expect(updated.activeSession, isNull);
    });

    test('copyWith sets error', () {
      const state = FlightControllerState(activeSession: null);
      final updated = state.copyWith(error: 'Test error');
      expect(updated.error, 'Test error');
    });

    test('copyWith clearError removes error', () {
      const state = FlightControllerState(activeSession: null, error: 'Error');
      final updated = state.copyWith(clearError: true);
      expect(updated.error, isNull);
    });

    test('copyWith clearSession removes activeSession', () {
      const state = FlightControllerState(activeSession: testSession);
      final updated = state.copyWith(clearSession: true);
      expect(updated.activeSession, isNull);
    });

    test('copyWith preserves values when not specified', () {
      const state = FlightControllerState(
        activeSession: testSession,
        isLoading: true,
        error: 'error',
      );
      final updated = state.copyWith();
      expect(updated.activeSession, testSession);
      expect(updated.isLoading, true);
      expect(updated.error, 'error');
    });
  });
}
