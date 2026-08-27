import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/application/local_recap_engine.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

void main() {
  const engine = LocalRecapEngine();

  test('does not invent activity when snapshot is empty', () {
    final snapshot = RecapSnapshot(
      label: '今天',
      start: DateTime(2026, 8, 27),
      end: DateTime(2026, 8, 27),
      activeSeconds: 0,
      idleSeconds: 0,
      previousActiveSeconds: 0,
      topApps: const [],
      sessionCount: 0,
      contextSwitches: 0,
      longestActiveStreakSeconds: 0,
      peakHour: null,
      peakHourActiveSeconds: 0,
      diaryEntries: const [],
    );

    final result = engine.generate(snapshot);
    expect(result.origin, RecapOrigin.local);
    expect(result.headline, contains('没有足够'));
    expect(result.summary, isNot(contains('项目')));
  });

  test('uses factual top app, comparison, and peak hour', () {
    final snapshot = RecapSnapshot(
      label: '今天',
      start: DateTime(2026, 8, 27),
      end: DateTime(2026, 8, 27),
      activeSeconds: 4 * 3600,
      idleSeconds: 3600,
      previousActiveSeconds: 2 * 3600,
      topApps: const [
        RecapAppFact(
          name: 'Android Studio',
          activeSeconds: 2 * 3600,
          idleSeconds: 0,
        ),
        RecapAppFact(
          name: 'Terminal',
          activeSeconds: 3600,
          idleSeconds: 0,
        ),
      ],
      sessionCount: 14,
      contextSwitches: 8,
      longestActiveStreakSeconds: 90 * 60,
      peakHour: 14,
      peakHourActiveSeconds: 45 * 60,
      diaryEntries: const ['修复了界面布局。'],
    );

    final result = engine.generate(snapshot);
    expect(result.headline, contains('Android Studio'));
    expect(result.summary, contains('100%'));
    expect(result.insights.join(' '), contains('14:00'));
    expect(result.insights.join(' '), contains('50%'));
    expect(result.insights.join(' '), isNot(contains('生产力评分 80')));
  });

  test('AI serialization can exclude diary text while preserving count', () {
    final snapshot = RecapSnapshot(
      label: '今天',
      start: DateTime(2026, 8, 27),
      end: DateTime(2026, 8, 27),
      activeSeconds: 3600,
      idleSeconds: 0,
      previousActiveSeconds: 0,
      topApps: const [],
      sessionCount: 1,
      contextSwitches: 0,
      longestActiveStreakSeconds: 3600,
      peakHour: 10,
      peakHourActiveSeconds: 3600,
      diaryEntries: const ['这段文字默认不应发送给外部模型'],
    );

    final localJson = snapshot.toJson();
    final aiJson = snapshot.toJson(includeDiaryEntries: false);

    expect(localJson['diary_entries'], isNotNull);
    expect(aiJson['diary_entries'], isNull);
    expect(aiJson['diary_entry_count'], 1);
    expect(aiJson.toString(), isNot(contains('这段文字默认不应发送给外部模型')));
  });
}
