import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browsing/domain/diary_candidate.dart';
import '../data/diary_entry_metadata_store.dart';
import '../domain/diary_entry_metadata.dart';

final diaryEntryMetadataStoreProvider = Provider<DiaryEntryMetadataStore>(
  (ref) => FileDiaryEntryMetadataStore(),
);

class DiaryEntryMetadataView {
  const DiaryEntryMetadataView({
    required this.value,
    this.loaded = false,
    this.loading = false,
    this.blocked = false,
    this.dirty = false,
    this.error,
  });
  final DiaryEntryMetadata value;
  final bool loaded, loading, blocked, dirty;
  final String? error;
}

final diaryEntryMetadataProvider =
    NotifierProvider.family<
      DiaryEntryMetadataNotifier,
      DiaryEntryMetadataView,
      DiaryEntryKey
    >(DiaryEntryMetadataNotifier.new);

class DiaryEntryMetadataNotifier extends Notifier<DiaryEntryMetadataView> {
  DiaryEntryMetadataNotifier(this.key);
  final DiaryEntryKey key;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  // Confirmed durable content is a CAS base, not the working revision counter.
  DiaryEntryMetadata? _confirmed;
  final _attempted = <int, DiaryEntryMetadata>{};
  int _generation = 0;

  static bool _same(DiaryEntryMetadata? a, DiaryEntryMetadata? b) =>
      jsonEncode(a?.toJson()) == jsonEncode(b?.toJson());

  void _confirm(DiaryEntryMetadata value) {
    if (_confirmed == null || value.revision >= _confirmed!.revision) {
      _confirmed = value;
      _attempted.removeWhere((revision, _) => revision <= value.revision);
    }
  }

