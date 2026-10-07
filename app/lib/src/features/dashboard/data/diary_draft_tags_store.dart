import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../../../core/preferences/local_storage_paths.dart';
import '../domain/diary_entry_metadata.dart';
import 'diary_entry_metadata_store.dart';

enum DiaryDraftTagPhase {
  draft,
  publishPending,
  returnedId,
  complete,
  discarded,
}

enum DiaryDraftTagLoadStatus { missing, loaded, unreadable, future, conflict }

String diaryDraftTagIdentity() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class DiaryDraftTagSnapshot {
  DiaryDraftTagSnapshot({
    required this.date,
    required this.generation,
    this.revision = 0,
    Iterable<String> tags = const [],
    this.phase = DiaryDraftTagPhase.draft,
    this.intent,
    this.entryId,
  }) : tags = normalizedDiaryTags(tags) {
    DiaryEntryKey(date, 1);
    if (revision < 0 ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(generation) ||
        intent != null &&
            !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(intent!) ||
        entryId != null && entryId! < 1 ||
        (phase == DiaryDraftTagPhase.publishPending &&
            (intent == null || entryId != null)) ||
        ((phase == DiaryDraftTagPhase.returnedId ||
                phase == DiaryDraftTagPhase.complete) &&
            (intent == null || entryId == null)) ||
        ((phase == DiaryDraftTagPhase.draft ||
                phase == DiaryDraftTagPhase.discarded) &&
            (intent != null || entryId != null))) {
      throw const FormatException('Invalid draft tag receipt');
    }
  }
  final String date, generation;
  final int revision;
  final List<String> tags;
  final DiaryDraftTagPhase phase;
  final String? intent;
  final int? entryId;
  DiaryDraftTagSnapshot copyWith({
    int? revision,
    Iterable<String>? tags,
    DiaryDraftTagPhase? phase,
    String? intent,
    int? entryId,
  }) => DiaryDraftTagSnapshot(
    date: date,
    generation: generation,
    revision: revision ?? this.revision,
    tags: tags ?? this.tags,
    phase: phase ?? this.phase,
    intent: intent ?? this.intent,
    entryId: entryId ?? this.entryId,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'date': date,
    'generation': generation,
    'revision': revision,
    'tags': tags,
    'phase': phase.name,
    'intent': intent,
    'entryId': entryId,
  };
  factory DiaryDraftTagSnapshot.fromJson(Map<String, dynamic> raw) {
    if (raw['schemaVersion'] is int && raw['schemaVersion'] > 1)
      throw const DiaryMetadataFuture();
    const fields = {
      'schemaVersion',
      'date',
      'generation',
      'revision',
      'tags',
      'phase',
      'intent',
      'entryId',
    };
    if (raw.length != fields.length ||
        raw.keys.any((k) => !fields.contains(k)) ||
        raw['schemaVersion'] != 1 ||
        raw['date'] is! String ||
        raw['generation'] is! String ||
        raw['revision'] is! int ||
        raw['tags'] is! List ||
        (raw['tags'] as List).any((v) => v is! String) ||
        raw['phase'] is! String ||
        raw['intent'] != null && raw['intent'] is! String ||
        raw['entryId'] != null && raw['entryId'] is! int)
      throw const FormatException('Invalid draft tag data');
    final value = DiaryDraftTagSnapshot(
      date: raw['date'],
      generation: raw['generation'],
      revision: raw['revision'],
      tags: (raw['tags'] as List).cast<String>(),
      phase: DiaryDraftTagPhase.values.byName(raw['phase']),
      intent: raw['intent'],
      entryId: raw['entryId'],
    );
    if (jsonEncode(value.toJson()) !=
        jsonEncode({for (final k in fields) k: raw[k]}))
      throw const FormatException('Noncanonical draft tags');
    return value;
  }
}

bool sameDiaryDraftTags(DiaryDraftTagSnapshot? a, DiaryDraftTagSnapshot? b) =>
    jsonEncode(a?.toJson()) == jsonEncode(b?.toJson());

class DiaryDraftTagLoad {
  const DiaryDraftTagLoad(this.status, {this.value});
  final DiaryDraftTagLoadStatus status;
  final DiaryDraftTagSnapshot? value;
  bool get blocked =>
      status != DiaryDraftTagLoadStatus.missing &&
      status != DiaryDraftTagLoadStatus.loaded;
}

abstract interface class DiaryDraftTagsStore {
  Future<DiaryDraftTagLoad> load(String date);
  Future<void> put(
    DiaryDraftTagSnapshot value, {
    required int? expectedRevision,
  });
}

/// Each legacy composer owns a distinct working memory repository.
class MemoryDiaryDraftTagsStore implements DiaryDraftTagsStore {
  final values = <String, DiaryDraftTagSnapshot>{};
  @override
  Future<DiaryDraftTagLoad> load(String date) async {
    DiaryEntryKey(date, 1);
    return DiaryDraftTagLoad(
      values.containsKey(date)
          ? DiaryDraftTagLoadStatus.loaded
          : DiaryDraftTagLoadStatus.missing,
      value: values[date],
    );
  }

