/// Shared codec and wall-clock bound. Backward clock jumps may extend a
/// running timer up to this cap; explicit pause discards any excess rollback.
/// Display ticks do not alter the persisted UTC deadline.
const maxPomodoroSeconds = 10800;
const maxTimeSessions = 10000;

/// Strict components, not a permissive minute parser or truncated duration.
int? pomodoroSeconds(String hours, String minutes, String seconds) {
  final values = [hours, minutes, seconds];
  if (values.any((s) => !RegExp(r'^[0-9]+$').hasMatch(s))) return null;
  final n = values.map(int.tryParse).toList();
  if (n.any((v) => v == null)) return null;
  final h = n[0]!, m = n[1]!, s = n[2]!;
  if (h > 3 || m > 59 || s > 59) return null;
  final total = h * 3600 + m * 60 + s;
  return total >= 60 && total <= maxPomodoroSeconds ? total : null;
}

enum TimeSessionKind { pomodoro, countdown }

enum TimeSessionStatus { active, paused, completed, interrupted, cancelled }

class TimeSession {
  const TimeSession({
    required this.id,
    required this.kind,
    required this.startUtc,
    this.phase,
    this.endUtc,
    this.status = TimeSessionStatus.active,
    this.knownMicroseconds = 0,
    this.elapsedKnown = true,
  });
  final String id;
  final TimeSessionKind kind;
  final PomodoroPhase? phase;
  final DateTime startUtc;
  final DateTime? endUtc;
  final TimeSessionStatus status;
  final int knownMicroseconds;
  final bool elapsedKnown;
  bool get ongoing =>
      status == TimeSessionStatus.active || status == TimeSessionStatus.paused;
  double? get effectiveActiveSeconds =>
      elapsedKnown ? knownMicroseconds / 1000000 : null;
  TimeSession copyWith({
    TimeSessionStatus? status,
    DateTime? endUtc,
    int? knownMicroseconds,
    bool? elapsedKnown,
  }) => TimeSession(
    id: id,
    kind: kind,
    phase: phase,
    startUtc: startUtc,
    endUtc: endUtc ?? this.endUtc,
    status: status ?? this.status,
    knownMicroseconds: knownMicroseconds ?? this.knownMicroseconds,
    elapsedKnown: elapsedKnown ?? this.elapsedKnown,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'phase': phase?.name,
    'startUtc': startUtc.toUtc().toIso8601String(),
    'endUtc': endUtc?.toUtc().toIso8601String(),
    'status': status.name,
    'knownMicroseconds': knownMicroseconds,
    'elapsedKnown': elapsedKnown,
  };
  factory TimeSession.fromJson(Map<String, dynamic> raw) {
    const fields = {
      'id',
      'kind',
      'phase',
      'startUtc',
      'endUtc',
      'status',
      'knownMicroseconds',
      'elapsedKnown',
    };
    if (raw.length != fields.length ||
        raw.keys.any((k) => !fields.contains(k)) ||
        raw['id'] is! String ||
        !validTimeToolId(raw['id']) ||
        raw['knownMicroseconds'] is! int ||
        raw['knownMicroseconds'] < 0 ||
        raw['elapsedKnown'] is! bool)
      throw const FormatException('Invalid session');
    final value = TimeSession(
      id: raw['id'],
      kind: TimeSessionKind.values.byName(raw['kind'] as String),
      phase: raw['phase'] == null
          ? null
          : PomodoroPhase.values.byName(raw['phase'] as String),
      startUtc: utcInstant(raw['startUtc']),
      endUtc: raw['endUtc'] == null ? null : utcInstant(raw['endUtc']),
      status: TimeSessionStatus.values.byName(raw['status'] as String),
      knownMicroseconds: raw['knownMicroseconds'],
      elapsedKnown: raw['elapsedKnown'],
    );
    if ((value.kind == TimeSessionKind.pomodoro) != (value.phase != null) ||
        value.ongoing && value.endUtc != null ||
        !value.ongoing && value.endUtc == null ||
        value.elapsedKnown &&
            value.endUtc != null &&
            value.endUtc!.isBefore(value.startUtc))
      throw const FormatException('Inconsistent session');
    return value;
  }
}

enum PomodoroPhase { focus, rest }

