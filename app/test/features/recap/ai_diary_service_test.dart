import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/recap/application/ai_diary_service.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

void main() {
  test(
    'same-day callers serialize and waiter rechecks duplicate after publish',
    () async {
      final api = _FakeApi();
      final client = _BlockingFirstAiClient();
      final coordinator = AiDiaryGenerationCoordinator(
        service: AiDiaryService(client: client),
      );

      final first = coordinator.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
      );
      await client.firstStarted.future;
      final second = coordinator.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, 1);
      expect(client.maxConcurrentCalls, 1);
      client.releaseFirst.complete();

      final outcomes = await Future.wait([first, second]);
      expect(outcomes.first.status, AiDiaryGenerationStatus.success);
      expect(outcomes.last.status, AiDiaryGenerationStatus.duplicate);
      expect(client.calls, 1);
      expect(api.publishedEntries, hasLength(1));
    },
  );

  test(
    'confirmed duplicate generation still waits for same-day lock',
    () async {
      final api = _FakeApi();
      final client = _BlockingFirstAiClient();
      final coordinator = AiDiaryGenerationCoordinator(
        service: AiDiaryService(client: client),
      );

      final first = coordinator.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
      );
      await client.firstStarted.future;
      final confirmed = coordinator.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
        allowDuplicate: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, 1);
      client.releaseFirst.complete();

      final outcomes = await Future.wait([first, confirmed]);
      expect(outcomes.every((outcome) => outcome.isSuccess), isTrue);
      expect(client.calls, 2);
      expect(client.maxConcurrentCalls, 1);
      expect(api.publishedEntries, hasLength(2));
    },
  );

  test(
    'duplicate is detected before model request and publishes nothing',
    () async {
      final api = _FakeApi(
        entries: const [
          DiaryEntryDto(
            id: 1,
            date: '2026-08-30',
            content: '已有 AI 日记',
            status: 'published',
            source: 'ai_assisted',
            sourceModel: 'old-model',
          ),
        ],
      );
      final client = _FakeAiClient(_successAttempt);

      final outcome = await AiDiaryService(client: client).generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
      );

      expect(outcome.status, AiDiaryGenerationStatus.duplicate);
      expect(client.calls, 0);
      expect(api.publishedEntries, isEmpty);
    },
  );

  test(
    'allowDuplicate explicitly proceeds and publishes with provenance',
    () async {
      final api = _FakeApi(
        entries: const [
          DiaryEntryDto(
            id: 1,
            date: '2026-08-30',
            content: '已有 AI 日记',
            status: 'published',
            source: 'ai_generated',
            sourceModel: 'old-model',
          ),
        ],
      );
      final client = _FakeAiClient(_successAttempt);

      final outcome = await AiDiaryService(client: client).generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings,
        allowDuplicate: true,
      );

      expect(outcome.status, AiDiaryGenerationStatus.success);
      expect(outcome.entryId, 100);
      expect(client.calls, 1);
      expect(api.publishedEntries, hasLength(1));
      expect(api.publishedEntries.single.source, 'ai_generated');
      expect(api.publishedEntries.single.sourceModel, 'test-model');
    },
  );

  test('no meaningful activity skips model and remains retryable', () async {
    final api = _FakeApi(activeSeconds: 0, sessions: const [], apps: const []);
    final client = _FakeAiClient(_successAttempt);

    final outcome = await AiDiaryService(client: client).generateAndPublish(
      api: api,
      date: DateTime(2026, 8, 30),
      settings: _settings,
    );

    expect(outcome.status, AiDiaryGenerationStatus.noActivity);
    expect(outcome.shouldRetry, isTrue);
    expect(client.calls, 0);
    expect(api.publishedEntries, isEmpty);
  });

  test('provider failure never publishes local or fallback text', () async {
    final api = _FakeApi();
    final client = _FakeAiClient(
      const AiDiaryAttempt.failure(
        failure: AiDiaryFailureKind.invalidResponse,
        error: '无效返回',
      ),
    );

    final outcome = await AiDiaryService(client: client).generateAndPublish(
      api: api,
      date: DateTime(2026, 8, 30),
      settings: _settings,
    );

    expect(outcome.status, AiDiaryGenerationStatus.failed);
    expect(outcome.message, '无效返回');
    expect(api.publishedEntries, isEmpty);
  });

  test(
    'disabled and incomplete settings make no model or storage calls',
    () async {
      final api = _FakeApi();
      final client = _FakeAiClient(_successAttempt);
      final service = AiDiaryService(client: client);

      final disabled = await service.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: const RecapAiSettings(),
      );
      final incomplete = await service.generateAndPublish(
        api: api,
        date: DateTime(2026, 8, 30),
        settings: _settings.copyWith(endpoint: ''),
      );

      expect(disabled.status, AiDiaryGenerationStatus.disabled);
      expect(incomplete.status, AiDiaryGenerationStatus.notConfigured);
      expect(client.calls, 0);
      expect(api.publishedEntries, isEmpty);
    },
  );

  test(
    'snapshot localizes explicit ISO zones and preserves time-only values',
    () {
      const utc = '2026-08-30T10:00:00Z';
      const offset = '2026-08-30T18:30:00+08:00';
      const timeOnly = '21:15:30';
      final api = _FakeApi(
        sessions: const [
          DaySessionDto(
            appName: 'UTC app',
            isIdle: false,
            durationSecs: 60,
            startedAt: utc,
          ),
          DaySessionDto(
            appName: 'Offset app',
            isIdle: false,
            durationSecs: 60,
            startedAt: offset,
          ),
          DaySessionDto(
            appName: 'Time app',
            isIdle: false,
            durationSecs: 60,
            startedAt: timeOnly,
          ),
        ],
      );

      final snapshot = buildAiDiarySnapshot(
        api: api,
        date: DateTime(2026, 8, 30),
      );
      final facts = {
        for (final fact in snapshot.activityFacts) fact.appName: fact,
      };

      expect(
        facts['UTC app']!.startedAt,
        DateTime.parse(utc).toLocal().toIso8601String(),
      );
      expect(
        facts['Offset app']!.startedAt,
        DateTime.parse(offset).toLocal().toIso8601String(),
      );
      expect(facts['Time app']!.startedAt, timeOnly);
    },
  );
}

