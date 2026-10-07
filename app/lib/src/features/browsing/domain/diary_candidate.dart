enum DiaryCandidateSource { local, ai }

enum CandidatePublishStatus {
  ready,
  appendIntent,
  awaitingVerification,
  saved,
  unknown,
}

/// Private candidate data. Runtime storage errors never enter the file format.
class DiaryCandidate {
  const DiaryCandidate({
    required this.id,
    required this.source,
    required this.startUtc,
    required this.endUtc,
    required this.saveDate,
    required this.content,
    required this.capturedAtUtc,
    this.generatedAtUtc,
    this.revision = 0,
    this.publishStatus = CandidatePublishStatus.ready,
    this.entryId,
    this.persisted = false,
    this.storageError,
    this.recoveryBlocked = false,
  });

  final String id;
  final DiaryCandidateSource source;
  final String startUtc;
  final String endUtc;
  final String saveDate;
  final String content;
  final DateTime capturedAtUtc;
  final DateTime? generatedAtUtc;
  final int revision;
  final CandidatePublishStatus publishStatus;
  final String? entryId;
  final bool persisted;
  final String? storageError;
  final bool recoveryBlocked;

  String get sourceLabel =>
      source == DiaryCandidateSource.local ? '本地整理' : 'AI 生成';
  String get rangeLabel => candidateRangeLabel(startUtc, endUtc, saveDate);
  String get timeLabel {
    final value = generatedAtUtc?.toLocal();
    if (value == null) return '生成时间未记录';
    return '${candidateDate(value)} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  DiaryCandidate copyWith({
    int? revision,
    CandidatePublishStatus? publishStatus,
    String? entryId,
    bool? persisted,
    String? storageError,
    bool clearStorageError = false,
    bool? recoveryBlocked,
  }) => DiaryCandidate(
    id: id,
    source: source,
    startUtc: startUtc,
    endUtc: endUtc,
    saveDate: saveDate,
    content: content,
    capturedAtUtc: capturedAtUtc,
    generatedAtUtc: generatedAtUtc,
    revision: revision ?? this.revision,
    publishStatus: publishStatus ?? this.publishStatus,
    entryId: entryId ?? this.entryId,
    persisted: persisted ?? this.persisted,
    storageError: clearStorageError
        ? null
        : (storageError ?? this.storageError),
    recoveryBlocked: recoveryBlocked ?? this.recoveryBlocked,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'revision': revision,
    'source': source.name,
    'startUtc': startUtc,
    'endUtc': endUtc,
    'saveDate': saveDate,
    'content': content,
    'capturedAtUtc': capturedAtUtc.toUtc().toIso8601String(),
    'generatedAtUtc': generatedAtUtc?.toUtc().toIso8601String(),
    'publishStatus': publishStatus.name,
    'entryId': entryId,
  };

  static bool validId(String id) =>
      RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id);

  factory DiaryCandidate.fromJson(Map<String, dynamic> json) {
    const fields = {
      'schemaVersion',
      'id',
      'revision',
      'source',
      'startUtc',
      'endUtc',
      'saveDate',
      'content',
      'capturedAtUtc',
      'generatedAtUtc',
      'publishStatus',
      'entryId',
    };
    if (json['schemaVersion'] != 1 ||
        json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unsupported candidate');
    }
    String text(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw const FormatException('Invalid candidate');
      }
      return value;
    }

    final id = text('id');
    final revision = json['revision'];
    final start = text('startUtc');
    final end = text('endUtc');
    final date = text('saveDate');
    final startTime = DateTime.parse(start);
    final endTime = DateTime.parse(end);
    if (!validId(id) ||
        revision is! int ||
        revision < 0 ||
        !endTime.isAfter(startTime) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        candidateDate(DateTime.parse(date)) != date) {
      throw const FormatException('Invalid candidate');
    }
    final source = DiaryCandidateSource.values.byName(text('source'));
    final status = CandidatePublishStatus.values.byName(text('publishStatus'));
    final entryId = json['entryId'];
    if (entryId != null &&
        (entryId is! String || !RegExp(r'^[1-9]\d*$').hasMatch(entryId))) {
      throw const FormatException('Invalid receipt');
    }
    if ((status == CandidatePublishStatus.awaitingVerification ||
            status == CandidatePublishStatus.saved) &&
        entryId == null) {
      throw const FormatException('Missing receipt');
    }
    final generated = json['generatedAtUtc'];
    if (generated != null && generated is! String) {
      throw const FormatException('Invalid time');
    }
    return DiaryCandidate(
      id: id,
      revision: revision,
      source: source,
      startUtc: start,
      endUtc: end,
      saveDate: date,
      content: text('content'),
      capturedAtUtc: DateTime.parse(text('capturedAtUtc')).toUtc(),
      generatedAtUtc: generated == null
          ? null
          : DateTime.parse(generated as String).toUtc(),
      publishStatus: status,
      entryId: entryId as String?,
      persisted: true,
    );
  }
}

String candidateDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String candidateRangeLabel(String startUtc, String endUtc, String saveDate) {
  final end = DateTime.tryParse(endUtc)
      ?.subtract(const Duration(microseconds: 1))
      .toLocal();
  if (end == null || DateTime.tryParse(startUtc) == null) return saveDate;
  final last = candidateDate(end);
  return last == saveDate ? saveDate : '$saveDate — $last';
}
