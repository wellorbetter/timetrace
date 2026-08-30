import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

/// Turns low-level foreground episodes into restrained, factual display lines.
///
/// This is deliberately deterministic. The live surface never waits for a
/// model call and never spends tokens just to keep the overlay moving.
class NowlineSemanticizer {
  const NowlineSemanticizer();

  NowlineTimeline build({
    required LiveActivitySnapshot snapshot,
    required NowlinePreferences preferences,
    required DateTime now,
  }) {
    final episodes = <LiveActivityEpisode>[
      ...snapshot.history,
      ?snapshot.current,
    ];
    final lines = episodes
        .map(
          (episode) => _line(
            episode,
            isCurrent: identical(episode, snapshot.current),
            preferences: preferences,
            now: now,
          ),
        )
        .toList(growable: false);
    final start = (lines.length - preferences.lineCount).clamp(0, lines.length);
    return NowlineTimeline(
      revision: snapshot.revision,
      paused: snapshot.paused,
      lines: lines.sublist(start),
    );
  }

  NowlineLine _line(
    LiveActivityEpisode episode, {
    required bool isCurrent,
    required NowlinePreferences preferences,
    required DateTime now,
  }) {
    final end = episode.endedAt ?? now;
    final duration = end.isAfter(episode.startedAt)
        ? end.difference(episode.startedAt)
        : Duration.zero;
    final appName = _displayAppName(episode.appName);
    final text = episode.isIdle
        ? (isCurrent ? '暂时离开屏幕' : '短暂离开了屏幕')
        : _activityText(appName, isCurrent: isCurrent);
    final title = preferences.showWindowTitles
        ? _safeTitle(episode.windowTitle, appName)
        : null;
    final detailParts = <String>[
      ?title,
      _durationLabel(duration, isCurrent: isCurrent),
    ];
    return NowlineLine(
      id: episode.sequence,
      text: text,
      detail: detailParts.join(' · '),
      startedAt: episode.startedAt,
      duration: duration,
      isCurrent: isCurrent,
      isIdle: episode.isIdle,
    );
  }

  String _activityText(String appName, {required bool isCurrent}) {
    final lower = appName.toLowerCase();
    if (_containsAny(lower, const [
      'chrome',
      'edge',
      'firefox',
      'safari',
      'arc',
      'browser',
    ])) {
      return isCurrent ? '正在 $appName 中浏览' : '在 $appName 中浏览';
    }
    if (_containsAny(lower, const [
      'figma',
      'sketch',
      'photoshop',
      'illustrator',
    ])) {
      return isCurrent ? '正在 $appName 中设计' : '在 $appName 中设计';
    }
    if (_containsAny(lower, const [
      'slack',
      'discord',
      'teams',
      'wechat',
      '微信',
      'telegram',
    ])) {
      return isCurrent ? '正在 $appName 中沟通' : '在 $appName 中沟通';
    }
    if (_containsAny(lower, const [
      'notion',
      'obsidian',
      'word',
      'pages',
      'typora',
    ])) {
      return isCurrent ? '正在 $appName 中记录' : '在 $appName 中记录';
    }
    if (_containsAny(lower, const ['spotify', 'music', '网易云音乐', 'vlc'])) {
      return isCurrent ? '正在 $appName 中播放媒体' : '在 $appName 中播放媒体';
    }
    return isCurrent ? '正在使用 $appName' : '使用了 $appName';
  }

  String _displayAppName(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value == '__IDLE__') return '电脑';
    return value.length <= 42 ? value : '${value.substring(0, 41)}…';
  }

  String? _safeTitle(String? raw, String appName) {
    var value = raw?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == appName.toLowerCase()) {
      return null;
    }
    final combined = '$appName $value'.toLowerCase();
    if (_containsAny(combined, const [
      '1password',
      'bitwarden',
      'keepass',
      'keychain',
      'authenticator',
      'incognito',
      'inprivate',
      '无痕',
      '密码',
    ])) {
      return '敏感窗口标题已隐藏';
    }
    for (final suffix in [' - $appName', ' — $appName', ' – $appName']) {
      if (value.toLowerCase().endsWith(suffix.toLowerCase())) {
        value = value.substring(0, value.length - suffix.length).trim();
      }
    }
    if (value.isEmpty) return null;
    return value.length <= 72 ? value : '${value.substring(0, 71)}…';
  }

  String _durationLabel(Duration duration, {required bool isCurrent}) {
    final seconds = duration.inSeconds.clamp(0, 24 * 3600).toInt();
    if (seconds < 10) return isCurrent ? '刚刚' : '${seconds}s';
    if (seconds < 60) return '${seconds}s';
    return formatRecapDuration(seconds);
  }

  bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);
}
