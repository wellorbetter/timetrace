import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/bridge/api_provider.dart';
import '../../calendar/providers/calendar_data_provider.dart';
import '../data/diary_candidate_repository.dart';
import '../domain/diary_candidate.dart';
import 'ai_connection_provider.dart';

typedef DiaryRequester = Future<String> Function({
  required String key,
  required String model,
  required String summary,
});

final diaryRequesterProvider = Provider<DiaryRequester>(
  (ref) => requestDeepSeekRecap,
);
final diaryCandidateRepositoryProvider = Provider<DiaryCandidateRepository>(
  (ref) => FileDiaryCandidateRepository(directory: candidateSupportDirectory),
);
final diaryCandidateClockProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now().toUtc(),
);
final diaryCandidateIdProvider = Provider<String Function()>((ref) {
  final random = Random.secure();
  return () => List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
});

enum DiaryGenerationStatus { idle, pending, success, error }

class DiaryGeneration {
  const DiaryGeneration({
    this.status = DiaryGenerationStatus.idle,
    this.startUtc,
    this.endUtc,
    this.saveDate,
    this.content,
    this.error,
    this.candidateId,
  });
  final DiaryGenerationStatus status;
  final String? startUtc;
  final String? endUtc;
  final String? saveDate;
  final String? content;
  final String? error;
  final String? candidateId;
  bool get isPending => status == DiaryGenerationStatus.pending;
  bool get hasResult => status == DiaryGenerationStatus.success;
  String get rangeLabel =>
      candidateRangeLabel(startUtc ?? '', endUtc ?? '', saveDate ?? '');
}

final diaryGenerationProvider =
    NotifierProvider<DiaryGenerationNotifier, DiaryGeneration>(
      DiaryGenerationNotifier.new,
    );

class DiaryGenerationNotifier extends Notifier<DiaryGeneration> {
  @override
  DiaryGeneration build() => const DiaryGeneration();

  Future<bool> start({
    required String startUtc,
    required String endUtc,
    required String saveDate,
    required String summary,
    required String key,
    required String model,
  }) async {
    if (state.isPending) return false;
    final requester = ref.read(diaryRequesterProvider);
    // Initialize the collection before setting a new success record, so only
    // a genuinely older record can be considered for migration.
    final candidates = ref.read(diaryCandidatesProvider.notifier);
    state = DiaryGeneration(
      status: DiaryGenerationStatus.pending,
      startUtc: startUtc,
      endUtc: endUtc,
      saveDate: saveDate,
    );
    String content;
    try {
      content = await requester(key: key, model: model, summary: summary);
      if (content.trim().isEmpty) {
        throw const AiConnectionFailure('未收到总结内容');
      }
    } on AiConnectionFailure catch (failure) {
      if (ref.mounted) {
        state = DiaryGeneration(
          status: DiaryGenerationStatus.error,
          startUtc: startUtc,
          endUtc: endUtc,
          saveDate: saveDate,
          error: failure.message,
        );
      }
      return true;
    } catch (_) {
      if (ref.mounted) {
        state = DiaryGeneration(
          status: DiaryGenerationStatus.error,
          startUtc: startUtc,
          endUtc: endUtc,
          saveDate: saveDate,
          error: '生成失败，请稍后重试',
        );
      }
      return true;
    }
    if (!ref.mounted) return true;
    // Storage is a separate operation, never another paid-request failure.
    final candidate = candidates.add(
      source: DiaryCandidateSource.ai,
      startUtc: startUtc,
      endUtc: endUtc,
      saveDate: saveDate,
      content: content,
    );
    state = DiaryGeneration(
      status: DiaryGenerationStatus.success,
      startUtc: startUtc,
      endUtc: endUtc,
      saveDate: saveDate,
      content: content,
      candidateId: candidate.id,
    );
    return true;
  }
}

class DiaryCandidates {
  const DiaryCandidates({
    this.items = const {},
    this.loading = true,
    this.loadError,
    this.hasRecoveryIssue = false,
  });
  final Map<String, DiaryCandidate> items;
  final bool loading;
  final String? loadError;
  final bool hasRecoveryIssue;
  List<DiaryCandidate> get ordered {
    final list = items.values.toList();
    list.sort((a, b) {
      final time = b.capturedAtUtc.compareTo(a.capturedAtUtc);
      return time == 0 ? b.id.compareTo(a.id) : time;
    });
    return list;
  }

  DiaryCandidates copyWith({
    Map<String, DiaryCandidate>? items,
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    bool? hasRecoveryIssue,
  }) => DiaryCandidates(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loadError: clearLoadError ? null : (loadError ?? this.loadError),
    hasRecoveryIssue: hasRecoveryIssue ?? this.hasRecoveryIssue,
  );
}