  @override
  Future<void> put(
    DiaryDraftTagSnapshot value, {
    required int? expectedRevision,
  }) async {
    final previous = values[value.date];
    if (sameDiaryDraftTags(previous, value)) return;
    if (previous?.revision != expectedRevision ||
        previous != null && previous.revision >= value.revision)
      throw const DiaryMetadataConflict();
    values[value.date] = value;
  }
}

Directory diaryDraftTagsDirectory() {
  if (!Platform.isWindows)
    throw const FileSystemException('Windows storage unavailable');
  final path = timeTraceStorageLocation(
    Platform.environment['LOCALAPPDATA'],
    diaryDraftTagsAssetSuffix,
  );
  if (path == null)
    throw const FileSystemException(
      'Absolute local application directory required',
    );
  return Directory(path);
}

/// Immutable per-date history. Existing Windows locking/no-replace backend is
/// shared, not replaced; no directory callback is evaluated during construction.
class FileDiaryDraftTagsStore implements DiaryDraftTagsStore {
  FileDiaryDraftTagsStore({
    Directory Function()? directory,
    this.backend = const DiaryMetadataFileBackend(),
    String Function()? nonce,
  }) : directory = directory ?? diaryDraftTagsDirectory,
       nonce = nonce ?? diaryDraftTagIdentity;
  final Directory Function() directory;
  final DiaryMetadataFileBackend backend;
  final String Function() nonce;
  Future<void> _queue = Future.value();
  Directory _date(String date) {
    DiaryEntryKey(date, 1);
    final root = directory();
    if (!root.isAbsolute)
      throw const FileSystemException('Absolute directory required');
    return Directory('${root.path}${Platform.pathSeparator}$date');
  }

  Future<DiaryDraftTagLoad> _read(String date) async {
    final dir = _date(date);
    if (!await backend.exists(dir))
      return const DiaryDraftTagLoad(DiaryDraftTagLoadStatus.missing);
    DiaryDraftTagSnapshot? best;
    var invalid = false, future = false, count = 0;
    await for (final entity in backend.list(dir)) {
      if (++count > 10000) {
        invalid = true;
        break;
      }
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is File &&
          (name == DiaryMetadataFileBackend.writerLockName ||
              RegExp(
                r'^tags-r(0|[1-9][0-9]*)\.json\.[a-zA-Z0-9_-]{1,80}\.tmp$',
              ).hasMatch(name)))
        continue;
      final match = RegExp(r'^tags-r(0|[1-9][0-9]*)\.json$').firstMatch(name);
      if (entity is! File || match == null) {
        invalid = true;
        continue;
      }
      try {
        final raw = jsonDecode(await backend.read(entity));
        if (raw is! Map<String, dynamic>)
          throw const FormatException('Invalid root');
        final value = DiaryDraftTagSnapshot.fromJson(raw);
        if (value.date != date || value.revision.toString() != match[1])
          throw const FormatException('Identity mismatch');
        if (best == null || value.revision > best.revision) best = value;
      } on DiaryMetadataFuture {
        future = true;
      } catch (_) {
        invalid = true;
      }
    }
    return DiaryDraftTagLoad(
      future
          ? DiaryDraftTagLoadStatus.future
          : invalid
          ? DiaryDraftTagLoadStatus.unreadable
          : best == null
          ? DiaryDraftTagLoadStatus.missing
          : DiaryDraftTagLoadStatus.loaded,
      value: best,
    );
  }

  @override
  Future<DiaryDraftTagLoad> load(String date) async {
    await _queue;
    try {
      return await _read(date);
    } catch (_) {
      return const DiaryDraftTagLoad(DiaryDraftTagLoadStatus.unreadable);
    }
  }

  @override
  Future<void> put(
    DiaryDraftTagSnapshot value, {
    required int? expectedRevision,
  }) {
    final operation = _queue.then((_) async {
      final encoded = jsonEncode(value.toJson());
      DiaryDraftTagSnapshot.fromJson(jsonDecode(encoded));
      if (utf8.encode(encoded).length > 65536)
        throw const FormatException('Draft tags too large');
      final dir = _date(value.date);
      await backend.create(dir);
      final lock = await backend.lockWriter(dir);
      try {
        final history = await _read(value.date);
        if (history.blocked) throw const DiaryMetadataConflict();
        final target = File(
          '${dir.path}${Platform.pathSeparator}tags-r${value.revision}.json',
        );
        if (history.value?.revision == value.revision) {
          if (await backend.read(target) == encoded) return;
          throw const DiaryMetadataConflict();
        }
        if (history.value?.revision != expectedRevision ||
            history.value != null && history.value!.revision >= value.revision)
          throw const DiaryMetadataConflict();
        final suffix = nonce();
        if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(suffix))
          throw const FormatException('Invalid nonce');
        final temporary = File('${target.path}.$suffix.tmp');
        await backend.write(temporary, encoded);
        final latest = await _read(value.date);
        if (latest.blocked || !sameDiaryDraftTags(latest.value, history.value))
          throw const DiaryMetadataConflict();
        await backend.commit(temporary, target);
        if (await backend.read(target) != encoded)
          throw const FileSystemException('Draft tag commit unverified');
      } finally {
        try {
          await lock.unlock(0, 1);
        } finally {
          await lock.close();
        }
      }
    });
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
