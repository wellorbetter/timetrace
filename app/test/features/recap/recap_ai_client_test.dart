import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/application/local_recap_engine.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

void main() {
  test('AI enhancement returns observations and actionable recommendations', () async {
    final snapshot = RecapSnapshot(
      label: '今天',
      start: DateTime(2026, 8, 29),
      end: DateTime(2026, 8, 29),
      activeSeconds: 3 * 3600,
      idleSeconds: 3600,
      previousActiveSeconds: 2 * 3600,
      topApps: const [
        RecapAppFact(
          name: 'Terminal',
          activeSeconds: 2 * 3600,
          idleSeconds: 0,
        ),
      ],
      sessionCount: 48,
      contextSwitches: 36,
      longestActiveStreakSeconds: 42 * 60,
      peakHour: 14,
      peakHourActiveSeconds: 50 * 60,
      diaryEntries: const ['private diary text must stay local by default'],
    );
    const engine = LocalRecapEngine();
    final local = engine.generate(snapshot);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    late Map<String, dynamic> receivedBody;

    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      receivedBody = jsonDecode(raw) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'headline': '今天的使用集中在终端',
                'summary': '活跃时间较集中，同时应用切换偏多。',
                'insights': ['14:00–15:00 是最活跃的时段。'],
                'recommendations': ['可以把需要连续注意力的任务安排在 14:00 左右。'],
              }),
            },
          },
        ],
      }));
      await request.response.close();
    });

    final attempt = await const RecapAiClient().enhance(
      local: local,
      settings: RecapAiSettings(
        enabled: true,
        provider: 'ollama',
        endpoint: 'http://127.0.0.1:${server.port}/v1/chat/completions',
        model: 'test-model',
        includeDiaryEntries: false,
      ),
    );

    expect(attempt.error, isNull);
    expect(attempt.result.origin, RecapOrigin.ai);
    expect(attempt.result.insights, isNotEmpty);
    expect(attempt.result.recommendations, isNotEmpty);
    expect(attempt.result.recommendations.first, contains('14:00'));

    final encodedRequest = jsonEncode(receivedBody);
    expect(encodedRequest, contains('recommendations'));
    expect(encodedRequest, contains('insights'));
    expect(encodedRequest, isNot(contains('private diary text must stay local by default')));
  });

  test('AI failure falls back to a usable local recap', () async {
    final snapshot = RecapSnapshot(
      label: '今天',
      start: DateTime(2026, 8, 29),
      end: DateTime(2026, 8, 29),
      activeSeconds: 3600,
      idleSeconds: 0,
      previousActiveSeconds: 0,
      topApps: const [],
      sessionCount: 1,
      contextSwitches: 0,
      longestActiveStreakSeconds: 3600,
      peakHour: 10,
      peakHourActiveSeconds: 3600,
      diaryEntries: const [],
    );
    const engine = LocalRecapEngine();
    final local = engine.generate(snapshot);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });

    final attempt = await const RecapAiClient().enhance(
      local: local,
      settings: RecapAiSettings(
        enabled: true,
        provider: 'ollama',
        endpoint: 'http://127.0.0.1:${server.port}/v1/chat/completions',
        model: 'test-model',
      ),
    );

    expect(attempt.error, isNotNull);
    expect(attempt.result.origin, RecapOrigin.local);
    expect(attempt.result.recommendations, isNotEmpty);
  });
}
