import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences/ui_preferences_store.dart';
import '../../../core/preferences/ui_preferences_controller.dart';
import '../../../core/preferences/safe_cache_service.dart';

const dailyPoemEndpoint = 'https://v2.jinrishici.com/one.json';

class DailyQuote {
  // Legacy const construction deliberately represents an excerpt, not a poem.
  const DailyQuote(
    this.text,
    this.source, {
    this.online = false,
    this.author = '',
    this.work = '',
  }) : dynasty = '',
       sourceUrl = '',
       fullContent = const [];

  DailyQuote._full(
    this.text,
    this.source, {
    required this.online,
    required this.author,
    required this.work,
    required this.dynasty,
    required this.sourceUrl,
    required this.fullContent,
  });

  /// Snapshots caller-owned lines; both alias mutation and returned mutation
  /// must be unable to change a verified excerpt/poem pair.
  factory DailyQuote.full(
    String text,
    String source, {
    bool online = false,
    required String author,
    required String work,
    required String dynasty,
    required String sourceUrl,
    required List<String> fullContent,
  }) {
    bool field(String value, int max) =>
        value.trim().isNotEmpty && value.length <= max;
    final uri = Uri.tryParse(sourceUrl);
    if (!field(text, 120) ||
        source.length > 256 ||
        !field(author, 120) ||
        !field(work, 120) ||
        !field(dynasty, 120) ||
        sourceUrl.length > 512 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        fullContent.isEmpty ||
        fullContent.length > 128 ||
        fullContent.any((line) => !field(line, 512)) ||
        fullContent.fold<int>(0, (sum, line) => sum + line.length) > 16384 ||
        !_withoutWhitespace(
          fullContent.join(),
        ).contains(_withoutWhitespace(text))) {
      throw const FormatException('Incomplete poem');
    }
    return DailyQuote._full(
      text.trim(),
      source.trim(),
      online: online,
      author: author.trim(),
      work: work.trim(),
      dynasty: dynasty.trim(),
      sourceUrl: sourceUrl,
      fullContent: List<String>.unmodifiable(fullContent),
    );
  }

  final String text;
  final String source;
  final bool online;
  final String author;
  final String work;
  final String dynasty;
  final String sourceUrl;
  final List<String> fullContent;
  bool get hasFullPoem => fullContent.isNotEmpty;
  static String _withoutWhitespace(String text) =>
      text.replaceAll(RegExp(r'\s+'), '');

  // Kept for legacy display only; never invents full-poem/cache metadata.
  static const _dynasties = {
    '陆游': '宋',
    '陸游': '宋',
    '苏轼': '宋',
    '蘇軾': '宋',
    '王维': '唐',
    '王維': '唐',
    '王安石': '宋',
  };
  String get attribution {
    var poet = author.trim();
    var title = work.trim();
    if (poet.isEmpty) {
      final legacy = source
          .split(' · ')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toSet()
          .join(' · ');
      for (final name in _dynasties.keys) {
        if (legacy == name ||
            legacy.startsWith('$name · ') ||
            legacy.startsWith('$name《')) {
          poet = name;
          title = legacy
              .substring(name.length)
              .replaceFirst(RegExp(r'^\s*·\s*'), '')
              .trim();
          break;
        }
      }
      if (poet.isEmpty) return legacy;
    }
    if (title == poet) title = '';
    if (title.isNotEmpty && !title.startsWith('《')) title = '《$title》';
    final era = dynasty.isNotEmpty ? dynasty : _dynasties[poet];
    return '${era == null ? '' : '〔$era〕'}$poet${title.isEmpty ? '' : ' · $title'}';
  }

