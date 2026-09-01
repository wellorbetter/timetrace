import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/reminders/domain/reminder_timing.dart';

void main() {
  test('only positive callback deltas up to the tolerance contribute', () {
    expect(reminderDeltaContributes(Duration.zero), isFalse);
    expect(reminderDeltaContributes(const Duration(milliseconds: -1)), isFalse);
    expect(reminderDeltaContributes(const Duration(seconds: 1)), isTrue);
    expect(reminderDeltaContributes(reminderCallbackGapTolerance), isTrue);
    expect(
      reminderDeltaContributes(const Duration(milliseconds: 2501)),
      isFalse,
    );
  });

  test('an explicit gap never contributes regardless of its duration', () {
    expect(
      reminderDeltaContributes(const Duration(seconds: 1), isGap: true),
      isFalse,
    );
  });
}
