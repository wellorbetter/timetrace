import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_format.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';

void main() {
  group('elapsedSeconds', () {
    test('returns 0 for invalid startedAt', () {
      final session = PrivateFlightSession(
        id: 1,
        startedAt: 'invalid-date',
        endedAt: null,
        durationSecs: null,
        status: 'active',
        satisfaction: null,
        note: '',
        date: '2026-08-10',
      );
      expect(elapsedSeconds(session), 0);
    });

    test('calculates elapsed time for completed session', () {
      final session = PrivateFlightSession(
        id: 1,
        startedAt: '2026-08-10T10:00:00Z',
        endedAt: '2026-08-10T10:30:00Z',
        durationSecs: 1800,
        status: 'completed',
        satisfaction: null,
        note: '',
        date: '2026-08-10',
      );
      // 30 minutes = 1800 seconds
      expect(elapsedSeconds(session), 1800);
    });

    test('calculates elapsed time for active session using current time', () {
      final now = DateTime.now();
      final started = now.subtract(const Duration(minutes: 5));
      final session = PrivateFlightSession(
        id: 1,
        startedAt: started.toUtc().toIso8601String(),
        endedAt: null,
        durationSecs: null,
        status: 'active',
        satisfaction: null,
        note: '',
        date: '2026-08-10',
      );
      final elapsed = elapsedSeconds(session);
      // Should be approximately 5 minutes (300 seconds), allow 2 second tolerance
      expect(elapsed, greaterThanOrEqualTo(298));
      expect(elapsed, lessThanOrEqualTo(302));
    });
  });

  group('formatTime', () {
    test('formats valid ISO timestamp as HH:mm', () {
      // Use a fixed UTC time that converts predictably
      final result = formatTime('2026-08-10T14:30:00Z');
      // The exact output depends on local timezone, but should be HH:mm format
      expect(result, matches(RegExp(r'^\d{2}:\d{2}$')));
    });

    test('returns original string for invalid ISO', () {
      expect(formatTime('invalid'), 'invalid');
      expect(formatTime(''), '');
      expect(formatTime('not-a-date'), 'not-a-date');
    });

    test('handles edge case timestamps', () {
      // Midnight
      final midnight = formatTime('2026-08-10T00:00:00Z');
      expect(midnight, matches(RegExp(r'^\d{2}:\d{2}$')));

      // End of day
      final endOfDay = formatTime('2026-08-10T23:59:59Z');
      expect(endOfDay, matches(RegExp(r'^\d{2}:\d{2}$')));
    });
  });
}
