import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

class RecapAiAttempt {
  const RecapAiAttempt({required this.result, this.error});

  final RecapResult result;
  final String? error;
}

class RecapAiClient {
  const RecapAiClient();

  Future<RecapAiAttempt> enhance({
    required RecapResult local,
    required RecapAiSettings settings,
  }) async {
    if (!settings.isConfigured) return RecapAiAttempt(result: local);

    final keyName = settings.apiKeyEnv.trim();
    final apiKey = keyName.isEmpty ? null : Platform.environment[keyName];
    if (keyName.isNotEmpty && (apiKey == null || apiKey.trim().isEmpty)) {
      return RecapAiAttempt(
        result: local,
        error: '未找到环境变量 $keyName，已使用本地回顾。',
      );
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.parse(settings.endpoint.trim());
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }

      final body = {
        'model': settings.model.trim(),
        'temperature': 0.35,
        'messages': [
          {
            'role': 'system',
            'content': _systemPrompt,
          },
          {
            'role': 'user',
            'content': _userPrompt(local),
          },
        ],
      };
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 45));
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return RecapAiAttempt(
          result: local,
          error: '模型请求失败 (${response.statusCode})，已使用本地回顾。',
        );
      }

      final decoded = jsonDecode(text);
      final content = _extractContent(decoded);
      if (content == null || content.trim().isEmpty) {
        return RecapAiAttempt(result: local, error: '模型没有返回可用内容，已使用本地回顾。');
      }
      final parsed = _parseRecapJson(content);
      if (parsed == null) {
        return RecapAiAttempt(result: local, error: '模型返回格式无法解析，已使用本地回顾。');
      }

      return RecapAiAttempt(
        result: RecapResult(
          headline: parsed.$1,
          summary: parsed.$2,
          insights: parsed.$3,
          snapshot: local.snapshot,
          origin: RecapOrigin.ai,
          model: settings.model.trim(),
        ),
      );
    } on TimeoutException {
      return RecapAiAttempt(result: local, error: '模型请求超时，已使用本地回顾。');
    } catch (_) {
      return RecapAiAttempt(result: local, error: 'AI Recap 暂时不可用，已使用本地回顾。');
    } finally {
      client.close(force: true);
    }
  }

  String? _extractContent(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final message = first['message'];
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    return content is String ? content : null;
  }

  (String, String, List<String>)? _parseRecapJson(String raw) {
    var value = raw.trim();
    if (value.startsWith('```')) {
      value = value.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      value = value.replaceFirst(RegExp(r'\s*```$'), '');
    }
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, dynamic>) return null;
      final headline = json['headline'];
      final summary = json['summary'];
      final insights = json['insights'];
      if (headline is! String || summary is! String || insights is! List) {
        return null;
      }
      return (
        headline.trim(),
        summary.trim(),
        insights.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).take(5).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  String _userPrompt(RecapResult local) => '''
下面是 TimeTrace 从本机记录计算出的事实快照，以及本地规则生成的基线回顾。

事实快照：
${local.snapshot.toPrettyJson()}

本地基线：
headline: ${local.headline}
summary: ${local.summary}
insights: ${local.insights.join(' | ')}

请返回 JSON，不要 Markdown：
{"headline":"...","summary":"...","insights":["...","..."]}
''';
}

const _systemPrompt = '''
你是 TimeTrace 的 AI Recap，总结用户已经发生的电脑使用活动。
必须遵守：
1. 只使用输入事实，不推断未提供的项目、任务、情绪、意图或工作成果。
2. 所有数字必须与事实快照一致；不要重新计算后改写数字含义。
3. “active/focus ratio”只是活动占比，不得称为生产力、效率、努力程度或健康评分。
4. 可以基于 diary_entries 提供的文字补充上下文，但不得扩写其中没有的信息。
5. 语气简洁、自然、客观，默认中文。
6. headline 一句话；summary 1–3 句；insights 最多 5 条，每条尽量给出具体事实。
7. 如果数据不足，明确说数据不足，不要补全故事。
''';