class PomodoroState {
  const PomodoroState({
    this.phase = PomodoroPhase.focus,
    this.running = false,
    this.completed = false,
    this.deadlineUtc,
    this.remainingSeconds = 1500,
    this.focusSeconds = 1500,
    this.restSeconds = 300,
  });
  final PomodoroPhase phase;
  final bool running, completed;
  final DateTime? deadlineUtc;
  final int remainingSeconds, focusSeconds, restSeconds;
  int get duration => phase == PomodoroPhase.focus ? focusSeconds : restSeconds;
  int remaining(DateTime now) => running
      ? ((deadlineUtc!.difference(now.toUtc()).inMilliseconds / 1000).ceil())
            .clamp(0, maxPomodoroSeconds)
      : remainingSeconds;
  PomodoroState copyWith({
    PomodoroPhase? phase,
    bool? running,
    bool? completed,
    DateTime? deadlineUtc,
    bool clearDeadline = false,
    int? remainingSeconds,
    int? focusSeconds,
    int? restSeconds,
  }) => PomodoroState(
    phase: phase ?? this.phase,
    running: running ?? this.running,
    completed: completed ?? this.completed,
    deadlineUtc: clearDeadline ? null : deadlineUtc ?? this.deadlineUtc,
    remainingSeconds: remainingSeconds ?? this.remainingSeconds,
    focusSeconds: focusSeconds ?? this.focusSeconds,
    restSeconds: restSeconds ?? this.restSeconds,
  );
  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'running': running,
    'completed': completed,
    'deadlineUtc': deadlineUtc?.toUtc().toIso8601String(),
    'remainingSeconds': remainingSeconds,
    'focusSeconds': focusSeconds,
    'restSeconds': restSeconds,
  };
  factory PomodoroState.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
      (key) => !{
        'phase',
        'running',
        'completed',
        'deadlineUtc',
        'remainingSeconds',
        'focusSeconds',
        'restSeconds',
      }.contains(key),
    )) {
      throw const FormatException('Unknown timer field');
    }
    final phase = PomodoroPhase.values.byName(json['phase'] as String);
    final running = json['running'] as bool,
        completed = json['completed'] as bool;
    final focus = json['focusSeconds'] as int,
        rest = json['restSeconds'] as int;
    final remaining = json['remainingSeconds'] as int;
    final deadline = json['deadlineUtc'] == null
        ? null
        : utcInstant(json['deadlineUtc']);
    if (focus < 60 ||
        focus > maxPomodoroSeconds ||
        rest < 60 ||
        rest > maxPomodoroSeconds ||
        remaining < 0 ||
        remaining > maxPomodoroSeconds ||
        running != (deadline != null) ||
        (completed && (running || remaining != 0)))
      throw const FormatException('Invalid timer');
    return PomodoroState(
      phase: phase,
      running: running,
      completed: completed,
      deadlineUtc: deadline,
      remainingSeconds: remaining,
      focusSeconds: focus,
      restSeconds: rest,
    );
  }
}

class TimeTask {
  const TimeTask({
    required this.id,
    required this.text,
    this.done = false,
    this.createdAtUtc,
    this.dueAtUtc,
  });
  final String id, text;
  final bool done;
  final DateTime? createdAtUtc, dueAtUtc;
  TimeTask copyWith({
    String? text,
    bool? done,
    DateTime? dueAtUtc,
    bool clearDue = false,
  }) => TimeTask(
    id: id,
    text: text ?? this.text,
    done: done ?? this.done,
    createdAtUtc: createdAtUtc,
    dueAtUtc: clearDue ? null : dueAtUtc ?? this.dueAtUtc,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'done': done,
    'createdAtUtc': createdAtUtc?.toUtc().toIso8601String(),
    'dueAtUtc': dueAtUtc?.toUtc().toIso8601String(),
  };
  factory TimeTask.fromJson(Map<String, dynamic> json, {bool legacy = false}) {
    final id = json['id'] as String, text = json['text'] as String;
    if (!validTimeToolId(id) || !validTimeToolText(text))
      throw const FormatException('Invalid task');
    if (json.keys.any(
      (key) => !{
        'id',
        'text',
        'done',
        if (!legacy) 'createdAtUtc',
        if (!legacy) 'dueAtUtc',
      }.contains(key),
    )) {
      throw const FormatException('Unknown task field');
    }
    return TimeTask(
      id: id,
      text: text,
      done: json['done'] as bool,
      createdAtUtc: legacy || json['createdAtUtc'] == null
          ? null
          : utcInstant(json['createdAtUtc']),
      dueAtUtc: legacy || json['dueAtUtc'] == null
          ? null
          : utcInstant(json['dueAtUtc']),
    );
  }
}

class CountdownState {
  const CountdownState({required this.title, required this.targetUtc});
  final String title;
  final DateTime targetUtc;
  bool expired(DateTime now) => !targetUtc.isAfter(now.toUtc());
  Map<String, Object> toJson() => {
    'title': title,
    'targetUtc': targetUtc.toUtc().toIso8601String(),
  };
  factory CountdownState.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((key) => !{'title', 'targetUtc'}.contains(key))) {
      throw const FormatException('Unknown countdown field');
    }
    final title = json['title'] as String;
    if (!validTimeToolText(title)) throw const FormatException('Invalid title');
    return CountdownState(
      title: title,
      targetUtc: utcInstant(json['targetUtc']),
    );
  }
}

bool validTimeToolId(String id) =>
    RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id);
bool validTimeToolText(String text) =>
    text.trim().isNotEmpty && text.length <= 2000;
DateTime utcInstant(Object? value) {
  if (value is! String || !value.endsWith('Z'))
    throw const FormatException('UTC required');
  final result = DateTime.parse(value);
  // Reject the parser's normalization of invalid dates, offsets and overflow.
  final canonical = result.toIso8601String();
  final normalized = value.replaceFirst(RegExp(r'Z$'), '.000Z');
  if (!result.isUtc || (value != canonical && normalized != canonical))
    throw const FormatException('Strict UTC instant required');
  return result;
}

