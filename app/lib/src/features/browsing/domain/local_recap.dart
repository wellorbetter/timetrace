import '../../../core/format/app_identity.dart';
import '../../dashboard/domain/dashboard_state.dart';

String localRecap(DashboardState state) {
  final start = DateTime.parse(state.requestedStartUtc).toLocal();
  final end = DateTime.parse(
    state.requestedEndUtc,
  ).toLocal().subtract(const Duration(microseconds: 1));
  String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final range = date(start) == date(end)
      ? date(start)
      : '${date(start)} 至 ${date(end)}';
  final apps = state.apps.where((app) => app.activeSeconds > 0).toList()
    ..sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
  final lines = <String>[
    '**$range**',
    '**${state.totalActiveLabel}** 活动 · ${apps.length} 个应用',
    if (apps.isNotEmpty)
      ...apps
          .take(3)
          .map((app) => '- ${appDisplayLabel(app.appName)}：${app.activeLabel}'),
    if (apps.isEmpty) '没有可归纳的前台应用活动。',
    if (state.totalIdleSeconds > 0)
      '另有 ${state.totalIdleSeconds ~/ 60} 分钟活动间歇。',
    if (state.unknownSeconds + state.systemGapSeconds > 0) '部分时段记录不完整。',
  ];
  return lines.join('\n\n');
}

final _diaryCache = Expando<String>('local-programmatic-diary');

/// Local-only prose from canonical hourly totals. Not an AI request payload.
/// Hour buckets describe aggregate activity, not inferred tasks or sessions.
String programmaticDiary(DashboardState state) {
  final cached = _diaryCache[state];
  if (cached != null) return cached;
  final apps = state.apps.where((app) => app.activeSeconds > 0).toList()
    ..sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
  final lines = <String>[
    localRecap(state).split('\n\n').first,
    apps.isEmpty
        ? '这段时间还没有留下可整理的应用使用记录。'
        : '从留下的记录看，这段时间我在电脑上活动了 ${_diaryDuration(state.totalActiveSeconds)}。${apps.length == 1 ? '主要用的是' : '用得最多的是'} ${_diaryLabel(appDisplayLabel(apps.first.appName))}${apps.length > 1 ? '，也用到了 ${apps.skip(1).take(2).map((app) => _diaryLabel(appDisplayLabel(app.appName))).join('和')}' : ''}。',
  ];
  final hours = state.hours.toList()
    ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  var written = 0;
  String? lastDate;
  final multipleDays = hours.map((hour) => hour.localDate).toSet().length > 1;
  for (final hour in hours) {
    if (hour.totals.accountedSeconds.toInt() <= 0) continue;
    final start = DateTime.parse(
      hour.startUtc,
    ).toUtc().add(Duration(seconds: hour.utcOffsetSeconds));
    final end = DateTime.parse(
      hour.endUtc,
    ).toUtc().add(Duration(seconds: hour.utcOffsetSeconds));
    String clock(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final hourApps =
        hour.apps
            .where(
              (app) =>
                  hour.totals.activeSeconds.toInt() > 0 &&
                  app.seconds.toInt() > 0,
            )
            .toList()
          ..sort((a, b) => b.seconds.compareTo(a.seconds));
    final parts = <String>[
      if (hourApps.isNotEmpty)
        '我主要在 ${_diaryLabel(appDisplayLabel(hourApps.first.id))} 上活动，用了 ${_diaryDuration(hourApps.first.seconds.toInt())}${hourApps.length > 1 ? '，这段时间也用了 ${hourApps.skip(1).take(2).map((app) => '${_diaryLabel(appDisplayLabel(app.id))}（${_diaryDuration(app.seconds.toInt())}）').join('和')}' : ''}',
      if (hourApps.isEmpty && hour.totals.activeSeconds.toInt() > 0)
        '这段时间有 ${_diaryDuration(hour.totals.activeSeconds.toInt())} 的电脑活动，但没留下应用名称',
      if (hour.totals.idleSeconds.toInt() > 0)
        '中间还有 ${_diaryDuration(hour.totals.idleSeconds.toInt())} 的活动间歇',
      if (hour.totals.pausedSeconds.toInt() > 0) '有一段时间暂停了记录',
      if (hour.totals.privacyExcludedSeconds.toInt() > 0) '部分时间做了隐私排除，没有保留应用细节',
    ];
    if (parts.isEmpty) continue;
    if (multipleDays && lastDate != hour.localDate) {
      lines.add('### ${hour.localDate}');
    }
    lines.add(
      '${written == 0 || lastDate != hour.localDate ? '' : '再往后，'}${_dayPart(start.hour)} ${clock(start)} 到 ${end.day != start.day ? '${end.month}月${end.day}日 ' : ''}${clock(end)}，${parts.join('；')}。',
    );
    lastDate = hour.localDate;
    written++;
  }
  if (written == 0 && apps.isNotEmpty) {
    lines.add('暂时没有按小时的明细，先记下整体使用情况，不补写具体先后顺序。');
  }
  final windows =
      state.windows.where((window) => window.seconds.toInt() > 0).toList()
        ..sort((a, b) => b.seconds.compareTo(a.seconds));
  if (windows.isNotEmpty) {
    lines.add(
      '记录里停留较久的窗口还有 ${windows.take(3).map((window) => '「${_diaryLabel(window.id)}」').join('、')}。这里只记下整个范围里出现的窗口，具体打开顺序没记下来。',
    );
  }
  if (state.unknownSeconds + state.systemGapSeconds > 0) {
    lines.add('有些时段没记完整，就先按留下的记录写到这里。');
  }
  final result = lines.join('\n\n');
  _diaryCache[state] = result;
  return result;
}

String _dayPart(int hour) => switch (hour) {
  < 6 => '凌晨',
  < 12 => '上午',
  < 14 => '中午',
  < 18 => '下午',
  _ => '晚上',
};

String _diaryDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  if (seconds < 3600) {
    return '${seconds ~/ 60} 分钟${seconds % 60 == 0 ? '' : '${seconds % 60} 秒'}';
  }
  return '${seconds ~/ 3600} 小时${seconds % 3600 ~/ 60 == 0 ? '' : '${seconds % 3600 ~/ 60} 分钟'}';
}

/// Structured, bounded AI facts: no window titles, pages, diary or source IDs.
String aiDiaryFacts(DashboardState state) {
  final hours =
      state.hours
          .where((hour) => hour.totals.activeSeconds.toInt() > 0)
          .toList()
        ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
  final visible = hours.length > 48 ? hours.sublist(hours.length - 48) : hours;
  return [
    localRecap(state),
    if (hours.length > 48) '按小时明细仅含最近 48 个有活动的小时，不覆盖整个范围。',
    for (final hour in visible)
      '${hour.localDate} ${hour.localHour}点（按小时汇总，不代表应用切换顺序）：${hour.apps.where((app) => app.seconds.toInt() > 0).take(3).map((app) => '${_diaryLabel(appDisplayLabel(app.id))} ${_diaryDuration(app.seconds.toInt())}').join('、')}；活动间歇 ${_diaryDuration(hour.totals.idleSeconds.toInt())}${hour.totals.systemGapSeconds.toInt() + hour.totals.unknownSeconds.toInt() > 0 ? '；部分时间缺少记录' : ''}',
  ].join('\n\n');
}

String _diaryLabel(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    .replaceAllMapped(RegExp(r'[*_`\[\]()<>#!|]'), (match) => '\\${match[0]}');
