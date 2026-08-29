import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/nowline/application/today_nowline_builder.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

void main() {
  test('restores bounded persistent scrollback from recap sessions', () {
    final sessions = [
      for (var index = 0; index < 14; index++)
        DaySessionDto(
          appName: index == 13 ? 'TimeTrace' : 'App $index',
          isIdle: false,
          durationSecs: 60 + index,
          startedAt: DateTime(2026, 8, 29, 9, index).toUtc().toIso8601String(),
        ),
    ];

    final timeline = const TodayNowlineBuilder().build(
      sessions: sessions,
      preferences: const NowlinePreferences(showWindowTitles: true),
      now: DateTime(2026, 8, 29, 12),
    );

    expect(timeline.lines, hasLength(12));
    expect(timeline.lines.first.text, '使用了 App 1');
    expect(timeline.lines.last.text, '使用了 App 12');
    expect(timeline.lines.every((line) => line.detail != null), isTrue);
  });

  test('ignores invalid and zero-length persisted sessions', () {
    final timeline = const TodayNowlineBuilder().build(
      sessions: [
        DaySessionDto(
          appName: 'Browser',
          isIdle: false,
          durationSecs: 0,
          startedAt: 'invalid',
        ),
      ],
      preferences: const NowlinePreferences(),
      now: DateTime(2026, 8, 29, 12),
    );

    expect(timeline.lines, isEmpty);
  });
}