/// Local input without DateTime.parse's silent day overflow.
DateTime? parseLocalCountdown(String input) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(input.trim());
  if (match == null) return null;
  final n = [for (var i = 1; i <= 5; i++) int.parse(match.group(i)!)];
  final seconds = match.group(6) == null ? 0 : int.parse(match.group(6)!);
  if (n[0] < 1 ||
      n[1] < 1 ||
      n[1] > 12 ||
      n[3] > 23 ||
      n[4] > 59 ||
      seconds > 59)
    return null;
  final date = DateTime(n[0], n[1], n[2], n[3], n[4], seconds);
  if (date.year != n[0] ||
      date.month != n[1] ||
      date.day != n[2] ||
      date.hour != n[3] ||
      date.minute != n[4] ||
      date.second != seconds)
    return null;
  return date;
}

class TimeToolsState {
  TimeToolsState({
    this.revision = 0,
    this.pomodoro = const PomodoroState(),
    List<TimeTask> tasks = const [],
    this.countdown,
    List<TimeSession> sessions = const [],
  }) : tasks = List.unmodifiable(tasks),
       sessions = List.unmodifiable(sessions);
  final int revision;
  final PomodoroState pomodoro;
  final List<TimeTask> tasks;
  final CountdownState? countdown;
  final List<TimeSession> sessions;
  TimeSession? activeSession(TimeSessionKind kind) {
    for (final s in sessions) {
      if (s.kind == kind && s.ongoing) return s;
    }
    return null;
  }

  TimeToolsState copyWith({
    int? revision,
    PomodoroState? pomodoro,
    List<TimeTask>? tasks,
    CountdownState? countdown,
    List<TimeSession>? sessions,
  }) => TimeToolsState(
    revision: revision ?? this.revision,
    pomodoro: pomodoro ?? this.pomodoro,
    tasks: tasks ?? this.tasks,
    countdown: countdown ?? this.countdown,
    sessions: sessions ?? this.sessions,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 3,
    'revision': revision,
    'pomodoro': pomodoro.toJson(),
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'countdown': countdown?.toJson(),
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
  factory TimeToolsState.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] is! int ||
        (json['schemaVersion'] != 1 &&
            json['schemaVersion'] != 2 &&
            json['schemaVersion'] != 3) ||
        json['revision'] is! int ||
        (json['revision'] as int) < 0)
      throw const FormatException('Invalid version');
    if (json.keys.any(
      (key) => !{
        'schemaVersion',
        'revision',
        'pomodoro',
        'tasks',
        'countdown',
        if (json['schemaVersion'] == 3) 'sessions',
      }.contains(key),
    )) {
      throw const FormatException('Unknown state field');
    }
    final rawTasks = json['tasks'] as List;
    if (rawTasks.length > 10000) throw const FormatException('Too many tasks');
    final tasks = rawTasks
        .map(
          (raw) => TimeTask.fromJson(
            Map<String, dynamic>.from(raw as Map),
            legacy: json['schemaVersion'] == 1,
          ),
        )
        .toList();
    if (tasks.map((task) => task.id).toSet().length != tasks.length)
      throw const FormatException('Duplicate identity');
    final sessions = json['schemaVersion'] == 3
        ? (json['sessions'] as List)
              .map(
                (s) =>
                    TimeSession.fromJson(Map<String, dynamic>.from(s as Map)),
              )
              .toList()
        : <TimeSession>[];
    if (sessions.length > maxTimeSessions ||
        sessions.map((s) => s.id).toSet().length != sessions.length ||
        TimeSessionKind.values.any(
          (kind) =>
              sessions.where((s) => s.kind == kind && s.ongoing).length > 1,
        ))
      throw const FormatException('Invalid session history');
    final pomodoro = PomodoroState.fromJson(
      Map<String, dynamic>.from(json['pomodoro'] as Map),
    );
    final countdown = json['countdown'] == null
        ? null
        : CountdownState.fromJson(
            Map<String, dynamic>.from(json['countdown'] as Map),
          );
    for (final session in sessions.where((s) => s.ongoing)) {
      if (session.kind == TimeSessionKind.pomodoro &&
              (session.phase != pomodoro.phase ||
                  pomodoro.completed ||
                  (session.status == TimeSessionStatus.active) !=
                      pomodoro.running ||
                  session.status == TimeSessionStatus.paused &&
                      pomodoro.remainingSeconds == 0) ||
          session.kind == TimeSessionKind.countdown &&
              (countdown == null ||
                  session.status != TimeSessionStatus.active ||
                  !countdown.targetUtc.isAfter(session.startUtc))) {
        throw const FormatException('Active session does not match timer');
      }
    }
    return TimeToolsState(
      revision: json['revision'] as int,
      pomodoro: pomodoro,
      tasks: tasks,
      sessions: sessions,
      countdown: countdown,
    );
  }
}
