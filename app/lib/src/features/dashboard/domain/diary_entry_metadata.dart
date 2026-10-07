enum DiaryEntrySource { unknown, handwritten, local, ai }

extension DiaryEntrySourceLabel on DiaryEntrySource {
  String get label => switch (this) {
    DiaryEntrySource.unknown => '来源未知',
    DiaryEntrySource.handwritten => '手写',
    DiaryEntrySource.local => '本地整理',
    DiaryEntrySource.ai => 'AI 生成',
  };
}

class DiaryEntryKey {
  DiaryEntryKey(this.date, this.entryId) {
    final parsed = DateTime.tryParse(date);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        parsed == null ||
        parsed.year < 1 ||
        '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' !=
            date ||
        entryId < 1) {
      throw const FormatException('Invalid diary identity');
    }
  }
  final String date;
  final int entryId;
  @override
  bool operator ==(Object other) =>
      other is DiaryEntryKey && other.date == date && other.entryId == entryId;
  @override
  int get hashCode => Object.hash(date, entryId);
}

List<String> normalizedDiaryTags(Iterable<String> values) {
  final result = <String>[];
  for (final raw in values) {
    final tag = raw.trim();
    if (tag.isEmpty ||
        tag.runes.length > 20 ||
        tag.runes.any(
          (rune) =>
              rune < 32 ||
              (rune >= 127 && rune <= 159) ||
              rune == 0x2028 ||
              rune == 0x2029,
        )) {
      throw const FormatException('标签须为1–20个字符，不能含换行或控制字符');
    }
    if (!result.contains(tag)) result.add(tag);
  }
  if (result.length > 8) throw const FormatException('最多8个标签');
  return List.unmodifiable(result);
}

class DiaryMetadataFuture implements Exception {
  const DiaryMetadataFuture();
}

/// Metadata only. Never contains diary text, image paths or credentials.
class DiaryEntryMetadata {
  DiaryEntryMetadata({
    required this.key,
    this.revision = 0,
    this.source = DiaryEntrySource.unknown,
    Iterable<String> tags = const [],
  }) : tags = normalizedDiaryTags(tags) {
    if (revision < 0) throw const FormatException('Invalid revision');
  }
  final DiaryEntryKey key;
  final int revision;
  final DiaryEntrySource source;
  final List<String> tags;
  DiaryEntryMetadata copyWith({
    int? revision,
    DiaryEntrySource? source,
    Iterable<String>? tags,
  }) => DiaryEntryMetadata(
    key: key,
    revision: revision ?? this.revision,
    source: source ?? this.source,
    tags: tags ?? this.tags,
  );
  Map<String, Object> toJson() => {
    'schemaVersion': 1,
    'date': key.date,
    'entryId': key.entryId,
    'revision': revision,
    'source': source.name,
    'tags': tags,
  };
  factory DiaryEntryMetadata.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] is int && (json['schemaVersion'] as int) > 1) {
      throw const DiaryMetadataFuture();
    }
    const fields = {
      'schemaVersion',
      'date',
      'entryId',
      'revision',
      'source',
      'tags',
    };
    if (json['schemaVersion'] != 1 ||
        json.length != fields.length ||
        json.keys.any((field) => !fields.contains(field)) ||
        json['date'] is! String ||
        json['entryId'] is! int ||
        json['revision'] is! int ||
        json['source'] is! String ||
        json['tags'] is! List ||
        (json['tags'] as List).any((tag) => tag is! String)) {
      throw const FormatException('Invalid metadata');
    }
    final tags = (json['tags'] as List).cast<String>();
    final result = DiaryEntryMetadata(
      key: DiaryEntryKey(json['date'], json['entryId']),
      revision: json['revision'],
      source: DiaryEntrySource.values.byName(json['source']),
      tags: tags,
    );
    if (result.tags.length != tags.length ||
        List.generate(
          tags.length,
          (i) => tags[i] == result.tags[i],
        ).contains(false)) {
      throw const FormatException('Noncanonical tags');
    }
    return result;
  }
}
