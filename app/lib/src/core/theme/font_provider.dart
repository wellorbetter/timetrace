import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

/// A selectable desktop font.
class AppFont {
  const AppFont({required this.name, required this.family, required this.preview});

  final String name;
  final String family;
  final String preview;

  static const windows = [
    AppFont(name: 'Segoe UI', family: 'Segoe UI', preview: 'TimeTrace 使用统计'),
    AppFont(name: '微软雅黑 UI', family: 'Microsoft YaHei UI', preview: 'TimeTrace 使用统计'),
    AppFont(name: '微软雅黑', family: 'Microsoft YaHei', preview: 'TimeTrace 使用统计'),
    AppFont(name: '等线', family: 'DengXian', preview: 'TimeTrace 使用统计'),
    AppFont(name: 'Consolas', family: 'Consolas', preview: 'TimeTrace 使用统计'),
  ];

  static const macos = [
    AppFont(name: '系统字体', family: '.AppleSystemUIFont', preview: 'TimeTrace 使用统计'),
    AppFont(name: '苹方', family: 'PingFang SC', preview: 'TimeTrace 使用统计'),
    AppFont(name: 'SF Pro Text', family: 'SF Pro Text', preview: 'TimeTrace Usage'),
    AppFont(name: 'Menlo', family: 'Menlo', preview: 'TimeTrace Usage'),
  ];

  static List<AppFont> get all => Platform.isMacOS ? macos : windows;

  static AppFont get defaultFont => all.first;

  static AppFont? byName(String? name) =>
      all.where((f) => f.name == name).firstOrNull;
}

class FontNotifier extends Notifier<AppFont> {
  @override
  AppFont build() {
    final value = UiPreferencesStore.read()['fontName'];
    return AppFont.byName(value as String?) ?? AppFont.defaultFont;
  }

  void select(AppFont font) {
    state = font;
    UiPreferencesStore.update({'fontName': font.name});
  }
}

final fontProvider = NotifierProvider<FontNotifier, AppFont>(FontNotifier.new);
