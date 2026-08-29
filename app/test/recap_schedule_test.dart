import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_schedule.dart';

void main() {
  test('scheduled recap settings round-trip without losing user choices', () {
    const source = RecapScheduleSettings(
      cadence: RecapScheduleCadence.weekly,
      hour: 21,
      minute: 30,
      weekday: DateTime.sunday,
      notify: false,
      lastRunKey: '2026-W35',
    );

    final restored = RecapScheduleSettings.fromJson(source.toJson());

    expect(restored.cadence, RecapScheduleCadence.weekly);
    expect(restored.hour, 21);
    expect(restored.minute, 30);
    expect(restored.weekday, DateTime.sunday);
    expect(restored.notify, isFalse);
    expect(restored.lastRunKey, '2026-W35');
  });

  test('invalid persisted clock values are clamped safely', () {
    final restored = RecapScheduleSettings.fromJson({
      'cadence': 'daily',
      'hour': 99,
      'minute': -8,
      'weekday': 99,
    });

    expect(restored.cadence, RecapScheduleCadence.daily);
    expect(restored.hour, 23);
    expect(restored.minute, 0);
    expect(restored.weekday, DateTime.sunday);
  });
}
