import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import '../../../core/refresh/data_refresh_policy.dart';
import '../../dashboard/domain/diary_entry_metadata.dart';
import '../../dashboard/data/diary_draft_tags_store.dart';
import '../../dashboard/data/diary_entry_metadata_store.dart'
    show DiaryMetadataConflict;
import '../../dashboard/providers/diary_entry_metadata_provider.dart';

/// Shared calendar data (images / diary days / entries),
/// loaded once per year for the calendar grid, diary image grid and
/// entries feed. Consumed by both the 日历日记 tab and the overview
/// carousel page.
class CalendarData {
  const CalendarData({
    required this.images,
    required this.entryImages,
    required this.diaryDays,
    required this.entries,
  });

  final Map<String, List<String>> images; // date -> image paths (markers)
  final Map<int, List<String>> entryImages; // entry_id -> image paths (album)
  final Set<String> diaryDays; // dates with non-empty journal
  final List<DiaryEntryDto> entries; // published entries, newest first
}

String calFmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

typedef CalendarDataLoader = FutureOr<CalendarData> Function(int year);
final calendarYearClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

class CalendarYearNotifier extends Notifier<int> {
  Timer? _timer;
  @override
  int build() {
    final clock = ref.watch(calendarYearClockProvider);
    final interval = ref.watch(dataRefreshPolicyProvider).interval;
    void check() {
      if (ref.mounted && state != clock().year) state = clock().year;
    }

    void start() {
      _timer?.cancel();
      if (interval > Duration.zero)
        _timer = Timer.periodic(interval, (_) => check());
    }

    start();
    ref.onCancel(() => _timer?.cancel());
    ref.onResume(() {
      scheduleMicrotask(check);
      start();
    });
    ref.onDispose(() => _timer?.cancel());
    return clock().year;
  }
}

final calendarYearProvider = NotifierProvider<CalendarYearNotifier, int>(
  CalendarYearNotifier.new,
);

final calendarDataLoaderProvider = Provider<CalendarDataLoader>((ref) {
  final api = ref.watch(apiProvider);
  return (year) => loadCalendarYear(api, year);
});

/// Scope cache is the non-autoDispose FutureProvider itself. Explicit invalidate
/// really replaces this generation; old Futures cannot populate the next one.
final calendarDataProvider = FutureProvider<CalendarData>((ref) async {
  final year = ref.watch(calendarYearProvider);
  return await ref.watch(calendarDataLoaderProvider)(year);
});

