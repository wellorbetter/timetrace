import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

class LocalRecapEngine {
  const LocalRecapEngine();

  RecapResult generate(RecapSnapshot snapshot) {
    final diaryEntries = snapshot.diaryEntries
        .map(_normalize)
        .where((entry) => entry.isNotEmpty)
        .take(2)
        .toList(growable: false);
    final appNames = _uniqueAppNames(snapshot.topApps);

    if (diaryEntries.isNotEmpty) {
      final diarySummary = diaryEntries
          .map((entry) => '“${_truncate(entry, 72)}”')
          .join('、');
      final appContext = appNames.isEmpty
          ? '没有检测到足够的应用使用记录。'
          : '使用记录主要涉及 ${appNames.join('、')}。';
      return RecapResult(
        headline: '${snapshot.label}记录了：${_truncate(diaryEntries.first, 36)}',
        summary: '日记中写到 $diarySummary。$appContext',
        insights: const [],
        snapshot: snapshot,
        origin: RecapOrigin.local,
      );
    }

    if (appNames.isNotEmpty) {
      return RecapResult(
        headline: '${snapshot.label}主要使用了 ${appNames.first}',
        summary:
            '使用记录主要涉及 ${appNames.join('、')}。仅凭应用名称无法判断具体完成了什么；发布一条日记后，回顾可以补充任务上下文。',
        insights: const [],
        snapshot: snapshot,
        origin: RecapOrigin.local,
      );
    }

    return RecapResult(
      headline: '${snapshot.label}还没有可回顾的记录',
      summary: 'TimeTrace 暂时没有检测到可回顾的应用使用记录，也没有已发布日记。',
      insights: const [],
      snapshot: snapshot,
      origin: RecapOrigin.local,
    );
  }

  List<String> _uniqueAppNames(List<RecapAppFact> apps) {
    final seen = <String>{};
    final names = <String>[];
    for (final app in apps) {
      final name = _normalize(app.name);
      if (name.isEmpty || !seen.add(name)) continue;
      names.add(name);
      if (names.length == 3) break;
    }
    return names;
  }

  String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  String _truncate(String value, int maxCharacters) {
    final normalized = _normalize(value);
    if (normalized.length <= maxCharacters) return normalized;
    return '${normalized.substring(0, maxCharacters).trimRight()}…';
  }
}
