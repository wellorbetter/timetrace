class LiveActivityEpisode {
  const LiveActivityEpisode({
    required this.sequence,
    required this.appName,
    required this.startedAt,
    required this.isIdle,
    this.windowTitle,
    this.endedAt,
  });

  final int sequence;
  final String appName;
  final String? windowTitle;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool isIdle;

  factory LiveActivityEpisode.fromJson(Map<String, Object?> json) {
    final startedAt = DateTime.tryParse(json['started_at'] as String? ?? '');
    if (startedAt == null) {
      throw const FormatException('Live activity episode has no start time');
    }
    final endedText = json['ended_at'] as String?;
    return LiveActivityEpisode(
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      appName: json['app_name'] as String? ?? '',
      windowTitle: json['window_title'] as String?,
      startedAt: startedAt.toLocal(),
      endedAt: endedText == null
          ? null
          : DateTime.tryParse(endedText)?.toLocal(),
      isIdle: json['is_idle'] == true,
    );
  }
}

class LiveActivitySnapshot {
  const LiveActivitySnapshot({
    required this.version,
    required this.revision,
    required this.paused,
    required this.history,
    this.current,
  });

  final int version;
  final int revision;
  final bool paused;
  final LiveActivityEpisode? current;
  final List<LiveActivityEpisode> history;

  factory LiveActivitySnapshot.fromJson(Map<String, Object?> json) {
    if ((json['version'] as num?)?.toInt() != 1) {
      throw const FormatException('Unsupported live activity snapshot');
    }
    final current = json['current'];
    final rawHistory = json['history'];
    return LiveActivitySnapshot(
      version: 1,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      paused: json['paused'] == true,
      current: current is Map
          ? LiveActivityEpisode.fromJson(
              current.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      history: rawHistory is List
          ? rawHistory
                .whereType<Map>()
                .map(
                  (entry) => LiveActivityEpisode.fromJson(
                    entry.map((key, value) => MapEntry(key.toString(), value)),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class NowlineLine {
  const NowlineLine({
    required this.id,
    required this.text,
    required this.startedAt,
    required this.duration,
    required this.isCurrent,
    required this.isIdle,
    this.detail,
  });

  final int id;
  final String text;
  final String? detail;
  final DateTime startedAt;
  final Duration duration;
  final bool isCurrent;
  final bool isIdle;
}

class NowlineTimeline {
  const NowlineTimeline({
    required this.revision,
    required this.paused,
    required this.lines,
  });

  final int revision;
  final bool paused;
  final List<NowlineLine> lines;

  NowlineLine? get current => lines.where((line) => line.isCurrent).firstOrNull;
}
