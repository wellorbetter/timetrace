import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/nowline/application/nowline_semanticizer.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

/// Rebuilds a small persistent scrollback from the same local sessions used by
/// AI Recap. The hot overlay uses the in-memory port; this view survives an app
/// restart without introducing a second event store.
class TodayNowlineBuilder {
  const TodayNowlineBuilder({this.maxEpisodes = 12});

  final int maxEpisodes;

  NowlineTimeline build({
    required List<DaySessionDto> sessions,
    required NowlinePreferences preferences,
    required DateTime now,
  }) {
    final episodes = <LiveActivityEpisode>[];
    for (final session in sessions) {
      final durationSeconds = session.durationSecs
          .toInt()
          .clamp(0, 24 * 3600)
          .toInt();
      final startedAt = DateTime.tryParse(session.startedAt)?.toLocal();
      if (durationSeconds <= 0 ||
          startedAt == null ||
          _isTimetrace(session.appName)) {
        continue;
      }
      episodes.add(
        LiveActivityEpisode(
          sequence: startedAt.microsecondsSinceEpoch,
          appName: session.appName,
          startedAt: startedAt,
          endedAt: startedAt.add(Duration(seconds: durationSeconds)),
          isIdle: session.isIdle,
        ),
      );
    }
    final start = (episodes.length - maxEpisodes).clamp(0, episodes.length);
    final recent = episodes.sublist(start);
    return const NowlineSemanticizer().build(
      snapshot: LiveActivitySnapshot(
        version: 1,
        revision: recent.length,
        paused: false,
        history: recent,
      ),
      preferences: preferences.copyWith(
        lineCount: recent.isEmpty ? 2 : recent.length,
      ),
      now: now,
    );
  }

  bool _isTimetrace(String appName) =>
      appName.trim().toLowerCase() == 'timetrace';
}