  static DailyQuote? decode(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    final source = value['source'];
    if (text is! String ||
        text.trim().isEmpty ||
        text.length > 120 ||
        source is! String ||
        source.length > 256)
      return null;
    if (value.containsKey('fullContent')) {
      final lines = value['fullContent'];
      if (lines is! List ||
          lines.any((line) => line is! String) ||
          value['author'] is! String ||
          value['work'] is! String ||
          value['dynasty'] is! String ||
          value['sourceUrl'] is! String ||
          value['online'] is! bool)
        return null;
      try {
        return DailyQuote.full(
          text,
          source,
          online: value['online'] as bool,
          author: value['author'] as String,
          work: value['work'] as String,
          dynasty: value['dynasty'] as String,
          sourceUrl: value['sourceUrl'] as String,
          fullContent: lines.cast<String>(),
        );
      } on FormatException {
        return null;
      }
    }
    return DailyQuote(
      text.trim(),
      source.trim(),
      online: value['online'] == true,
      author:
          value['author'] is String && (value['author'] as String).length <= 120
          ? value['author'] as String
          : '',
      work: value['work'] is String && (value['work'] as String).length <= 120
          ? value['work'] as String
          : '',
    );
  }

  Map<String, Object> toCache(String day) => {
    'schemaVersion': 2,
    'day': day,
    'text': text,
    'source': source,
    'online': online,
    'author': author,
    'work': work,
    'dynasty': dynasty,
    'fullContent': fullContent,
    'sourceUrl': sourceUrl,
  };
}

// Ancient original texts, checked in interaction-request-queue.md; simplified
// characters only, no modern translations/annotations. Versioned source URLs.
final offlineDailyQuotes = List<DailyQuote>.unmodifiable([
  DailyQuote.full(
    '行到水穷处，坐看云起时。',
    '王维《终南别业》',
    author: '王维',
    work: '终南别业',
    dynasty: '唐',
    sourceUrl: 'https://zh.wikisource.org/wiki/終南別業?oldid=1982349',
    fullContent: [
      '中岁颇好道，晚家南山陲。',
      '兴来每独往，胜事空自知。',
      '行到水穷处，坐看云起时。',
      '偶然值林叟，谈笑无还期。',
    ],
  ),
  DailyQuote.full(
    '且将新火试新茶。',
    '苏轼《望江南（春未老）》',
    author: '苏轼',
    work: '望江南（春未老）',
    dynasty: '北宋',
    sourceUrl: 'https://zh.wikisource.org/zh/望江南（春未老）?oldid=2589938',
    fullContent: [
      '春未老，风细柳斜斜。',
      '试上超然台上看，半壕春水一城花。',
      '烟雨暗千家。',
      '寒食后，酒醒却咨嗟。',
      '休对故人思故国，且将新火试新茶。',
      '诗酒趁年华。',
    ],
  ),
  DailyQuote.full(
    '山重水复疑无路，柳暗花明又一村。',
    '陆游《游山西村》',
    author: '陆游',
    work: '游山西村',
    dynasty: '南宋',
    sourceUrl: 'https://zh.wikisource.org/zh-hans/遊山西村?oldid=902696',
    fullContent: [
      '莫笑农家腊酒浑，丰年留客足鸡豚。',
      '山重水复疑无路，柳暗花明又一村。',
      '箫鼓追随春社近，衣冠简朴古风存。',
      '从今若许闲乘月，拄杖无时夜叩门。',
    ],
  ),
]);

/// Only white-listed origin fields become model/cache values.
DailyQuote parseDailyPoem(Object? raw) {
  if (raw is! Map || raw['status'] != 'success' || raw['data'] is! Map) {
    throw const FormatException('Poem unavailable');
  }
  final data = raw['data'] as Map;
  final origin = data['origin'];
  if (origin is! Map ||
      data['content'] is! String ||
      origin['title'] is! String ||
      origin['author'] is! String ||
      origin['dynasty'] is! String ||
      origin['content'] is! List ||
      (origin['content'] as List).any((line) => line is! String)) {
    throw const FormatException('Incomplete poem');
  }
  final author = origin['author'] as String;
  final title = origin['title'] as String;
  return DailyQuote.full(
    data['content'] as String,
    '$author《$title》',
    online: true,
    author: author,
    work: title,
    dynasty: origin['dynasty'] as String,
    sourceUrl: dailyPoemEndpoint,
    fullContent: (origin['content'] as List).cast<String>(),
  );
}

