import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';

void main() {
  test('parses a versioned live activity snapshot', () {
    final snapshot = LiveActivitySnapshot.fromJson({
      'version': 1,
      'revision': 8,
      'paused': false,
      'current': {
        'sequence': 8,
        'app_name': 'Code',
        'window_title': 'main.dart',
        'started_at': '2026-08-29T10:00:00Z',
        'ended_at': null,
        'is_idle': false,
      },
      'history': [
        {
          'sequence': 6,
          'app_name': 'Browser',
          'window_title': null,
          'started_at': '2026-08-29T09:55:00Z',
          'ended_at': '2026-08-29T10:00:00Z',
          'is_idle': false,
        },
      ],
    });

    expect(snapshot.revision, 8);
    expect(snapshot.current?.appName, 'Code');
    expect(snapshot.current?.startedAt.toUtc().hour, 10);
    expect(snapshot.history.single.endedAt?.toUtc().minute, 0);
  });

  test('rejects an unknown snapshot version', () {
    expect(
      () =>
          LiveActivitySnapshot.fromJson({'version': 2, 'history': <Object>[]}),
      throwsFormatException,
    );
  });
}