CalendarData loadCalendarYear(TimeTraceApi api, int year) {
  // Cold methods below are synchronous Rust bridge calls, not background work.
  final now = DateTime(year);

  // Image paths for the whole year + per-entry album map
  final detailedImgs = api.getDiaryImagesDetailed(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  final images = <String, List<String>>{};
  final entryImages = <int, List<String>>{};
  for (final (date, entryId, path) in detailedImgs) {
    images.putIfAbsent(date, () => []).add(path);
    if (entryId != null) {
      entryImages.putIfAbsent(entryId, () => []).add(path);
    }
  }

  // Diary days (markers) + entries feed with ids
  final diaryEntries = api.getDiaryEntries(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  final diaryDays = diaryEntries
      .where((e) => e.$2.isNotEmpty)
      .map((e) => e.$1)
      .toSet();
  final detailed = api.getDiaryEntriesDetailed(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  // Only published entries in the feed; drafts stay in the editor.
  final published = detailed.where((e) => e.status == 'published').toList();
  // Cap to the most recent 100 (memory: avoid holding long texts)
  final capped = published.length > 100 ? published.sublist(0, 100) : published;

  return CalendarData(
    images: images,
    entryImages: entryImages,
    diaryDays: diaryDays,
    entries: capped,
  );
}

/// The selected day's draft content (autosaved, not yet published).
final diaryDraftProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  date,
) async {
  final api = ref.read(apiProvider);
  return api.getDiaryDraft(date: date);
});

final diaryDraftTagsStoreProvider = Provider<DiaryDraftTagsStore>(
  (ref) => FileDiaryDraftTagsStore(),
);

/// Draft memory belongs to the application scope, rather than an editor widget.
final diaryComposerStoreProvider = Provider<DiaryComposerStore>((ref) {
  var alive = true;
  Timer? notification;
  final dates = <String>{};
  final store = DiaryComposerStore(
    api: ref.read(apiProvider),
    tagsStore: ref.read(diaryDraftTagsStoreProvider),
    onChanged: () {
      if (alive) ref.notifyListeners();
    },
    onPromoteTags: (date, id, tags) async {
      if (!alive) throw StateError('Disposed composer');
      final saved = await ref
          .read(diaryEntryMetadataProvider(DiaryEntryKey(date, id)).notifier)
          .promoteHandwrittenTags(tags);
      if (!saved) throw StateError('Tag promotion not acknowledged');
    },
    onPublished: (date, id) async {
      if (!alive) return;
      final saved = await ref
          .read(diaryEntryMetadataProvider(DiaryEntryKey(date, id)).notifier)
          .recordHandwritten();
      if (!saved) throw StateError('Metadata not acknowledged');
    },
    onPersisted: (date) {
      if (!alive) return;
      dates.add(date);
      notification ??= Timer(const Duration(milliseconds: 250), () {
        notification = null;
        if (!alive) return;
        for (final date in dates) {
          ref.invalidate(diaryDraftProvider(date));
        }
        dates.clear();
        ref.invalidate(calendarDataProvider);
      });
    },
  );
  ref.onDispose(() {
    alive = false;
    notification?.cancel();
    store.dispose();
  });
  return store;
});

typedef DiaryDraftWriter = FutureOr<void> Function(String date, String text);

typedef DiaryTagPromotion =
    FutureOr<void> Function(String date, int id, List<String> tags);

typedef DiaryPublishedObserver = FutureOr<void> Function(String date, int id);

class DiaryComposerStore {
  DiaryComposerStore({
    required this.api,
    this.onPersisted,
    this.writeDraft,
    this.onPublished,
    this.onPromoteTags,
    this.onChanged,
    DiaryDraftTagsStore? tagsStore,
  }) : tagsStore = tagsStore ?? MemoryDiaryDraftTagsStore();

  final DiaryDraftTagsStore tagsStore;
  final DiaryTagPromotion? onPromoteTags;
  final void Function()? onChanged;
  final TimeTraceApi api;
  final void Function(String date)? onPersisted;
  final DiaryDraftWriter? writeDraft;
  final DiaryPublishedObserver? onPublished;
  final Map<String, DiaryComposerSession> _sessions = {};

  void dispose() {
    for (final session in _sessions.values) {
      session._disposed = true;
    }
  }

  DiaryComposerSession read(String date) {
    final previous = _sessions[date];
    if (previous != null &&
        (!previous.retired ||
            previous.hasPendingImages ||
            previous.hasPendingReceipt)) {
      return previous;
    }
    final session = DiaryComposerSession(
      date: date,
      api: api,
      writeDraft: writeDraft,
      onPersisted: onPersisted,
      onPublished: onPublished,
      onPromoteTags: onPromoteTags,
      tagsStore: tagsStore,
      onChanged: onChanged,
    );
    // A successful publish/discard already removed this date's old draft.
    // A stale provider result must not seed it back into the next session.
    if (previous != null) {
      session.seed(null);
      session._imagesSeeded = true;
    }
    return _sessions[date] = session;
  }
}

class DiaryComposerSession {
  DiaryComposerSession({
    required this.date,
    required this.api,
    this.writeDraft,
    this.onPersisted,
    this.onPublished,
    this.onPromoteTags,
    this.onChanged,
    DiaryDraftTagsStore? tagsStore,
    String Function()? tagIdentity,
  }) : tagsStore = tagsStore ?? MemoryDiaryDraftTagsStore() {
    _tagValue = DiaryDraftTagSnapshot(
      date: date,
      generation: (tagIdentity ?? diaryDraftTagIdentity)(),
    );
  }

  final DiaryDraftTagsStore tagsStore;
  final DiaryTagPromotion? onPromoteTags;
  final void Function()? onChanged;
  final String date;
  final TimeTraceApi api;
  final Object token = Object();
  final DiaryDraftWriter? writeDraft;
  final void Function(String date)? onPersisted;
  final DiaryPublishedObserver? onPublished;
  String text = '';
  int revision = 0;
  int savedRevision = 0;
  bool seeded = false;
  bool retired = false;
  bool publishing = false;
  String? error;
  int? publishedEntryId;
  String? metadataError;
  Future<void>? _metadataRecording;
  final List<String> staged = [];
  bool _imagesSeeded = false;
  bool _disposed = false;
  Future<void>? _saving;

  bool get dirty => revision != savedRevision;
  bool get acceptsImages =>
      !_disposed &&
      !retired &&
      !publishing &&
      _tagValue.phase == DiaryDraftTagPhase.draft;
  bool get hasPendingImages => publishedEntryId != null && staged.isNotEmpty;

  late DiaryDraftTagSnapshot _tagValue;
  DiaryDraftTagSnapshot? _tagConfirmed;
  final _tagAttempted = <int, DiaryDraftTagSnapshot>{};
  Future<void>? _tagLoading;
  Future<void> _tagWrites = Future.value();
  bool tagsLoaded = false, tagsBlocked = false;
  String? tagsError;
  bool _uninvokedIntent = false, _invoked = false;
  bool _metadataConfirmed = false;
  bool _recoveringReceipt = false;
  List<String> get tags => _tagValue.tags;
  DiaryDraftTagSnapshot get tagSnapshot => _tagValue;
  bool get tagsDirty =>
      tagsLoaded && _tagValue.revision > (_tagConfirmed?.revision ?? 0);
  bool get hasPendingReceipt =>
      _tagValue.phase == DiaryDraftTagPhase.publishPending ||
      _tagValue.phase == DiaryDraftTagPhase.returnedId ||
      metadataError != null ||
      publishedEntryId != null && tagsDirty ||
      tagsError != null && publishedEntryId != null;
  bool get canEditTags =>
      !_disposed &&
      !retired &&
      !publishing &&
      !tagsBlocked &&
      _tagValue.phase == DiaryDraftTagPhase.draft;
  bool get publishUnknown =>
      _tagValue.phase == DiaryDraftTagPhase.publishPending && !_uninvokedIntent;
  void _changed() {
    if (!_disposed) onChanged?.call();
  }

  Future<void> ensureTagsLoaded() =>
      _disposed || tagsLoaded ? Future.value() : (_tagLoading ??= _loadTags());
  Future<void> _loadTags() async {
    if (_disposed) return;
    try {
      final base = _tagConfirmed;
      final incoming = await tagsStore.load(date);
      if (_disposed) return;
      if (incoming.blocked) {
        tagsBlocked = true;
        tagsError = '草稿标签历史需要核对，仅可读取';
      } else {
        final value = incoming.value;
        final stale =
            !sameDiaryDraftTags(base, _tagConfirmed) &&
            sameDiaryDraftTags(value, base);
        if (stale) {
          // This read belongs to the old confirmed base, not the latest ACK.
        } else if (tagsLoaded && tagsDirty) {
          if (!sameDiaryDraftTags(value, _tagConfirmed) &&
              !sameDiaryDraftTags(value, _tagAttempted[value?.revision])) {
            tagsBlocked = true;
            tagsError = '标签历史已改变，本地修改保留，请核对';
          } else if (value != null &&
              sameDiaryDraftTags(value, _tagAttempted[value.revision])) {
            _tagConfirmed = value;
          }
        } else if (_tagConfirmed != null &&
            (value == null ||
                value.revision < _tagConfirmed!.revision ||
                value.revision == _tagConfirmed!.revision &&
                    !sameDiaryDraftTags(value, _tagConfirmed))) {
          tagsBlocked = true;
          tagsError = '标签历史已改变，请核对';
        } else if (value == null) {
          tagsBlocked = false;
          tagsError = null;
        } else {
          tagsBlocked = false;
          tagsError = null;
          _tagConfirmed = value;
          if (value.phase == DiaryDraftTagPhase.complete ||
              value.phase == DiaryDraftTagPhase.discarded) {
            _tagValue = DiaryDraftTagSnapshot(
              date: date,
              generation: _tagValue.generation,
              revision: value.revision,
            );
          } else {
            _tagValue = value;
            if (value.phase == DiaryDraftTagPhase.publishPending) {
              tagsBlocked = true;
              tagsError = '发表凭据需要人工核对，不会再次发表';
              _uninvokedIntent = false;
            } else if (value.phase == DiaryDraftTagPhase.returnedId) {
              _recoveringReceipt = true;
              retired = true;
              publishedEntryId = value.entryId;
              metadataError = '文字已发表，标签与凭据待完成';
            }
          }
        }
      }
      tagsLoaded = true;
    } catch (_) {
      if (!_disposed) {
        tagsLoaded = true;
        tagsBlocked = true;
        tagsError = '草稿标签无法读取，请重试读取';
      }
    }
    _changed();
  }

  Future<void> reloadTags() async {
    if (_disposed) return;
    _tagLoading = _loadTags();
    await _tagLoading;
  }

  void _tagChange(DiaryDraftTagSnapshot value) {
    _tagValue = value;
    tagsError = null;
    _changed();
  }

  Future<bool> setTags(Iterable<String> values) async {
    final normalized = normalizedDiaryTags(values);
    await ensureTagsLoaded();
    if (!canEditTags) return false;
    if (tags.length != normalized.length ||
        List.generate(
          tags.length,
          (i) => tags[i] != normalized[i],
        ).contains(true)) {
      _tagChange(
        _tagValue.copyWith(revision: _tagValue.revision + 1, tags: normalized),
      );
    }
    return retryTags();
  }

  Future<bool> retryTags() async {
    await ensureTagsLoaded();
    if (_disposed || tagsBlocked) return false;
    final operation = _tagWrites.then((_) async {
      if (_disposed || tagsBlocked || !tagsDirty) return;
      final snapshot = _tagValue;
      _tagAttempted[snapshot.revision] = snapshot;
      try {
        await tagsStore.put(
          snapshot,
          expectedRevision: _tagConfirmed?.revision,
        );
        if (_disposed) return;
        if (_tagConfirmed == null ||
            snapshot.revision >= _tagConfirmed!.revision)
          _tagConfirmed = snapshot;
        if (sameDiaryDraftTags(snapshot, _tagValue)) tagsError = null;
      } catch (error) {
        if (_disposed) return;
        tagsBlocked = tagsBlocked || error is DiaryMetadataConflict;
        tagsError = error is DiaryMetadataConflict
            ? '标签历史有冲突，修改已保留，请核对'
            : '标签或发表凭据未保存，可重试';
      }
      _changed();
    });
    _tagWrites = operation;
    await operation;
    if (!_disposed &&
        !tagsBlocked &&
        !tagsDirty &&
        _tagValue.phase == DiaryDraftTagPhase.discarded) {
      retired = true;
      text = '';
      savedRevision = revision;
      error = null;
    }
    return !_disposed && !tagsBlocked && !tagsDirty;
  }

  Future<bool> _saveReturnedReceipt() async {
    if (publishedEntryId == null) return false;
    if (_tagValue.phase == DiaryDraftTagPhase.publishPending) {
      _tagChange(
        _tagValue.copyWith(
          revision: _tagValue.revision + 1,
          phase: DiaryDraftTagPhase.returnedId,
          entryId: publishedEntryId,
        ),
      );
    }
    return retryTags();
  }

  Future<void> _completeReceipt() async {
    if (_recoveringReceipt && !_imagesSeeded) {
      metadataError = '文字已发表，图片状态待读取后核对';
      return;
    }
    if (_disposed ||
        !_metadataConfirmed ||
        staged.isNotEmpty ||
        metadataError != null ||
        publishedEntryId == null ||
        _tagValue.phase != DiaryDraftTagPhase.returnedId)
      return;
    _tagChange(
      _tagValue.copyWith(
        revision: _tagValue.revision + 1,
        phase: DiaryDraftTagPhase.complete,
      ),
    );
    await retryTags();
  }

  void seed(String? draft) {
    if (seeded || retired) return;
    if (revision == 0) text = draft ?? '';
    seeded = true;
  }

  void seedImages(CalendarData? data) {
    if (_imagesSeeded || data == null || retired && publishedEntryId == null)
      return;
    final linked = data.entryImages.values.expand((paths) => paths).toSet();
    for (final path in data.images[date] ?? const <String>[]) {
      if (!linked.contains(path) && !staged.contains(path)) staged.add(path);
    }
    _imagesSeeded = true;
  }

  void updateText(String value) {
    if (_disposed ||
        retired ||
        publishing ||
        _tagValue.phase != DiaryDraftTagPhase.draft ||
        text == value)
      return;
    text = value;
    revision++;
  }

  void addImage(String path) {
    if (!acceptsImages) return;
    api.addDiaryImage(date: date, path: path);
    if (!staged.contains(path)) staged.add(path);
    onPersisted?.call(date);
  }

  bool removeImage(String path) {
    if (!acceptsImages || !staged.contains(path)) return false;
    try {
      api.removeDiaryImage(path: path);
    } catch (_) {
      error = '图片未移除，请重试';
      return false;
    }
    staged.remove(path);
    error = null;
    onPersisted?.call(date);
    return true;
  }

  Future<void> flush() async {
    // Starting text persistence remains synchronous for the 900ms editor and
    // publication barrier. Tags have their own serialized durable queue.
    if (_disposed) return;
    unawaited(ensureTagsLoaded());
    if (retired || publishing || !dirty) return;
    final running = _saving;
    if (running != null) {
      await running;
      return flush();
    }
    final savingRevision = revision;
    final savingText = text;
    final operation = Future<void>.sync(() {
      final writer = writeDraft;
      if (writer != null) return writer(date, savingText);
      api.saveDiaryDraft(date: date, content: savingText);
    });
    _saving = operation;
    try {
      await operation;
      if (_disposed) return;
      if (!retired) savedRevision = savingRevision;
      error = null;
      onPersisted?.call(date);
    } catch (_) {
      if (!_disposed) {
        error = '草稿未保存，可继续编辑后重试';
      }
      rethrow;
    } finally {
      if (identical(_saving, operation)) _saving = null;
    }
  }

  Future<void> publish() async {
    if (_disposed ||
        publishing ||
        (retired && !hasPendingImages && !hasPendingReceipt))
      return;
    if (text.trim().isEmpty && publishedEntryId == null) return;
    publishing = true;
    try {
      // A draft write that started earlier must finish before promotion.
      final running = _saving;
      if (running != null) {
        try {
          await running;
        } catch (_) {
          // Publishing the in-memory text is still possible after save failure.
        }
      }
      if (_disposed) return;
      await ensureTagsLoaded();
      if (_disposed) return;
      if (publishedEntryId == null) {
        if (tagsBlocked ||
            _invoked ||
            (_tagValue.phase != DiaryDraftTagPhase.draft && !_uninvokedIntent))
          throw StateError('Publish intent requires verification');
        if (_tagValue.phase == DiaryDraftTagPhase.draft) {
          _uninvokedIntent = true;
          _tagChange(
            _tagValue.copyWith(
              revision: _tagValue.revision + 1,
              phase: DiaryDraftTagPhase.publishPending,
              intent: '${_tagValue.generation}_${_tagValue.revision + 1}',
            ),
          );
        }
        if (!await retryTags() || _disposed)
          throw StateError('Publish intent not acknowledged');
        _uninvokedIntent = false;
        _invoked = true;
        final returned = api.publishDiary(date: date, content: text);
        if (returned < 1) throw StateError('Invalid returned diary ID');
        publishedEntryId = returned;
        // Retire immediately after text succeeds, before image association.
        retired = true;
        savedRevision = revision;
        // Independent sidecar IO must never turn a returned ID into a failed
        // publish or repeat the database append/image promotion.
        unawaited(retryMetadata());
      }
      for (final path in List<String>.of(staged)) {
        api.setDiaryImageEntry(path: path, entryId: publishedEntryId!);
        staged.remove(path);
      }
      text = '';
      error = null;
      if (onPromoteTags == null && onPublished == null) await retryMetadata();
      await _completeReceipt();
    } catch (_) {
      error = publishedEntryId == null
          ? (_invoked || publishUnknown
                ? '发表结果需要人工核对，内容和标签保留，不会再次发表'
                : '发表凭据未保存，内容和标签保留，请重试')
          : '文字已发布，图片未全部关联，请重试';
      rethrow;
    } finally {
      publishing = false;
      onPersisted?.call(date);
    }
  }

  Future<void> retryMetadata() {
    final id = publishedEntryId;
    if (_disposed || id == null) return Future.value();
    final running = _metadataRecording;
    if (running != null) return running;
    final operation = Future<void>.sync(() async {
      try {
        if (!await _saveReturnedReceipt())
          throw StateError('Receipt not acknowledged');
        if (_disposed) return;
        if (!_metadataConfirmed) {
          final promotion = onPromoteTags;
          if (promotion != null)
            await promotion(date, id, tags);
          else if (onPublished != null)
            await onPublished!(date, id);
        }
        if (_disposed) return;
        metadataError = null;
        _metadataConfirmed = true;
        await _completeReceipt();
      } catch (_) {
        if (!_disposed) metadataError = '文字已发布，元数据未保存，可单独重试';
      }
      _changed();
    });
    _metadataRecording = operation;
    return operation.whenComplete(() {
      if (identical(_metadataRecording, operation)) _metadataRecording = null;
    });
  }

  Future<void> discard() async {
    await ensureTagsLoaded();
    if (_tagValue.phase == DiaryDraftTagPhase.discarded && !_disposed) {
      if (await retryTags()) {
        retired = true;
        text = '';
        savedRevision = revision;
        error = null;
      } else
        throw StateError('Discard receipt not acknowledged');
      return;
    }
    if (tagsBlocked || _tagValue.phase != DiaryDraftTagPhase.draft) {
      tagsError = '发表凭据需核对，不能放弃或重新发表';
      _changed();
      return;
    }
    if (_disposed || retired || publishing) return;
    publishing = true;
    try {
      final running = _saving;
      if (running != null) {
        try {
          await running;
        } catch (_) {}
      }
      if (_disposed) return;
      final entries = api.getDiaryEntriesDetailed(start: date, end: date);
      for (final entry in entries) {
        if (entry.status == 'draft' && entry.date == date) {
          api.deleteDiaryEntry(id: entry.id);
        }
      }
      for (final path in List<String>.of(staged)) {
        api.removeDiaryImage(path: path);
        staged.remove(path);
      }
      _tagChange(
        DiaryDraftTagSnapshot(
          date: date,
          generation: _tagValue.generation,
          revision: _tagValue.revision + 1,
          phase: DiaryDraftTagPhase.discarded,
        ),
      );
      if (!await retryTags())
        throw StateError('Discard receipt not acknowledged');
      retired = true;
      text = '';
      savedRevision = revision;
      error = null;
    } catch (_) {
      error = '放弃草稿失败，内容已保留，请重试';
      rethrow;
    } finally {
      publishing = false;
      onPersisted?.call(date);
    }
  }
}
