import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppLocale { zh, en }

class LocaleNotifier extends Notifier<AppLocale> {
  @override
  AppLocale build() => AppLocale.zh;

  void set(AppLocale locale) => state = locale;
}

final localeProvider = NotifierProvider<LocaleNotifier, AppLocale>(LocaleNotifier.new);

/// Lightweight string table (avoids ARB overhead for this app's scale).
class L10n {
  final AppLocale locale;
  const L10n(this.locale);

  String get settings => locale == AppLocale.zh ? '设置' : 'Settings';
  String get dashboard => locale == AppLocale.zh ? '仪表盘' : 'Dashboard';
  String get startup => locale == AppLocale.zh ? '自启动' : 'Startup';
  String get usageStats => locale == AppLocale.zh ? '使用统计' : 'Usage Stats';
  String get theme => locale == AppLocale.zh ? '主题' : 'Theme';
  String get lightMode => locale == AppLocale.zh ? '浅色' : 'Light';
  String get darkMode => locale == AppLocale.zh ? '深色' : 'Dark';
  String get language => locale == AppLocale.zh ? '语言' : 'Language';
  String get monitoring => locale == AppLocale.zh ? '监控' : 'Monitoring';
  String get pollInterval => locale == AppLocale.zh ? '轮询间隔' : 'Poll interval';
  String get idleThreshold => locale == AppLocale.zh ? '空闲阈值' : 'Idle threshold';
  String get seconds => locale == AppLocale.zh ? '秒' : 's';
  String get minutes => locale == AppLocale.zh ? '分钟' : 'min';
  String get data => locale == AppLocale.zh ? '数据' : 'Data';
  String get clearData => locale == AppLocale.zh ? '清除全部数据' : 'Clear all data';
  String get clearDataConfirm =>
      locale == AppLocale.zh ? '确定清除全部记录？此操作不可恢复。' : 'Clear all records? This cannot be undone.';
  String get cancel => locale == AppLocale.zh ? '取消' : 'Cancel';
  String get confirm => locale == AppLocale.zh ? '确认' : 'OK';
  String get save => locale == AppLocale.zh ? '保存' : 'Save';
  String get saved => locale == AppLocale.zh ? '已保存' : 'Saved';
  String get appliesOnRestart =>
      locale == AppLocale.zh ? '监控参数将在下次启动时生效' : 'Applies on next launch';
  String get about => locale == AppLocale.zh ? '关于' : 'About';
  String get aboutText => locale == AppLocale.zh
      ? 'TimeTrace — 本地应用使用追踪器'
      : 'TimeTrace — local app usage tracker';
  String get recordingSince => locale == AppLocale.zh ? '数据记录自' : 'Recording since';
  String get active => locale == AppLocale.zh ? '活跃' : 'Active';
  String get idle => locale == AppLocale.zh ? '挂机' : 'Idle';
  String get byApp => locale == AppLocale.zh ? '按应用' : 'By App';
  String get distribution => locale == AppLocale.zh ? '占比' : 'Distribution';
  String get appList => locale == AppLocale.zh ? '应用列表' : 'App list';
  String get noData => locale == AppLocale.zh ? '暂无数据，切换应用后回来查看' : 'No data yet. Switch apps and return.';
  String get pages => locale == AppLocale.zh ? '页面' : 'pages';
  String get noPageData => locale == AppLocale.zh ? '暂无页面数据' : 'No page data';
}