final diaryCandidatesProvider =
    NotifierProvider<DiaryCandidatesNotifier, DiaryCandidates>(
      DiaryCandidatesNotifier.new,
    );

class DiaryCandidatesNotifier extends Notifier<DiaryCandidates> {
  Future<void>? _loading;
  bool _loaded = false;

  @override
  DiaryCandidates build() {
    final legacy = ref.read(diaryGenerationProvider);
    final legacyReceipts = ref.read(diarySaveProvider);
    scheduleMicrotask(() async {
      if (!ref.mounted) return;
      await load();
      if (!ref.mounted || !legacy.hasResult || legacy.candidateId != null) {
        return;
      }
      final start = DateTime.tryParse(legacy.startUtc ?? '');
      final end = DateTime.tryParse(legacy.endUtc ?? '');
      if (start == null || end == null) return;
      final id =
          'legacy-${start.millisecondsSinceEpoch}-${end.millisecondsSinceEpoch}';
      if (state.items.containsKey(id)) return;
      final receipt = legacyReceipts[(legacy.saveDate!, legacy.content!)];
      final entryId = receipt?.entryId?.toString();
      final status = switch (receipt?.status) {
        DiarySaveStatus.saved => CandidatePublishStatus.saved,
        DiarySaveStatus.awaitingVerification when entryId != null =>
          CandidatePublishStatus.awaitingVerification,
        DiarySaveStatus.resultUnknown => CandidatePublishStatus.unknown,
        _ => CandidatePublishStatus.ready,
      };
      final candidate = DiaryCandidate(
        id: id,
        source: DiaryCandidateSource.ai,
        startUtc: legacy.startUtc!,
        endUtc: legacy.endUtc!,
        saveDate: legacy.saveDate!,
        content: legacy.content!,
        capturedAtUtc: ref.read(diaryCandidateClockProvider)().toUtc(),
        // The old record never recorded its completion time.
        generatedAtUtc: null,
        publishStatus: status,
        entryId: entryId,
      );
      replace(candidate);
      unawaited(persist(id));
    });
    return const DiaryCandidates();
  }

  Future<void> ensureLoaded() => _loaded ? Future<void>.value() : load();

  Future<void> load() {
    final running = _loading;
    if (running != null) return running;
    final operation = Future<void>.microtask(_load);
    _loading = operation;
    return operation;
  }

  Future<void> _load() async {
    try {
      // load() queues this callback; the scope may disappear before it starts.
      if (!ref.mounted) return;
      state = state.copyWith(loading: true, clearLoadError: true);
      final result = await ref.read(diaryCandidateRepositoryProvider).load();
      if (!ref.mounted) return;
      final merged = {...state.items};
      for (final candidate in result.candidates) {
        final current = merged[candidate.id];
        if (current == null) {
          merged[candidate.id] = candidate;
        } else if (candidate.revision > current.revision) {
          if (candidate.recoveryBlocked && current.entryId != null) {
            // A damaged newer file is not evidence against an ID already returned
            // in this scope. Keep that receipt and skip the occupied bad revision.
            merged[candidate.id] = current.copyWith(
              revision: candidate.revision + 1,
              persisted: false,
              recoveryBlocked: true,
              storageError: candidate.storageError,
            );
          } else {
            merged[candidate.id] = candidate;
          }
        }
        // Older/equal snapshots never replace a newer in-memory receipt.
        // Their recovery warning remains visible on the collection.
      }
      _loaded = true;
      state = state.copyWith(
        items: Map.unmodifiable(merged),
        loading: false,
        clearLoadError: true,
        hasRecoveryIssue: result.hasRecoveryIssue,
      );
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, loadError: '历史暂时无法读取，请重试');
      }
    } finally {
      _loading = null;
    }
  }

  void replace(DiaryCandidate candidate) {
    if (!ref.mounted) return;
    final current = state.items[candidate.id];
    // An asynchronous caller must never install an older snapshot.
    if (current != null && candidate.revision < current.revision) return;
    state = state.copyWith(
      items: Map.unmodifiable({...state.items, candidate.id: candidate}),
    );
  }

  DiaryCandidate add({
    required DiaryCandidateSource source,
    required String startUtc,
    required String endUtc,
    required String saveDate,
    required String content,
  }) {
    final id = ref.read(diaryCandidateIdProvider)();
    if (!DiaryCandidate.validId(id) || state.items.containsKey(id)) {
      throw StateError('Candidate identity collision');
    }
    final time = ref.read(diaryCandidateClockProvider)().toUtc();
    final candidate = DiaryCandidate(
      id: id,
      source: source,
      startUtc: startUtc,
      endUtc: endUtc,
      saveDate: saveDate,
      content: content,
      capturedAtUtc: time,
      generatedAtUtc: time,
    );
    replace(candidate);
    unawaited(persist(id));
    return candidate;
  }

  Future<bool> persist(String id) async {
    final candidate = state.items[id];
    if (candidate == null) return false;
    try {
      await ref.read(diaryCandidateRepositoryProvider).put(candidate);
      if (!ref.mounted) return false;
      final current = state.items[id];
      if (current?.revision == candidate.revision) {
        replace(current!.copyWith(persisted: true, clearStorageError: true));
      }
      return true;
    } catch (_) {
      if (ref.mounted) {
        final current = state.items[id];
        if (current?.revision == candidate.revision) {
          replace(
            current!.copyWith(
              persisted: false,
              storageError: '尚未保留到本机，内容仍在本次会话',
            ),
          );
        }
      }
      return false;
    }
  }
}

