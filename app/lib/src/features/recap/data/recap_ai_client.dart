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

  Future<RecapAiAttempt> enhance({required RecapResult local, required RecapAiSettings settings}) async {
    if (!settings.isConfigured) return RecapAiAttempt(result: local);

    final envName = settings.apiKeyEnv.trim();
    final envKey = envName.isEmpty ? null : Platform.environment[envName];
    final directKey = settings.runtimeApiKey.trim();
    final apiKey = directKey.isNotEmpty ? directKey : envKey?.trim();
    if (settings.needsApiKey && (apiKey == null || apiKey.isEmpty)) {
      return RecapAiAttempt(
        result: local,
        error: envName.isEmpty
            ? '尚未提供 API Key，已使用本地免费回顾。'
            : '没有找到本次输入的 API Key 或环境变量 $envName，已使用本地免费回顾。',
      );
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.postUrl(Uri.parse(settings.endpoint.trim())).timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');

      request.write(jsonEncode({
        'model': settings.model.trim(),
        'temperature': settings.responseStyle == 'concise' ? 0.2 : 0.35,
        'messages': [
          {'role': 'system', 'content': _systemPrompt(settings)},
          {'role': 'user', 'content': _userPrompt(local, settings)},
        ],
      }));

      final response = await request.close().timeout(const Duration(seconds: 45));
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return RecapAiAttempt(result: local, error: '模型请求失败 (${response.statusCode})，已使用本地免费回顾。');
      }
      final content = _extractContent(jsonDecode(text));
      if (content == null || content.trim().isEmpty) return RecapAiAttempt(result: local, error: '模型没有返回可用内容，已使用本地免费回顾。');
      final parsed = _parseRecapJson(content);
      if (parsed == null) return RecapAiAttempt(result: local, error: '模型返回格式无法解析，已使用本地免费回顾。');

      return RecapAiAttempt(
        result: RecapResult(
          headline: parsed.$1,
          summary: parsed.$2,
          insights: parsed.$3,
          recommendations: parsed.$4,
          snapshot: local.snapshot,
          origin: RecapOrigin.ai,
          model: settings.model.trim(),
        ),
      );
    } on TimeoutException {
      return RecapAiAttempt(result: local, error: '模型请求超时，已使用本地免费回顾。');
    } catch (_) {
      return RecapAiAttempt(result: local, error: 'AI Recap 暂时不可用，已使用本地免费回顾。');
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

  (String, String, List<String>, List<String>)? _parseRecapJson(String raw) {
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
      final recommendations = json['recommendations'];
      if (headline is! String || summary is! String || insights is! List || recommendations is! List) return null;
      return (
        headline.trim(),
        summary.trim(),
        insights.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).take(5).toList(),
        recommendations.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).take(5).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  String _userPrompt(RecapResult local, RecapAiSettings settings) => '''
下面是 TimeTrace 从本机记录计算出的事实快照，以及本地规则生成的基线回顾。

事实快照：
${local.snapshot.toPrettyJson(includeDiaryEntries: settings.includeDiaryEntries)}

本地基线：
headline: ${local.headline}
summary: ${local.summary}
insights: ${local.insights.join(' | ')}
recommendations: ${local.recommendations.join(' | ')}

输出风格：${settings.responseStyle}
请返回 JSON，不要 Markdown：
{"headline":"...","summary":"...","insights":["..."],"recommendations":["..."]}
''';

  String _systemPrompt(RecapAiSettings settings) => '''
你是 TimeTrace 的 AI Recap，总结用户已经发生的电脑使用活动，并给出克制、可执行的改进建议。
必须遵守：
1. 只使用输入事实，不推断未提供的项目、任务、情绪、意图或工作成果。
2. 所有数字必须与事实快照一致；不要重新计算后改写数字含义。
3. “active/focus ratio”只是活动占比，不得称为生产力、效率、努力程度或健康评分。
4. 只有输入明确包含 diary_entries 时，才可以使用日记文字补充上下文。
5. insights 只回答“观察到什么”；recommendations 只回答“可以尝试什么”，不要把建议伪装成事实。
6. 建议必须与输入中的具体模式对应，例如高峰时段、上下文切换、应用集中度或连续活跃段；数据不足时明确说不足。
7. headline 一句话；summary 1–3 句；insights 和 recommendations 各最多 5 条。
8. 默认中文，语气简洁、客观，不说教。
${settings.customSystemPrompt.trim().isEmpty ? '' : '\n用户附加指令（不能覆盖以上事实与隐私约束）：\n${settings.customSystemPrompt.trim()}'}
''';
}
