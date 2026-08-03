import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A selectable font (system fonts available on Windows).
class AppFont {
  const AppFont({required this.name, required this.family, required this.preview});

  final String name; // display name
  final String family; // font family for Flutter
  final String preview; // sample text showing the style

  static const all = [
    AppFont(name: 'Segoe UI', family: 'Segoe UI', preview: 'TimeTrace 使用统计'),
    AppFont(name: '微软雅黑 UI', family: 'Microsoft YaHei UI', preview: 'TimeTrace 使用统计'),
    AppFont(name: '微软雅黑', family: 'Microsoft YaHei', preview: 'TimeTrace 使用统计'),
    AppFont(name: '等线', family: 'DengXian', preview: 'TimeTrace 使用统计'),
    AppFont(name: '宋体', family: 'SimSun', preview: 'TimeTrace 使用统计'),
    AppFont(name: '黑体', family: 'SimHei', preview: 'TimeTrace 使用统计'),
    AppFont(name: '楷体', family: 'KaiTi', preview: 'TimeTrace 使用统计'),
    AppFont(name: '仿宋', family: 'FangSong', preview: 'TimeTrace 使用统计'),
    AppFont(name: 'Consolas', family: 'Consolas', preview: 'TimeTrace 使用统计'),
  ];

  /// Default is Segoe UI (clean, modern).
  static AppFont get defaultFont => all.first;

  static AppFont? byName(String? name) =>
      all.where((f) => f.name == name).firstOrNull;
}

/// Selected font preference.
class FontNotifier extends Notifier<AppFont> {
  @override
  AppFont build() => AppFont.defaultFont;

  void select(AppFont font) => state = font;
}

final fontProvider = NotifierProvider<FontNotifier, AppFont>(FontNotifier.new);
