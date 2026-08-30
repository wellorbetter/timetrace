import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

class LocalRecapEngine {
  const LocalRecapEngine();

  RecapResult generate(RecapSnapshot snapshot) {
    if (snapshot.activeSeconds <= 0) {
      final diarySummary = _diarySentence(snapshot.diaryEntries);
      return RecapResult(
        headline: diarySummary == null
            ? '${snapshot.label}还没有足够的使用记录'
            : '${snapshot.label}留下了日记记录',
        summary:
            diarySummary ?? 'TimeTrace 暂时没有检测到可用于回顾的应用使用记录。继续使用电脑后，这里会自动形成回顾。',
        insights: const [],
        snapshot: snapshot,
        origin: RecapOrigin.local,
      );
    }

    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final headline = top == null
        ? '${snapshot.label}共记录 ${formatRecapDuration(snapshot.activeSeconds)} 活跃时间'
        : '${snapshot.label}主要时间花在 ${top.name}';

    final usedApps = snapshot.topApps
        .take(3)
        .map((app) => '${app.name}（${formatRecapDuration(app.activeSeconds)}）')
        .join('、');
    final diarySummary = _diarySentence(snapshot.diaryEntries);
    final summary = [
      usedApps.isEmpty
          ? '${snapshot.label}记录到 ${formatRecapDuration(snapshot.activeSeconds)} 的应用使用。'
          : '${snapshot.label}主要使用了 $usedApps。',
      if (diarySummary != null) diarySummary,
    ].join('');

    return RecapResult(
      headline: headline,
      summary: summary,
      insights: const [],
      snapshot: snapshot,
      origin: RecapOrigin.local,
    );
  }
}

String? _diarySentence(List<String> entries) {
  if (entries.isEmpty) return null;
  final excerpts = entries
      .take(2)
      .map((entry) {
        final normalized = entry.replaceAll(RegExp(r'\s+'), ' ').trim();
        return normalized.length <= 72
            ? normalized
            : '${normalized.substring(0, 72)}…';
      })
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  if (excerpts.isEmpty) return null;
  return '日记中记录了：${excerpts.join('；')}。';
}
