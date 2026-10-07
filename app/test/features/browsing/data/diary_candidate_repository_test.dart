import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/browsing/data/diary_candidate_repository.dart';
import 'package:timetrace_app/src/features/browsing/domain/diary_candidate.dart';

DiaryCandidate _candidate({
  String id = 'paid-1',
  int revision = 0,
  DiaryCandidateSource source = DiaryCandidateSource.ai,
  CandidatePublishStatus status = CandidatePublishStatus.ready,
  String? entryId,
}) => DiaryCandidate(
  id: id,
  revision: revision,
  source: source,
  startUtc: '2026-10-02T00:00:00Z',
  endUtc: '2026-10-03T00:00:00Z',
  saveDate: '2026-10-02',
  content: '## 候选全文\n不应丢失的付费结果。',
  capturedAtUtc: DateTime.utc(2026, 10, 3, 12),
  generatedAtUtc: DateTime.utc(2026, 10, 3, 12),
  publishStatus: status,
  entryId: entryId,
);
Future<Directory> _temporary() async {
  final root = await Directory.systemTemp.createTemp(
    'timetrace-candidate-fixture-',
  );
  final known = root.absolute.path;
  addTearDown(() async {
    if (root.absolute.path != known ||
        !root.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('timetrace-candidate-fixture-')) {
      throw StateError('Unsafe fixture cleanup');
    }
    if (await root.exists()) await root.delete(recursive: true);
  });
  return root;
}

File _revision(Directory root, String name) =>
    File('${root.path}${Platform.pathSeparator}$name');

