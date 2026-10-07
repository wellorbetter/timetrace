import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';

void main() {
  test('opt-in DeepSeek connection uses synthetic content only', () async {
    final result = await requestDeepSeekRecap(
      key: Platform.environment['DEEPSEEK_API_KEY'] ?? '',
      model: 'deepseek-flash',
      summary: '这是连接测试，不含任何用户活动记录。请只回答：连接成功。',
    );
    expect(result.trim(), isNotEmpty);
  }, skip: Platform.environment['TIMETRACE_LIVE_AI_TEST'] != '1');
}