const _settings = RecapAiSettings(
  enabled: true,
  endpoint: 'https://example.test/chat',
  model: 'test-model',
  apiKeyEnv: '',
);

const _successAttempt = AiDiaryAttempt.success(
  AiDiaryDraft(content: '今天主要在开发工具中活动，使用时段比较集中。', model: 'test-model'),
);

class _FakeAiClient implements AiDiaryClient {
  _FakeAiClient(this.attempt);

  final AiDiaryAttempt attempt;
  int calls = 0;

  @override
  Future<AiDiaryAttempt> generateDiary({
    required RecapSnapshot snapshot,
    required RecapAiSettings settings,
  }) async {
    calls++;
    return attempt;
  }

  @override
  Future<String?> testConnection(RecapAiSettings settings) async => null;
}

class _BlockingFirstAiClient implements AiDiaryClient {
  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  int calls = 0;
  int concurrentCalls = 0;
  int maxConcurrentCalls = 0;

  @override
  Future<AiDiaryAttempt> generateDiary({
    required RecapSnapshot snapshot,
    required RecapAiSettings settings,
  }) async {
    calls++;
    concurrentCalls++;
    if (concurrentCalls > maxConcurrentCalls) {
      maxConcurrentCalls = concurrentCalls;
    }
    try {
      if (calls == 1) {
        firstStarted.complete();
        await releaseFirst.future;
      }
      return _successAttempt;
    } finally {
      concurrentCalls--;
    }
  }

  @override
  Future<String?> testConnection(RecapAiSettings settings) async => null;
}

class _FakeApi implements TimeTraceApi {
  _FakeApi({
    this.activeSeconds = 3600,
    List<DiaryEntryDto> entries = const [],
    List<DaySessionDto>? sessions,
    List<AppUsageDto>? apps,
  }) : entries = List.of(entries),
       sessions =
           sessions ??
           const [
             DaySessionDto(
               appName: 'Android Studio',
               isIdle: false,
               durationSecs: 3600,
               startedAt: '2026-08-30T10:00:00',
             ),
           ],
       apps =
           apps ??
           const [
             AppUsageDto(
               appName: 'Android Studio',
               activeSeconds: 3600,
               idleSeconds: 0,
               exePath: '',
             ),
           ];

  final int activeSeconds;
  final List<DiaryEntryDto> entries;
  final List<DaySessionDto> sessions;
  final List<AppUsageDto> apps;
  final List<DiaryEntryDto> publishedEntries = [];

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) => List.of(entries);

  @override
  StatsDto getStats({required String start, required String end}) => StatsDto(
    activeSeconds: start == '2026-08-30' ? activeSeconds : 0,
    idleSeconds: 0,
    totalSeconds: start == '2026-08-30' ? activeSeconds : 0,
  );

  @override
  List<AppUsageDto> getUsageSplit({
    required String start,
    required String end,
  }) => apps;

  @override
  DayDetailDto getDayDetail({required String date}) => DayDetailDto(
    date: date,
    activeSeconds: activeSeconds,
    idleSeconds: 0,
    sessionCount: sessions.length,
    diary: '',
    sessions: sessions,
  );

  @override
  Int64List getDayHourly({required String date}) {
    final values = List<int>.filled(24, 0);
    if (activeSeconds > 0) values[10] = activeSeconds;
    return Int64List.fromList(values);
  }

  @override
  int publishAiDiary({
    required String date,
    required String content,
    required String sourceModel,
  }) {
    const id = 100;
    final entry = DiaryEntryDto(
      id: id,
      date: date,
      content: content,
      status: 'published',
      source: 'ai_generated',
      sourceModel: sourceModel,
    );
    entries.insert(0, entry);
    publishedEntries.add(entry);
    return id;
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