  @override
  DiaryEntryMetadataView build() {
    ref.onDispose(() => _generation++);
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(reload());
    });
    return DiaryEntryMetadataView(value: DiaryEntryMetadata(key: key));
  }

  Future<void> ensureLoaded() => state.loaded ? Future.value() : reload();
  Future<void> reload() {
    final running = _loading;
    if (running != null) return running;
    final generation = _generation;
    final operation = Future<void>.microtask(() async {
      if (!ref.mounted || generation != _generation) return;
      state = DiaryEntryMetadataView(
        value: state.value,
        loaded: state.loaded,
        loading: true,
        blocked: state.blocked,
        dirty: state.dirty,
        error: state.error,
      );
      try {
        final readBase = _confirmed;
        final result = await ref
            .read(diaryEntryMetadataStoreProvider)
            .load(key);
        if (!ref.mounted || generation != _generation) return;
        final current = state;
        final incoming = result.value;
        final stale = !_same(readBase, _confirmed) && _same(incoming, readBase);
        final ownReceipt =
            incoming != null && _same(incoming, _attempted[incoming.revision]);
        var conflict = false;
        var value = current.value;
        var dirty = current.dirty;
        if (result.blocked &&
            !current.dirty &&
            incoming != null &&
            incoming.revision >= value.revision) {
          // A valid older revision may remain visible beneath damaged/future
          // history. Showing it is not a new writable CAS acknowledgement.
          value = incoming;
        }
        if (!result.blocked && !stale) {
          if (current.dirty) {
            // A higher local counter is not evidence that external tags may be
            // overwritten. Only the exact confirmed base or a full attempted
            // snapshot receipt may authorize further writes.
            if (_same(incoming, _confirmed)) {
              // The expected base is unchanged.
            } else if (ownReceipt &&
                (_confirmed == null ||
                    incoming.revision > _confirmed!.revision)) {
              _confirm(incoming);
              dirty = !_same(current.value, incoming);
            } else {
              conflict = true;
            }
          } else if (incoming == null) {
            conflict = _confirmed != null;
          } else if (_confirmed == null ||
              incoming.revision > _confirmed!.revision) {
            _confirm(incoming);
            value = incoming;
          } else if (!_same(incoming, _confirmed)) {
            conflict = true;
          }
        }
        final blocked = result.blocked || conflict || stale && current.blocked;
        state = DiaryEntryMetadataView(
          value: value,
          loaded: true,
          dirty: dirty,
          blocked: blocked,
          error: blocked ? '日记元数据历史需要核对，仅可读取；本地修改已保留，不会覆盖已有版本' : null,
        );
      } catch (_) {
        if (ref.mounted && generation == _generation) {
          state = DiaryEntryMetadataView(
            value: state.value,
            loaded: true,
            dirty: state.dirty,
            blocked: true,
            error: '日记元数据暂时无法读取，请重试读取',
          );
        }
      } finally {
        if (generation == _generation) _loading = null;
      }
    });
    _loading = operation;
    return operation;
  }

  List<String>? _promotedTags;

  /// First promotion may only claim a pristine unknown entry. A later user's
  /// tags/source revision is never silently replaced by a delayed publication.
  Future<bool> promoteHandwrittenTags(Iterable<String> values) async {
    final tags = normalizedDiaryTags(values);
    await ensureLoaded();
    if (!ref.mounted || state.blocked) return false;
    bool sameTags(List<String> a, List<String> b) =>
        a.length == b.length &&
        !List.generate(a.length, (i) => a[i] != b[i]).contains(true);
    final current = state.value;
    if (current.source == DiaryEntrySource.handwritten &&
        sameTags(current.tags, tags))
      return retrySave();
    if (_promotedTags != null) {
      if (!sameTags(_promotedTags!, tags) ||
          current.source != DiaryEntrySource.handwritten ||
          !sameTags(current.tags, tags))
        return false;
    } else {
      if (current.revision != 0 ||
          current.source != DiaryEntrySource.unknown ||
          current.tags.isNotEmpty)
        return false;
      _promotedTags = tags;
      _change(
        current.copyWith(source: DiaryEntrySource.handwritten, tags: tags),
      );
    }
    return retrySave();
  }

  Future<bool> recordHandwritten() async {
    await ensureLoaded();
    if (!ref.mounted || state.blocked) return false;
    if (state.value.source != DiaryEntrySource.unknown &&
        state.value.source != DiaryEntrySource.handwritten) {
      return false;
    }
    if (state.value.source == DiaryEntrySource.unknown) {
      _change(state.value.copyWith(source: DiaryEntrySource.handwritten));
    }
    return retrySave();
  }

  Future<bool> setTags(Iterable<String> tags) async {
    final normalized = normalizedDiaryTags(tags);
    await ensureLoaded();
    if (!ref.mounted || state.blocked) return false;
    if (normalized.length != state.value.tags.length ||
        List.generate(
          normalized.length,
          (i) => normalized[i] == state.value.tags[i],
        ).contains(false)) {
      _change(state.value.copyWith(tags: normalized));
    }
    return retrySave();
  }

  void _change(DiaryEntryMetadata value) {
    state = DiaryEntryMetadataView(
      value: value.copyWith(revision: state.value.revision + 1),
      loaded: true,
      dirty: true,
    );
  }

  Future<bool> retrySave() async {
    await ensureLoaded();
    if (!ref.mounted || state.blocked) return false;
    final generation = _generation;
    final operation = _writes.then((_) async {
      if (!ref.mounted ||
          generation != _generation ||
          state.blocked ||
          !state.dirty) {
        return;
      }
      // Select the current snapshot when the queued write actually starts.
      final snapshot = state.value;
      _attempted[snapshot.revision] = snapshot;
      try {
        await ref
            .read(diaryEntryMetadataStoreProvider)
            .put(snapshot, expectedRevision: _confirmed?.revision);
        if (!ref.mounted || generation != _generation) return;
        _confirm(snapshot);
        final current = state;
        state = DiaryEntryMetadataView(
          value: current.value,
          loaded: true,
          dirty: current.value.revision != snapshot.revision,
          blocked: current.blocked,
          error: current.value.revision == snapshot.revision
              ? null
              : current.error,
        );
      } catch (error) {
        if (!ref.mounted || generation != _generation) return;
        final current = state;
        // A failed old write cannot mark a newer acknowledged snapshot dirty.
        if (current.dirty || error is DiaryMetadataConflict) {
          state = DiaryEntryMetadataView(
            value: current.value,
            loaded: true,
            dirty: current.dirty,
            blocked: current.blocked || error is DiaryMetadataConflict,
            error: current.blocked
                ? current.error
                : error is DiaryMetadataConflict
                ? '元数据历史已改变，修改仍在；请重试读取核对，不会覆盖已有版本'
                : '来源或标签尚未保存到本机，可仅重试元数据',
          );
        }
      }
    });
    _writes = operation;
    await operation;
    return ref.mounted && !state.dirty && !state.blocked;
  }
}

/// Published identity is supplied by the entry, never inferred from its text.
DiaryEntrySource diaryEntrySource(
  DiaryEntryKey key,
  DiaryEntryMetadataView view,
  Iterable<DiaryCandidate> candidates,
) {
  if (view.blocked) return DiaryEntrySource.unknown;
  final evidence = <DiaryEntrySource>{};
  if (view.value.source != DiaryEntrySource.unknown) {
    evidence.add(view.value.source);
  }
  var damaged = false;
  for (final candidate in candidates) {
    if (candidate.entryId != key.entryId.toString() ||
        candidate.saveDate != key.date) {
      continue;
    }
    if (candidate.recoveryBlocked ||
        (candidate.publishStatus != CandidatePublishStatus.saved &&
            candidate.publishStatus !=
                CandidatePublishStatus.awaitingVerification)) {
      damaged = true;
      continue;
    }
    evidence.add(
      candidate.source == DiaryCandidateSource.local
          ? DiaryEntrySource.local
          : DiaryEntrySource.ai,
    );
  }
  return !damaged && evidence.length == 1
      ? evidence.single
      : DiaryEntrySource.unknown;
}