enum DiarySaveStatus { writeFailed, awaitingVerification, saved, resultUnknown }

class DiarySaveReceipt {
  const DiarySaveReceipt({
    required this.date,
    required this.content,
    required this.status,
    this.entryId,
    this.saving = false,
  });
  final String date;
  final String content;
  final Object? entryId;
  final DiarySaveStatus status;
  final bool saving;
}

// Tuple keys remain readable only for a live pre-upgrade record's migration.
typedef DiarySaveKey = (String, String);
final diarySaveProvider =
    NotifierProvider<DiarySaveNotifier, Map<Object, DiarySaveReceipt>>(
      DiarySaveNotifier.new,
    );

class DiarySaveNotifier extends Notifier<Map<Object, DiarySaveReceipt>> {
  final Set<String> _busy = {};
  @override
  Map<Object, DiarySaveReceipt> build() => const {};

  void _receipt(
    DiaryCandidate candidate,
    DiarySaveStatus status, {
    bool saving = false,
  }) {
    if (!ref.mounted) return;
    state = Map.unmodifiable({
      ...state,
      candidate.id: DiarySaveReceipt(
        date: candidate.saveDate,
        content: candidate.content,
        status: status,
        entryId: candidate.entryId,
        saving: saving,
      ),
    });
  }

  DiarySaveStatus _status(DiaryCandidate candidate) {
    if (candidate.publishStatus == CandidatePublishStatus.saved) {
      return DiarySaveStatus.saved;
    }
    if (candidate.entryId != null) return DiarySaveStatus.awaitingVerification;
    if (candidate.recoveryBlocked ||
        candidate.publishStatus == CandidatePublishStatus.appendIntent ||
        candidate.publishStatus == CandidatePublishStatus.unknown) {
      return DiarySaveStatus.resultUnknown;
    }
    return DiarySaveStatus.writeFailed;
  }

  // put() acknowledges its snapshot, not necessarily the current revision.
  // A load can promote the receipt while IO is pending; persist that revision
  // too before continuing, without ever reinstalling the acknowledged snapshot.
  Future<bool> _persistLatest(DiaryCandidatesNotifier assets, String id) async {
    while (ref.mounted) {
      final current = ref.read(diaryCandidatesProvider).items[id];
      if (current == null) return false;
      if (current.persisted) return true;
      if (!await assets.persist(id)) return false;
    }
    return false;
  }

