import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

void main() {
  test(
    'uses content-only diary contract and bounded custom preferences',
    () async {
      final call = await _callAi(
        responseContent: jsonEncode({
          'content': '今天主要在 Android Studio 中活动，期间也查看了一些资料。',
        }),
        settings: _settings.copyWith(
          customPrompt: '写得像轻松的睡前日记，不要编造成果。',
          includeHabitReflection: true,
          includeImprovementSuggestion: false,
        ),
      );

      expect(call.attempt.isSuccess, isTrue);
      expect(call.attempt.draft?.content, contains('Android Studio'));
      expect(call.attempt.draft?.model, 'test-model');

      final systemPrompt = _messageContent(call.requestBody, 'system');
      expect(systemPrompt, contains('不得根据应用名称编造'));
      expect(systemPrompt, contains('情绪或生产力'));
      expect(systemPrompt, contains('最多给出一条'));
      expect(systemPrompt, contains('{"content":"..."}'));

      final userPrompt = _messageContent(call.requestBody, 'user');
      expect(userPrompt, contains('写得像轻松的睡前日记'));
      expect(userPrompt, contains('包含习惯反思：true'));
      expect(userPrompt, contains('包含改进建议：false'));
      expect(userPrompt, contains('{"content":"完整日记正文"}'));
      expect(userPrompt, isNot(contains('{"headline"')));
    },
  );

  test('diary text is sent only with explicit privacy opt-in', () async {
    final private = await _callAi(
      responseContent: jsonEncode({'content': '今天的使用记录主要集中在开发工具上。'}),
      settings: _settings.copyWith(includeDiaryEntries: false),
    );
    final privatePrompt = _messageContent(private.requestBody, 'user');
    expect(privatePrompt, contains('diary_entry_count'));
    expect(privatePrompt, isNot(contains('existing_diary_entries')));
    expect(privatePrompt, isNot(contains('修复了私密界面布局')));

    final optedIn = await _callAi(
      responseContent: jsonEncode({'content': '今天继续整理了界面，并在开发工具中核对了实现。'}),
      settings: _settings.copyWith(includeDiaryEntries: true),
    );
    final optedInPrompt = _messageContent(optedIn.requestBody, 'user');
    expect(optedInPrompt, contains('existing_diary_entries'));
    expect(optedInPrompt, contains('修复了私密界面布局'));
  });

  test('rejects legacy recap and report-shaped responses', () async {
    final legacy = await _callAi(
      responseContent: jsonEncode({'headline': '今日回顾', 'summary': '这是旧合同。'}),
      settings: _settings,
    );
    expect(legacy.attempt.isSuccess, isFalse);
    expect(legacy.attempt.failure, AiDiaryFailureKind.invalidResponse);

    final report = await _callAi(
      responseContent: jsonEncode({'content': '生产力评分：90\n- 事实一\n- 事实二'}),
      settings: _settings,
    );
    expect(report.attempt.isSuccess, isFalse);
    expect(report.attempt.draft, isNull);
  });

  test('connection check sends no usage, diary, or custom prompt', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? requestBody;
    final handled = server.first.then((request) async {
      requestBody =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    try {
      final error = await const RecapAiClient().testConnection(
        _settings.copyWith(
          endpoint:
              'http://${server.address.address}:${server.port}/chat/completions',
          customPrompt: '这段自定义提示词不应被发送',
          includeDiaryEntries: true,
        ),
      );
      await handled;
      expect(error, isNull);
      final encoded = jsonEncode(requestBody);
      expect(encoded, isNot(contains('active_seconds')));
      expect(encoded, isNot(contains('diary')));
      expect(encoded, isNot(contains('这段自定义提示词')));
    } finally {
      await server.close(force: true);
    }
  });
}

Future<({AiDiaryAttempt attempt, Map<String, dynamic> requestBody})> _callAi({
  required String responseContent,
  required RecapAiSettings settings,
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
    final attempt = await const RecapAiClient().generateDiary(
      snapshot: _snapshot,
      settings: settings.copyWith(
        endpoint:
            'http://${server.address.address}:${server.port}/chat/completions',
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

const _settings = RecapAiSettings(
  enabled: true,
  endpoint: 'http://127.0.0.1',
  model: 'test-model',
  apiKeyEnv: '',
);

final _snapshot = RecapSnapshot(
  label: '所选日期',
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
