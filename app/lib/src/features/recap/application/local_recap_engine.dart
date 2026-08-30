import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

class LocalRecapEngine {
  const LocalRecapEngine();

  RecapResult generate(RecapSnapshot snapshot) {
    if (snapshot.activeSeconds <= 0) {
      return RecapResult(
        headline: '${snapshot.label}还没有足够的活动记录',
        summary: 'TimeTrace 暂时没有检测到可用于回顾的活跃使用数据。继续使用电脑后，这里会自动形成回顾。',
        insights: const [
          '本地回顾只基于设备内已有记录，不会虚构没有发生的活动。',
        ],
        snapshot: snapshot,
        origin: RecapOrigin.local,
      );
    }

    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final headline = top == null
        ? '${snapshot.label}共记录 ${formatRecapDuration(snapshot.activeSeconds)} 活跃时间'
        : '${snapshot.label}主要时间花在 ${top.name}';

    final pieces = <String>[
      '活跃 ${formatRecapDuration(snapshot.activeSeconds)}',
      if (snapshot.longestActiveStreakSeconds > 0)
        '最长连续活跃 ${formatRecapDuration(snapshot.longestActiveStreakSeconds)}',
      if (snapshot.contextSwitches > 0) '记录到 ${snapshot.contextSwitches} 次应用切换',
    ];
    final summary = '${pieces.join('，')}。${_comparisonSentence(snapshot)}';

    final insights = <String>[];
    if (top != null) {
      insights.add(
        '${top.name} 占活跃时间的 ${(snapshot.topAppShare * 100).round()}%，共 ${formatRecapDuration(top.activeSeconds)}。',
      );
    }
    if (snapshot.peakHour != null && snapshot.peakHourActiveSeconds > 0) {
      final hour = snapshot.peakHour!.toString().padLeft(2, '0');
      insights.add(
        '$hour:00–${(snapshot.peakHour! + 1).toString().padLeft(2, '0')}:00 是最活跃的小时，累计 ${formatRecapDuration(snapshot.peakHourActiveSeconds)}。',
      );
    }
    if (snapshot.totalObservedSeconds > 0) {
      insights.add(
        '记录区间内活跃占比约 ${(snapshot.focusRatio * 100).round()}%；这是活动占比，不是“生产力评分”。',
      );
    }
    if (snapshot.diaryEntries.isNotEmpty) {
      insights.add('这段时间有 ${snapshot.diaryEntries.length} 条已发布日记，可与活动时间线一起理解当天上下文。');
    }
    if (snapshot.contextSwitches >= 30) {
      insights.add('应用切换较多，回顾时可以重点看看是否存在频繁上下文切换。');
    }

    return RecapResult(
      headline: headline,
      summary: summary,
      insights: insights.take(4).toList(growable: false),
      snapshot: snapshot,
      origin: RecapOrigin.local,
    );
  }

  String _comparisonSentence(RecapSnapshot snapshot) {
    final change = snapshot.activeChangeRatio;
    if (change == null) return '上一同长度区间没有足够数据可供比较。';
    final percent = (change.abs() * 100).round();
    if (percent < 3) return '与上一同长度区间的活跃时长基本持平。';
    return change > 0
        ? '比上一同长度区间多约 $percent% 的活跃时长。'
        : '比上一同长度区间少约 $percent% 的活跃时长。';
  }
}
