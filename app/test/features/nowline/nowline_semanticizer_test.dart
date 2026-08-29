import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/nowline/application/nowline_semanticizer.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

void main() {
  const semanticizer = NowlineSemanticizer();
  final now = DateTime(2026, 8, 29, 12);

  test('creates factual local lines and caps visible history', () {
    final snapshot = LiveActivitySnapshot(
      version: 1,
      revision: 4,
      paused: false,
      history: [
        _episode(1, 'Terminal', 20, endedMinute: 30),
        _episode(2, 'Figma', 30, endedMinute: 40),
        _episode(3, 'Chrome', 40, endedMinute: 50),
      ],
      current: _episode(4, 'Visual Studio Code', 50),
    );

    final timeline = semanticizer.build(
      snapshot: snapshot,
      preferences: const NowlinePreferences(lineCount: 3),
      now: now,
    );

    expect(timeline.lines, hasLength(3));
    expect(timeline.lines.first.id, 2);
    expect(timeline.lines[1].text, '在 Chrome 中浏览');
    expect(timeline.current?.text, '正在使用 Visual Studio Code');
    expect(timeline.current?.detail, '10m');
  });

  test('does not reveal titles until explicitly enabled', () {
    final snapshot = LiveActivitySnapshot(
      version: 1,
      revision: 1,
      paused: false,
      history: const [],
      current: _episode(1, 'Chrome', 50, title: 'Private project - Chrome'),
    );

    final hidden = semanticizer.build(
      snapshot: snapshot,
      preferences: const NowlinePreferences(),
      now: now,
    );
    final visible = semanticizer.build(
      snapshot: snapshot,
      preferences: const NowlinePreferences(showWindowTitles: true),
      now: now,
    );

    expect(hidden.current?.detail, '10m');
    expect(visible.current?.detail, 'Private project · 10m');
  });

  test('still redacts sensitive titles after title display is enabled', () {
    final snapshot = LiveActivitySnapshot(
      version: 1,
      revision: 1,
      paused: false,
      history: const [],
      current: _episode(1, '1Password', 50, title: 'Personal vault password'),
    );

    final timeline = semanticizer.build(
      snapshot: snapshot,
      preferences: const NowlinePreferences(showWindowTitles: true),
      now: now,
    );

    expect(timeline.current?.detail, '敏感窗口标题已隐藏 · 10m');
  });

  test('renders idle as presence rather than productivity judgement', () {
    final snapshot = LiveActivitySnapshot(
      version: 1,
      revision: 2,
      paused: false,
      history: const [],
      current: LiveActivityEpisode(
        sequence: 2,
        appName: '__IDLE__',
        startedAt: now.subtract(const Duration(minutes: 2)),
        isIdle: true,
      ),
    );

    final timeline = semanticizer.build(
      snapshot: snapshot,
      preferences: const NowlinePreferences(),
      now: now,
    );

    expect(timeline.current?.text, '暂时离开屏幕');
    expect(timeline.current?.detail, '2m');
  });
}

LiveActivityEpisode _episode(
  int sequence,
  String appName,
  int startedMinute, {
  int? endedMinute,
  String? title,
}) => LiveActivityEpisode(
  sequence: sequence,
  appName: appName,
  windowTitle: title,
  startedAt: DateTime(2026, 8, 29, 11, startedMinute),
  endedAt: endedMinute == null ? null : DateTime(2026, 8, 29, 11, endedMinute),
  isIdle: false,
);
