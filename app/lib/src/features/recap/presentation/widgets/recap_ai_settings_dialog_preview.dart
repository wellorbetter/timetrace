import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_ai_settings_dialog.dart';

@Preview(name: 'AI Recap 设置 · 未配置', size: Size(920, 820))
Widget recapAiSettingsDialogPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.dark(),
  home: Scaffold(
    body: Center(
      child: RecapAiSettingsDialog(
        initial: const RecapAiSettings(),
        environment: const {},
        onTestConnection: (_) async => null,
      ),
    ),
  ),
);

@Preview(name: 'AI Recap 设置 · 已连接', size: Size(920, 820))
Widget recapAiSettingsConnectedPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(),
  home: Scaffold(
    body: Center(
      child: RecapAiSettingsDialog(
        initial: const RecapAiSettings(),
        environment: const {'DEEPSEEK_API_KEY': 'redacted-preview-key'},
        onTestConnection: (_) async => null,
      ),
    ),
  ),
);