/// No user data, custom headers, token, cookie or identity parameters.
/// deadline covers connect, headers, every chunk, UTF-8 decode and parse.
Future<DailyQuote> fetchDailyQuote({
  HttpClient Function()? clientFactory,
  Duration deadline = const Duration(seconds: 10),
}) async {
  final client = (clientFactory ?? HttpClient.new)()
    ..connectionTimeout = const Duration(seconds: 5);
  var active = true;
  HttpClientRequest? pending;
  Future<DailyQuote> read() async {
    final request = await client.getUrl(Uri.parse(dailyPoemEndpoint));
    pending = request;
    if (!active) {
      request.abort();
      throw const FormatException('Poem cancelled');
    }
    request.followRedirects = false;
    final response = await request.close();
    if (!active || response.statusCode != HttpStatus.ok) {
      throw const FormatException('Poem unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (!active || chunk.length > 32 * 1024 - bytes.length) {
        throw const FormatException('Poem response too large');
      }
      bytes.addAll(chunk);
    }
    if (!active) throw const FormatException('Poem cancelled');
    return parseDailyPoem(jsonDecode(utf8.decode(bytes)));
  }

  try {
    return await read().timeout(deadline);
  } finally {
    active = false;
    pending?.abort();
    client.close(force: true);
  }
}

class DailyQuoteStatus {
  const DailyQuoteStatus({
    this.quote,
    this.busy = false,
    this.message,
    this.cachePending = false,
  });
  final DailyQuote? quote;
  final bool busy, cachePending;
  final String? message;
}

typedef QuoteCachePatch =
    UiPreferencesWriteOutcome Function(
      Map<String, dynamic>,
      Object?,
      bool Function(Map<String, dynamic>),
    );

