import 'dart:async';
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

  /// Verifies only the configured endpoint and API key.
  ///
  /// The request contains no TimeTrace usage facts or diary text. A null
  /// result means the provider accepted the request; otherwise the returned
  /// message is safe to render directly in the settings dialog.
  Future<String?> testConnection(RecapAiSettings settings) async {
    if (!settings.isConfigured) return '请先选择模型并完成服务配置。';
    final keyName = settings.apiKeyEnv.trim();
    final apiKey = keyName.isEmpty ? null : Platform.environment[keyName];
    if (keyName.isNotEmpty && (apiKey == null || apiKey.trim().isEmpty)) {
      return '未检测到环境变量 $keyName，请配置后重启 TimeTrace。';
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .postUrl(Uri.parse(settings.endpoint.trim()))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.write(
        jsonEncode({
          'model': settings.model.trim(),
          'temperature': 0,
          'max_tokens': 8,
          'messages': const [
            {'role': 'user', 'content': 'Reply with OK.'},
          ],
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      await response.drain<void>();
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      return switch (response.statusCode) {
        401 || 403 => 'API Key 未通过验证，请检查后重试。',
        429 => '服务请求较多，请稍后再试。',
        _ => '服务返回 ${response.statusCode}，请检查 Endpoint 与模型名。',
      };
    } on TimeoutException {
      return '连接超时，请检查网络后重试。';
    } on FormatException {
      return 'Endpoint 格式不正确，请检查后重试。';
    } catch (_) {
      return '暂时无法连接模型服务，请检查网络与配置。';
    } finally {
      client.close(force: true);
    }
  }

  Future<RecapAiAttempt> enhance({
    required RecapResult local,
    required RecapAiSettings settings,
  }) async {
    if (!settings.isConfigured) return RecapAiAttempt(result: local);

    final keyName = settings.apiKeyEnv.trim();
    final apiKey = keyName.isEmpty ? null : Platform.environment[keyName];
    if (keyName.isNotEmpty && (apiKey == null || apiKey.trim().isEmpty)) {
      return RecapAiAttempt(result: local, error: '未找到环境变量 $keyName，已使用本地回顾。');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.parse(settings.endpoint.trim());
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }

      final body = {
        'model': settings.model.trim(),
        'temperature': 0.35,
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {'role': 'user', 'content': _userPrompt(local, settings)},
        ],
      };
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
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
      if (headline is! String || summary is! String) {
        return null;
      }
      return (
        headline.trim(),
        summary.trim(),
        insights is List
            ? insights
                  .whereType<String>()
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .take(3)
                  .toList()
            : const <String>[],
      );
    } catch (_) {
      return null;
    }
  }

  String _userPrompt(RecapResult local, RecapAiSettings settings) =>
      '''
下面是 TimeTrace 从本机记录整理出的使用快照，以及本地生成的基线总结。

本机使用快照：
${local.snapshot.toPrettyJson(includeDiaryEntries: settings.includeDiaryEntries)}

本地基线：
headline: ${local.headline}
summary: ${local.summary}
insights: ${local.insights.join(' | ')}

请返回 JSON，不要 Markdown：
{"headline":"...","summary":"..."}
''';
}

const _systemPrompt = '''
你是 TimeTrace 的 AI Recap，总结用户已经发生的电脑使用活动。
必须遵守：
1. 只使用输入记录，不推断未提供的项目、任务、情绪、意图或工作成果。
2. 所有数字必须与本机使用快照一致；不要重新计算后改写数字含义。
3. “active/focus ratio”只是活动占比，不得称为生产力、效率、努力程度或健康评分。
4. 只有输入明确包含 diary_entries 时，才可以使用日记文字补充上下文；否则不得推断日记内容。
5. 语气简洁、自然、客观，默认中文。
6. headline 一句话；summary 2–4 句，回答“这段时间主要做了什么”。先按应用与 usage_history 还原使用脉络；存在 diary_entries 时，把日记作为用户主动记录的上下文自然融入总结。
7. 不要逐项复述仪表盘指标，不要输出排行榜、事实依据或评分；不要把应用名称扩写成未记录的项目或任务。
8. 如果日记明确写了任务，可以引用日记中的任务；否则只能描述使用了哪些应用和时间脉络。
9. 如果数据不足，明确说数据不足，不要补全故事。
''';
