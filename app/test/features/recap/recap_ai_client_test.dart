import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

void main() {
  test('accepts narrative-only JSON and sends diary when opted in', () async {
    final responseContent = jsonEncode({
      'headline': '整理了回顾页',
      'summary': '日记记录了界面整理，使用记录中主要出现了 Android Studio。',
    });
    final call = await _callAi(
      responseContent: responseContent,
      includeDiaryEntries: true,
    );

    expect(call.attempt.result.origin, RecapOrigin.ai);
    expect(call.attempt.result.headline, '整理了回顾页');
    expect(call.attempt.result.insights, isEmpty);

    final userPrompt = _messageContent(call.requestBody, 'user');
    expect(userPrompt, contains('修复了私密界面布局'));
    expect(userPrompt, contains('usage_history'));
    expect(userPrompt, contains('{"headline":"...","summary":"..."}'));
    expect(userPrompt, isNot(contains('active_seconds')));
    expect(userPrompt, isNot(contains('focus_ratio')));
    expect(userPrompt, isNot(contains('"insights"')));
  });

  test('excludes diary without consent and ignores legacy insights', () async {
    final responseContent = jsonEncode({
      'headline': '今天主要使用了 Android Studio',
      'summary': '只能根据应用使用记录整理，无法确定具体任务。',
      'insights': ['这个旧字段应被忽略'],
    });
    final call = await _callAi(
      responseContent: responseContent,
      includeDiaryEntries: false,
    );

    expect(call.attempt.result.origin, RecapOrigin.ai);
    expect(call.attempt.result.insights, isEmpty);
    final userPrompt = _messageContent(call.requestBody, 'user');
    expect(userPrompt, isNot(contains('修复了私密界面布局')));
    expect(userPrompt, isNot(contains('diary_entries')));
    expect(userPrompt, contains('diary_entry_count'));
  });
}

Future<({RecapAiAttempt attempt, Map<String, dynamic> requestBody})> _callAi({
  required String responseContent,
  required bool includeDiaryEntries,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  Map<String, dynamic>? requestBody;
  final handled = server.first.then((request) async {
    requestBody =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'choices': [
          {
            'message': {'content': responseContent},
          },
        ],
      }),
    );
    await request.response.close();
  });

  try {
    final attempt = await const RecapAiClient().enhance(
      local: _localResult,
      settings: RecapAiSettings(
        enabled: true,
        endpoint:
            'http://${server.address.address}:${server.port}/chat/completions',
        model: 'test-model',
        apiKeyEnv: '',
        includeDiaryEntries: includeDiaryEntries,
      ),
    );
    await handled;
    return (attempt: attempt, requestBody: requestBody!);
  } finally {
    await server.close(force: true);
  }
}

String _messageContent(Map<String, dynamic> body, String role) {
  final messages = body['messages']! as List<dynamic>;
  return (messages.cast<Map<String, dynamic>>().singleWhere(
            (message) => message['role'] == role,
          )['content']
          as String)
      .trim();
}

final _snapshot = RecapSnapshot(
  label: '今天',
  start: DateTime(2026, 8, 27),
  end: DateTime(2026, 8, 27),
  activeSeconds: 7200,
  idleSeconds: 600,
  previousActiveSeconds: 3600,
  topApps: const [
    RecapAppFact(name: 'Android Studio', activeSeconds: 5400, idleSeconds: 0),
  ],
  sessionCount: 2,
  contextSwitches: 1,
  longestActiveStreakSeconds: 3600,
  peakHour: 10,
  peakHourActiveSeconds: 3600,
  diaryEntries: const ['修复了私密界面布局'],
  activityFacts: [
    RecapActivityFact(
      date: DateTime(2026, 8, 27),
      startedAt: '2026-08-27T10:00:00',
      appName: 'Android Studio',
      durationSeconds: 1800,
    ),
  ],
);

final _localResult = RecapResult(
  headline: '今天记录了：修复了私密界面布局',
  summary: '日记中写到修复了私密界面布局。',
  insights: const [],
  snapshot: _snapshot,
  origin: RecapOrigin.local,
);
