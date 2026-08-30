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
          insights: const [],
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
      if (headline is! String || summary is! String) return null;
      final normalizedHeadline = headline.trim();
      final normalizedSummary = summary.trim();
      if (normalizedHeadline.isEmpty || normalizedSummary.isEmpty) return null;

      // Older compatible providers may still return an `insights` field.
      // Recap is now one narrative surface, so that optional field is ignored.
      return (normalizedHeadline, normalizedSummary, const <String>[]);
    } catch (_) {
      return null;
    }
  }

  String _userPrompt(RecapResult local, RecapAiSettings settings) =>
      '''
下面是 TimeTrace 为叙事回顾准备的本机上下文。
应用使用记录只能说明用户在什么时候使用了哪些应用，不能单独证明用户完成了哪项具体任务。

回顾上下文：
${const JsonEncoder.withIndent('  ').convert(_narrativeContext(local.snapshot, settings.includeDiaryEntries))}

请返回 JSON，不要 Markdown：
{"headline":"...","summary":"..."}
''';

  Map<String, Object?> _narrativeContext(
    RecapSnapshot snapshot,
    bool includeDiaryEntries,
  ) {
    const maxHistoryFacts = 24;
    final historyStart = snapshot.activityFacts.length > maxHistoryFacts
        ? snapshot.activityFacts.length - maxHistoryFacts
        : 0;
    final history = snapshot.activityFacts.skip(historyStart);

    return {
      'range': {
        'label': snapshot.label,
        'start': _date(snapshot.start),
        'end': _date(snapshot.end),
      },
      'observed_apps': snapshot.topApps
          .map((app) => app.name.trim())
          .where((name) => name.isNotEmpty)
          .take(5)
          .toList(growable: false),
      'usage_history': history.map((fact) => fact.toJson()).toList(),
      'usage_history_truncated':
          snapshot.activityFacts.length > maxHistoryFacts,
      'diary_entry_count': snapshot.diaryEntries.length,
      if (includeDiaryEntries) 'diary_entries': snapshot.diaryEntries,
    };
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

const _systemPrompt = '''
你是 TimeTrace 的 AI Recap。把用户已经发生的电脑使用和已发布日记整理成一段简洁的叙事回顾，回答“这段时间主要做了什么”。
必须遵守：
1. 只使用输入上下文，不推断未提供的项目、任务、情绪、意图或工作成果。
2. 输入包含 diary_entries 时，优先把日记里写的事和应用使用自然地结合起来；不包含时，不得推断日记内容。
3. usage_history 只可用于说明使用顺序或时间，应用名称不能被扩写成未记录的具体任务。
4. 没有日记时，应坦率说明只能知道使用了哪些应用，无法确定具体做了什么。
5. 不要输出指标块、排名、时间分配、百分比、评分、事实清单或“洞察”列表。
6. 语气简洁、自然、客观，默认中文。headline 一句话；summary 用 1–3 句连贯叙述。
7. 如果上下文不足，明确说不足，不要补全故事。
8. 只返回包含 headline 和 summary 的 JSON 对象，不要 Markdown 或其他字段。
''';