void main() {
  test('JSON whitelists source/range/time/receipt; rejects credentials and future schema', () {
    final candidate = _candidate(
      status: CandidatePublishStatus.awaitingVerification,
      entryId: '9007199254740993',
    );
    final json = candidate.toJson();
    final restored = DiaryCandidate.fromJson(Map<String, dynamic>.from(json));
    expect(restored.content, candidate.content);
    expect(restored.source, DiaryCandidateSource.ai);
    expect(restored.generatedAtUtc, candidate.generatedAtUtc);
    expect(restored.entryId, '9007199254740993');
    expect(restored.persisted, isTrue);
    expect(
      json.keys,
      unorderedEquals([
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
      ]),
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'apiKey': 'fixture'}),
      throwsFormatException,
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'schemaVersion': 2}),
      throwsFormatException,
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'id': '../escape'}),
      throwsFormatException,
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'entryId': null}),
      throwsFormatException,
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'saveDate': '2026-02-31'}),
      throwsFormatException,
    );
    expect(
      () => DiaryCandidate.fromJson({...json, 'endUtc': candidate.startUtc}),
      throwsFormatException,
    );
    final legacy = DiaryCandidate.fromJson({...json, 'generatedAtUtc': null});
    expect(legacy.timeLabel, '生成时间未记录');
  });

  test(
    'local and AI histories plus returned receipt survive a fresh repository',
    () async {
      final root = await _temporary();
      final repo = FileDiaryCandidateRepository(directory: () => root);
      final paid = _candidate();
      await repo.put(paid);
      await repo.put(
        _candidate(id: 'local-1', source: DiaryCandidateSource.local),
      );
      await repo.put(
        paid.copyWith(
          revision: 1,
          publishStatus: CandidatePublishStatus.appendIntent,
        ),
      );
      await repo.put(
        paid.copyWith(
          revision: 2,
          publishStatus: CandidatePublishStatus.awaitingVerification,
          entryId: '13',
        ),
      );
      final restored = await FileDiaryCandidateRepository(directory: () => root)
          .load();
      expect(restored.hasRecoveryIssue, isFalse);
      expect(restored.candidates, hasLength(2));
      final latest = restored.candidates.singleWhere(
        (item) => item.id == paid.id,
      );
      expect(latest.revision, 2);
      expect(latest.content, paid.content);
      expect(latest.saveDate, paid.saveDate);
      expect(latest.startUtc, paid.startUtc);
      expect(latest.generatedAtUtc, paid.generatedAtUtc);
      expect(latest.entryId, '13');
      expect(latest.publishStatus, CandidatePublishStatus.awaitingVerification);
      // Every previous immutable revision remains present.
      expect(await _revision(root, 'paid-1.0.json').exists(), isTrue);
      expect(await _revision(root, 'paid-1.1.json').exists(), isTrue);
    },
  );

  for (final futureVersion in [false, true]) {
    test(
      'damaged latest revision future=$futureVersion preserves content but blocks unsafe ready fallback',
      () async {
        final root = await _temporary();
        final repo = FileDiaryCandidateRepository(directory: () => root);
        final paid = _candidate();
        await repo.put(paid);
        await _revision(root, 'paid-1.3.json').writeAsString(
          futureVersion
              ? jsonEncode({
                  ...paid.toJson(),
                  'revision': 3,
                  'schemaVersion': 9,
                })
              : '{partial',
          flush: true,
        );
        await _revision(
          root,
          'other-bad.0.json',
        ).writeAsString('[]', flush: true);
        final loaded = await repo.load();
        expect(loaded.hasRecoveryIssue, isTrue);
        expect(loaded.candidates, hasLength(1));
        final recovered = loaded.candidates.single;
        expect(recovered.content, paid.content);
        expect(recovered.revision, 3);
        expect(recovered.recoveryBlocked, isTrue);
        expect(recovered.publishStatus, CandidatePublishStatus.unknown);
        expect(recovered.entryId, isNull);
        // A new safe unknown revision can be committed, without rewriting bad evidence.
        await repo.put(recovered.copyWith(revision: 4));
        final next = await FileDiaryCandidateRepository(directory: () => root)
            .load();
        expect(
          next.candidates.single.publishStatus,
          CandidatePublishStatus.unknown,
        );
        expect(next.candidates.single.revision, 4);
        expect(
          await _revision(root, 'paid-1.3.json').readAsString(),
          futureVersion
              ? jsonEncode({
                  ...paid.toJson(),
                  'revision': 3,
                  'schemaVersion': 9,
                })
              : '{partial',
        );
      },
    );
  }

  test(
    'incomplete temporary file is ignored and does not replace known history',
    () async {
      final root = await _temporary();
      final repo = FileDiaryCandidateRepository(directory: () => root);
      await repo.put(_candidate());
      await _revision(
        root,
        'paid-1.9.json.123.0.tmp',
      ).writeAsString('{partial', flush: true);
      final loaded = await repo.load();
      expect(loaded.hasRecoveryIssue, isFalse);
      expect(loaded.candidates.single.revision, 0);
    },
  );

  test('failed write preserves history and queue recovers without re-generating content', () async {
    final root = await _temporary();
    var fail = false;
    final repo = FileDiaryCandidateRepository(
      directory: () {
        if (fail) throw const FileSystemException('fixture denied');
        return root;
      },
    );
    final candidate = _candidate();
    await repo.put(candidate);
    fail = true;
    await expectLater(
      repo.put(
        candidate.copyWith(
          revision: 1,
          publishStatus: CandidatePublishStatus.appendIntent,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await _revision(root, 'paid-1.0.json').readAsString(),
      jsonEncode(candidate.toJson()),
    );
    expect(await _revision(root, 'paid-1.1.json').exists(), isFalse);
    fail = false;
    await repo.put(
      candidate.copyWith(
        revision: 1,
        publishStatus: CandidatePublishStatus.unknown,
      ),
    );
    final result = await repo.load();
    expect(result.candidates.single.content, candidate.content);
    expect(
      result.candidates.single.publishStatus,
      CandidatePublishStatus.unknown,
    );
  });

  test('same acknowledged revision retry is idempotent; a different payload never overwrites it', () async {
    final root = await _temporary();
    final repo = FileDiaryCandidateRepository(directory: () => root);
    final candidate = _candidate();
    await repo.put(candidate);
    await repo.put(
      candidate.copyWith(persisted: true, storageError: 'runtime only'),
    );
    final original = await _revision(root, 'paid-1.0.json').readAsString();
    await expectLater(
      repo.put(
        candidate.copyWith(publishStatus: CandidatePublishStatus.unknown),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await _revision(root, 'paid-1.0.json').readAsString(), original);
    expect(
      (await repo.load()).candidates.single.publishStatus,
      CandidatePublishStatus.ready,
    );
  });

  test(
    'durable intent and unknown states round trip without inventing a saved ID',
    () async {
      final root = await _temporary();
      final repo = FileDiaryCandidateRepository(directory: () => root);
      await repo.put(_candidate(status: CandidatePublishStatus.appendIntent));
      var result = await FileDiaryCandidateRepository(directory: () => root)
          .load();
      expect(
        result.candidates.single.publishStatus,
        CandidatePublishStatus.appendIntent,
      );
      expect(result.candidates.single.entryId, isNull);
      await repo.put(
        _candidate(revision: 1, status: CandidatePublishStatus.unknown),
      );
      result = await FileDiaryCandidateRepository(directory: () => root).load();
      expect(
        result.candidates.single.publishStatus,
        CandidatePublishStatus.unknown,
      );
      expect(result.candidates.single.entryId, isNull);
    },
  );
}
