import 'dart:convert';
import 'dart:io';

import '../domain/diary_candidate.dart';

class CandidateLoad {
  CandidateLoad(this.candidates, {this.hasRecoveryIssue = false});
  final List<DiaryCandidate> candidates;
  final bool hasRecoveryIssue;
}

abstract interface class DiaryCandidateRepository {
  Future<CandidateLoad> load();
  Future<void> put(DiaryCandidate candidate);
}

/// Evaluated only when load/put are called, never by a test's fake repository.
Directory candidateSupportDirectory() {
  if (!Platform.isWindows) {
    throw const FileSystemException('Candidate storage unavailable');
  }
  final root = Platform.environment['LOCALAPPDATA'];
  if (root == null ||
      root.isEmpty ||
      !RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(root)) {
    throw const FileSystemException('Candidate storage unavailable');
  }
  return Directory(
    '$root${Platform.pathSeparator}TimeTrace${Platform.pathSeparator}diary-candidates-v1',
  );
}

/// Immutable revisions avoid replacing valid history during a failed write.
class FileDiaryCandidateRepository implements DiaryCandidateRepository {
  FileDiaryCandidateRepository({required this.directory});
  final Directory Function() directory;
  Future<void> _tail = Future<void>.value();
  int _temporarySequence = 0;
  static final _filename = RegExp(r'^([a-zA-Z0-9_-]{1,80})\.([0-9]+)\.json$');

  @override
  Future<CandidateLoad> load() async {
    // Complete earlier writes before assembling a consistent repository view.
    await _tail;
    final root = directory();
    if (!await root.exists()) return CandidateLoad([]);
    final latest = <String, DiaryCandidate>{};
    final highest = <String, int>{};
    var hasIssue = false;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = _filename.firstMatch(name);
      if (match == null)
        continue; // Incomplete tmp files never become candidates.
      final id = match.group(1)!;
      final revision = int.tryParse(match.group(2)!);
      if (revision == null) {
        hasIssue = true;
        continue;
      }
      if (revision > (highest[id] ?? -1)) highest[id] = revision;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid candidate');
        }
        final candidate = DiaryCandidate.fromJson(decoded);
        if (candidate.id != id || candidate.revision != revision) {
          throw const FormatException('Invalid revision');
        }
        if (revision > (latest[id]?.revision ?? -1)) latest[id] = candidate;
      } catch (_) {
        hasIssue = true;
      }
    }
    final candidates = <DiaryCandidate>[];
    for (final entry in latest.entries) {
      final candidate = entry.value;
      final high = highest[entry.key]!;
      candidates.add(
        high > candidate.revision
            ? candidate.copyWith(
                revision: high,
                publishStatus: CandidatePublishStatus.unknown,
                recoveryBlocked: true,
                storageError: '历史存在损坏版本，保存结果待人工核对',
              )
            : candidate,
      );
    }
    return CandidateLoad(candidates, hasRecoveryIssue: hasIssue);
  }

  @override
  Future<void> put(DiaryCandidate candidate) {
    final operation = _tail.then((_) => _put(candidate));
    // A failed operation does not poison future retries.
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _put(DiaryCandidate candidate) async {
    if (!DiaryCandidate.validId(candidate.id) || candidate.revision < 0) {
      throw const FormatException('Invalid candidate identity');
    }
    final encoded = jsonEncode(candidate.toJson());
    // Validate every committed document, including caller-created fixtures.
    DiaryCandidate.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
    final root = directory();
    await root.create(recursive: true);
    final target = File(
      '${root.path}${Platform.pathSeparator}${candidate.id}.${candidate.revision}.json',
    );
    if (await target.exists()) {
      // Retry of a commit whose acknowledgement was lost is idempotent.
      if (await target.readAsString() == encoded) return;
      throw const FileSystemException('Candidate revision already exists');
    }
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.${_temporarySequence++}.tmp',
    );
    await temporary.writeAsString(encoded, flush: true);
    if (await target.exists()) {
      throw const FileSystemException('Candidate revision already exists');
    }
    await temporary.rename(target.path);
  }
}