  Future<DiarySaveStatus> saveCandidate(String id) async {
    if (!_busy.add(id)) {
      return state[id]?.status ?? DiarySaveStatus.awaitingVerification;
    }
    final assets = ref.read(diaryCandidatesProvider.notifier);
    var result = DiarySaveStatus.writeFailed;
    try {
      await assets.ensureLoaded();
      if (!ref.mounted) return result;
      final initial = ref.read(diaryCandidatesProvider).items[id];
      if (initial == null) return result;
      var candidate = initial;
      _receipt(candidate, DiarySaveStatus.awaitingVerification, saving: true);
      if (candidate.publishStatus == CandidatePublishStatus.saved) {
        await _persistLatest(assets, id);
        if (!ref.mounted) return result;
        return result = _status(ref.read(diaryCandidatesProvider).items[id]!);
      }
      final api = ref.read(apiProvider);
      if (candidate.entryId == null &&
          (candidate.recoveryBlocked ||
              candidate.publishStatus == CandidatePublishStatus.unknown ||
              candidate.publishStatus == CandidatePublishStatus.appendIntent)) {
        // There is no returned ID. Text equality is not proof of ownership.
        try {
          api
              .getDiaryEntriesDetailed(
                start: candidate.saveDate,
                end: candidate.saveDate,
              )
              .where(
                (entry) =>
                    entry.date == candidate.saveDate &&
                    entry.content == candidate.content &&
                    entry.status == 'published',
              )
              .toList();
        } catch (_) {}
        candidate = ref.read(diaryCandidatesProvider).items[id]!;
        // A synchronous API callback may also have advanced the receipt.
        if (candidate.entryId != null) return result = _status(candidate);
        candidate = candidate.copyWith(
          revision: candidate.revision + 1,
          publishStatus: CandidatePublishStatus.unknown,
          persisted: false,
        );
        assets.replace(candidate);
        await assets.persist(id);
        if (!ref.mounted) return result;
        return result = _status(ref.read(diaryCandidatesProvider).items[id]!);
      }
      if (candidate.entryId == null) {
        // Record intent BEFORE calling the independent database append.
        candidate = ref.read(diaryCandidatesProvider).items[id]!;
        final intent = candidate.copyWith(
          revision: candidate.revision + 1,
          publishStatus: CandidatePublishStatus.appendIntent,
          persisted: false,
          clearStorageError: true,
        );
        assets.replace(intent);
        final intentStored = await assets.persist(id);
        if (!ref.mounted) return result;
        candidate = ref.read(diaryCandidatesProvider).items[id]!;
        final ownsIntent =
            candidate.revision == intent.revision &&
            candidate.entryId == null &&
            !candidate.recoveryBlocked &&
            candidate.publishStatus == CandidatePublishStatus.appendIntent;
        if (!intentStored) {
          if (ownsIntent) {
            // DB was never called and no intervening recovery changed intent.
            candidate = candidate.copyWith(
              revision: candidate.revision + 1,
              publishStatus: CandidatePublishStatus.ready,
              persisted: false,
              storageError: '尚未保留到本机，内容仍在本次会话',
            );
            assets.replace(candidate);
          }
          return result = _status(candidate);
        }
        if (candidate.entryId == null && !ownsIntent) {
          // A newer recovered intent/unknown snapshot is not ours to append.
          return result = _status(candidate);
        }
        if (candidate.entryId == null) {
          Object returnedId;
          try {
            returnedId = api.addDiaryEntry(
              date: candidate.saveDate,
              content: candidate.content,
            );
          } catch (_) {
            // Append may have happened before the exception. Never reset ready.
            candidate = ref.read(diaryCandidatesProvider).items[id]!;
            candidate = candidate.copyWith(
              revision: candidate.revision + 1,
              publishStatus: candidate.entryId == null
                  ? CandidatePublishStatus.unknown
                  : candidate.publishStatus,
              persisted: false,
            );
            assets.replace(candidate);
            await assets.persist(id);
            if (!ref.mounted) return result;
            return result = _status(
              ref.read(diaryCandidatesProvider).items[id]!,
            );
          }
          candidate = ref.read(diaryCandidatesProvider).items[id]!;
          candidate = candidate.copyWith(
            revision: candidate.revision + 1,
            publishStatus:
                candidate.publishStatus == CandidatePublishStatus.saved
                ? CandidatePublishStatus.saved
                : CandidatePublishStatus.awaitingVerification,
            entryId: candidate.entryId ?? returnedId.toString(),
            persisted: false,
          );
          assets.replace(candidate); // Retain the ID before any further IO.
        }
      }
      if (!await _persistLatest(assets, id)) {
        if (!ref.mounted) return result;
        return result = _status(ref.read(diaryCandidatesProvider).items[id]!);
      }
      if (!ref.mounted) return result;
      candidate = ref.read(diaryCandidatesProvider).items[id]!;
      if (candidate.publishStatus == CandidatePublishStatus.saved ||
          candidate.entryId == null) {
        return result = _status(candidate);
      }
      try {
        final entries = api.getDiaryEntriesDetailed(
          start: candidate.saveDate,
          end: candidate.saveDate,
        );
        if (!entries.any(
          (entry) =>
              entry.id.toString() == candidate.entryId &&
              entry.date == candidate.saveDate &&
              entry.content == candidate.content &&
              entry.status == 'published',
        )) {
          return result = DiarySaveStatus.awaitingVerification;
        }
      } catch (_) {
        return result = DiarySaveStatus.awaitingVerification;
      }
      candidate = ref.read(diaryCandidatesProvider).items[id]!;
      candidate = candidate.copyWith(
        revision: candidate.revision + 1,
        publishStatus: CandidatePublishStatus.saved,
        persisted: false,
      );
      assets.replace(candidate);
      await _persistLatest(assets, id);
      if (!ref.mounted) return result;
      ref.invalidate(calendarDataProvider);
      return result = _status(ref.read(diaryCandidatesProvider).items[id]!);
    } catch (_) {
      if (ref.mounted) {
        final candidate = ref.read(diaryCandidatesProvider).items[id];
        if (candidate != null) result = _status(candidate);
      }
      return result;
    } finally {
      _busy.remove(id);
      if (ref.mounted) {
        final candidate = ref.read(diaryCandidatesProvider).items[id];
        if (candidate != null) _receipt(candidate, result);
      }
    }
  }
}
