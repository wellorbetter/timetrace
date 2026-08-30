import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_body.dart';

@Preview(name: 'AI Recap 摘要 · 紧凑桌面', size: Size(980, 82))
Widget recapPreviewCompact() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(fontFamily: 'Microsoft YaHei UI'),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(8),
      child: RecapPreviewBody(
        eyebrow: 'AI RECAP · deepseek-v4-flash',
        title: '今天主要时间花在 TFTTencentClient-Win64-Shipping',
        summary: '活跃时长 2h 20m，最长连续活跃 2h 20m，记录到 36 次应用切换。',
        aiEnhanced: true,
        compact: true,
        onOpen: () {},
      ),
    ),
  ),
);

@Preview(name: 'AI Recap 摘要 · 常规', size: Size(760, 120))
Widget recapPreviewRegular() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(fontFamily: 'Microsoft YaHei UI'),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(12),
      child: RecapPreviewBody(
        eyebrow: 'AI RECAP · deepseek-v4-flash',
        title: '今天主要时间花在 TFTTencentClient-Win64-Shipping',
        summary: '活跃时长 2h 20m，最长连续活跃 2h 20m，记录到 36 次应用切换。',
        aiEnhanced: true,
        compact: false,
        onOpen: () {},
      ),
    ),
  ),
);