class DailyQuoteRepository {
  DailyQuoteRepository({
    required this.read,
    required this.write,
    required this.fetch,
    this.readOutcome,
    this.patch,
    this.cacheEpoch,
  }) : _observedEpoch = cacheEpoch?.call() ?? 0;
  final Map<String, dynamic> Function() read;
  final void Function(Map<String, dynamic>) write;
  final Future<DailyQuote> Function() fetch;
  final UiPreferencesReadOutcome Function()? readOutcome;
  final QuoteCachePatch? patch;
  final int Function()? cacheEpoch;
  int _observedEpoch;
  String? _displayDay;
  DailyQuoteStatus? _clearedDisplay;
  final _completed = LinkedHashMap<String, DailyQuoteStatus>();
  final _flights = <String, Future<DailyQuote>>{};
  final _busy = <String, DailyQuoteStatus>{};
  // Quote CAS is separate from the shared workspace/order token. Retain the
  // exact target preimage with a pending result until a verified retry.
  final _cachePreimages = <String, String>{};
  final _changes = StreamController<String>.broadcast(sync: true);
  int _generation = 0, _sequence = 0, _latest = 0;
  bool _alive = true;
  int get completedCount => _completed.length;
  int get flightCount => _flights.length;
  List<String> get completedDays => List.unmodifiable(_completed.keys);
  Stream<String> get changes => _changes.stream;
  static String stamp(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  DailyQuoteStatus status(String day) =>
      _busy[day] ??
      _completed[day] ??
      (day == _displayDay ? _clearedDisplay : null) ??
      const DailyQuoteStatus();
  void _emit(String day) {
    if (_alive) _changes.add(day);
  }

  void _remember(String day, DailyQuoteStatus value) {
    _displayDay = null;
    _clearedDisplay = null;
    _completed.remove(day);
    _completed[day] = value;
    while (_completed.length > 7) {
      final oldest = _completed.keys.first;
      _completed.remove(oldest);
      _cachePreimages.remove(oldest);
    }
  }

  /// Called only after a verified cache-removal ACK (or an injected epoch).
  /// The single display value is not a reusable cache or a pending write intent.
  /// Clearing never starts a request, reads storage or clears Flutter images.
  void clearMemory({DateTime? visibleDate}) {
    if (!_alive) return;
    final affected = {..._completed.keys, ..._busy.keys, ..._flights.keys};
    final day = visibleDate != null
        ? stamp(visibleDate)
        : _busy.isNotEmpty
        ? _busy.keys.last
        : _completed.isNotEmpty
        ? _completed.keys.last
        : _displayDay;
    final previous = day == null ? null : status(day).quote;
    _generation++;
    _latest = ++_sequence;
    _observedEpoch = cacheEpoch?.call() ?? _observedEpoch;
    _completed.clear();
    _cachePreimages.clear();
    _flights.clear();
    _busy.clear();
    _displayDay = day;
    _clearedDisplay = day == null
        ? null
        : DailyQuoteStatus(
            quote: previous ?? offlineDailyQuotes.first,
            message: '缓存已清除，当前诗句保留',
          );
    if (day != null) affected.add(day);
    for (final key in affected) {
      _emit(key);
    }
  }

  void _syncEpoch() {
    if ((cacheEpoch?.call() ?? _observedEpoch) != _observedEpoch) clearMemory();
  }

  bool _isCurrent(int generation, int epoch) =>
      _alive &&
      generation == _generation &&
      epoch == (cacheEpoch?.call() ?? _observedEpoch);

  DailyQuote _retained(String day, DailyQuote? previous) =>
      status(day).quote ?? previous ?? offlineDailyQuotes.first;

  void dispose() {
    _alive = false;
    _generation++;
    _busy.clear();
    unawaited(_changes.close());
  }

  static bool _safeRoot(Map<String, dynamic> root) {
    if (!root.containsKey('dailyQuoteV2')) return true;
    final slot = root['dailyQuoteV2'];
    if (slot is! Map ||
        slot['schemaVersion'] != 2 ||
        slot['day'] is! String ||
        !_validDay(slot['day'] as String) ||
        DailyQuote.decode(slot)?.hasFullPoem != true)
      return false;
    const keys = {
      'schemaVersion',
      'day',
      'text',
      'source',
      'online',
      'author',
      'work',
      'dynasty',
      'fullContent',
      'sourceUrl',
    };
    return slot.keys.every(keys.contains);
  }

  static bool _validDay(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(5, 7));
    final day = int.parse(value.substring(8, 10));
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31)
      return false;
    final date = DateTime.utc(year, month, day);
    return date.year == year && date.month == month && date.day == day;
  }

  static String _quoteToken(Map<String, dynamic> root) => jsonEncode({
    'present': root.containsKey('dailyQuoteV2'),
    if (root.containsKey('dailyQuoteV2')) 'value': root['dailyQuoteV2'],
  });

  ({Map<String, dynamic> root, Object? token, bool writable}) _read() {
    try {
      if (readOutcome case final reader?) {
        final outcome = reader();
        if (outcome is UiPreferencesMissing)
          return (
            root: <String, dynamic>{},
            token: outcome.token,
            writable: true,
          );
        if (outcome is UiPreferencesLoaded)
          return (
            root: outcome.root,
            token: outcome.token,
            writable: _safeRoot(outcome.root),
          );
        return (root: <String, dynamic>{}, token: null, writable: false);
      }
      final root = read();
      return (root: root, token: null, writable: _safeRoot(root));
    } catch (_) {
      return (root: <String, dynamic>{}, token: null, writable: false);
    }
  }

  bool _save(
    String day,
    DailyQuote quote,
    String preimage,
    int generation,
    int epoch,
  ) {
    if (!_isCurrent(generation, epoch)) return false;
    final current = _read();
    if (!current.writable || !_validDay(day)) return false;
    final currentSlot = current.root['dailyQuoteV2'];
    if (currentSlot is Map &&
        currentSlot['day'] is String &&
        (currentSlot['day'] as String).compareTo(day) > 0)
      return false;
    try {
      final delta = {'dailyQuoteV2': quote.toCache(day)};
      final result = _quoteToken(delta);
      bool validatesQuoteTarget(Map<String, dynamic> root) {
        if (!_isCurrent(generation, epoch) || !_safeRoot(root)) return false;
        final target = _quoteToken(root);
        // The shared transaction validates both its input and generated root.
        // An exact intended result is also safe to ACK after lost verification.
        return target == preimage || target == result;
      }

      if (!validatesQuoteTarget(current.root)) return false;
      if (patch case final commit?)
        return commit(delta, current.token, validatesQuoteTarget)
            is UiPreferencesCommitted;
      write(delta);
      return _isCurrent(
        generation,
        epoch,
      ); // Compatible injected memory seam only.
    } catch (_) {
      return false;
    }
  }

  Future<DailyQuote> load(DateTime date) {
    _syncEpoch();
    final day = stamp(date), running = _flights[stamp(date)];
    if (!_alive) return Future.value(_retained(day, null));
    if (running != null) return running;
    if (day == _displayDay && _clearedDisplay?.quote != null) {
      return Future.value(_clearedDisplay!.quote!);
    }
    final value = _completed.remove(day);
    if (value != null) {
      _completed[day] = value;
      return Future.value(value.quote!);
    }
    return _start(date, explicit: false);
  }

  Future<DailyQuote> refresh(DateTime date, {bool offline = false}) {
    _syncEpoch();
    if (!_alive) return Future.value(_retained(stamp(date), null));
    return _flights[stamp(date)] ??
        _start(date, explicit: true, offline: offline);
  }

  Future<DailyQuote> _start(
    DateTime date, {
    required bool explicit,
    bool offline = false,
  }) {
    final day = stamp(date),
        generation = _generation,
        epoch = cacheEpoch?.call() ?? _observedEpoch,
        sequence = ++_sequence;
    _latest = sequence;
    final previousStatus = status(day);
    final previous = previousStatus.quote;
    _busy[day] = DailyQuoteStatus(quote: previous, busy: true);
    _emit(day);
    final snapshot = _read(), cached = _readCache(date, explicit);
    final preimage = _quoteToken(snapshot.root);
    Future<DailyQuote> request;
    if (cached != null) {
      request = Future.value(cached);
    } else if (offline) {
      final index = offlineDailyQuotes.indexWhere(
        (q) => q.text == previous?.text && q.work == previous?.work,
      );
      request = Future.value(
        offlineDailyQuotes[(index + 1) % offlineDailyQuotes.length],
      );
    } else {
      try {
        request = fetch();
      } catch (e, s) {
        request = Future.error(e, s);
      }
    }
    late final Future<DailyQuote> operation;
    operation =
        (() async {
          var failed = false;
          DailyQuote quote;
          try {
            quote = await request;
            if (!quote.hasFullPoem) throw const FormatException('Excerpt only');
          } catch (_) {
            failed = true;
            quote =
                previous ??
                offlineDailyQuotes[DateTime(
                      date.year,
                      date.month,
                      date.day,
                    ).difference(DateTime(2020)).inDays.abs() %
                    offlineDailyQuotes.length];
          }
          if (!_isCurrent(generation, epoch)) return _retained(day, previous);
          var saved = cached != null && snapshot.writable;
          final retainedAfterFailure = failed && previous != null;
          if (retainedAfterFailure) saved = !previousStatus.cachePending;
          if (!saved &&
              sequence == _latest &&
              !retainedAfterFailure &&
              snapshot.writable)
            saved = _save(day, quote, preimage, generation, epoch);
          if (!_isCurrent(generation, epoch)) return _retained(day, previous);
          final same =
              previous != null &&
              jsonEncode(previous.toCache(day)) ==
                  jsonEncode(quote.toCache(day));
          if (!retainedAfterFailure) _cachePreimages[day] = preimage;
          _remember(
            day,
            DailyQuoteStatus(
              quote: quote,
              message: failed
                  ? '暂时无法换句，保留当前诗句'
                  : explicit && same
                  ? '这次仍是同一句'
                  : null,
              cachePending: !saved,
            ),
          );
          return quote;
        })().whenComplete(() {
          if (identical(_flights[day], operation)) {
            _flights.remove(day);
            _busy.remove(day);
            _emit(day);
          }
        });
    _flights[day] = operation;
    return operation;
  }

  DailyQuote? _readCache(DateTime date, bool explicit) {
    if (explicit) return null;
    final cached = _read().root['dailyQuoteV2'];
    if (cached is Map &&
        cached['schemaVersion'] == 2 &&
        cached['day'] == stamp(date)) {
      final value = DailyQuote.decode(cached);
      if (value?.hasFullPoem == true) return value;
    }
    return null;
  }

  bool retryCache(DateTime date) {
    _syncEpoch();
    final generation = _generation,
        epoch = cacheEpoch?.call() ?? _observedEpoch;
    final day = stamp(date), value = _completed[stamp(date)];
    if (!_alive || value?.quote == null || _flights.containsKey(day))
      return false;
    final preimage = _cachePreimages[day];
    if (preimage == null) return false;
    final saved = _save(day, value!.quote!, preimage, generation, epoch);
    if (!_isCurrent(generation, epoch)) return false;
    _remember(
      day,
      DailyQuoteStatus(
        quote: value.quote,
        message: value.message,
        cachePending: !saved,
      ),
    );
    _emit(day);
    return saved;
  }
}

final dailyQuoteClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);
final dailyQuoteFetchProvider = Provider<Future<DailyQuote> Function()>(
  (ref) => fetchDailyQuote,
);
final dailyQuoteRepositoryProvider = Provider<DailyQuoteRepository>((ref) {
  final repository = DailyQuoteRepository(
    read: () => throw StateError('Production uses typed cache'),
    write: (_) => throw StateError('Production uses typed commit'),
    readOutcome: () =>
        ref.read(uiPreferencesControllerProvider.notifier).readOutcome(),
    patch: (delta, token, validate) => UiPreferencesStore.tryPatch(
      delta,
      expectedTargetToken: token,
      validateRoot: validate,
      backend: ref.read(uiPreferencesBackendProvider),
    ),
    fetch: ref.read(dailyQuoteFetchProvider),
    cacheEpoch: () => ref.read(safeCacheEpochProvider),
  );
  ref.listen<int>(safeCacheEpochProvider, (previous, next) {
    if (previous != next) {
      repository.clearMemory(visibleDate: ref.read(dailyQuoteClockProvider)());
    }
  });
  ref.onDispose(repository.dispose);
  return repository;
});
final dailyQuoteProvider = FutureProvider.autoDispose
    .family<DailyQuote, String>(
      (ref, day) =>
          ref.watch(dailyQuoteRepositoryProvider).load(DateTime.parse(day)),
    );
final dailyQuoteStatusProvider = StreamProvider.autoDispose
    .family<DailyQuoteStatus, String>((ref, day) {
      final repository = ref.watch(dailyQuoteRepositoryProvider),
          stamp = DailyQuoteRepository.stamp(DateTime.parse(day));
      late final StreamController<DailyQuoteStatus> controller;
      StreamSubscription<String>? subscription;
      controller = StreamController<DailyQuoteStatus>(
        onListen: () {
          subscription = repository.changes.listen((changed) {
            if (changed == stamp) controller.add(repository.status(stamp));
          });
          controller.add(repository.status(stamp));
        },
        onCancel: () => subscription?.cancel(),
      );
      ref.onDispose(() {
        unawaited(subscription?.cancel());
        unawaited(controller.close());
      });
      return controller.stream;
    });
