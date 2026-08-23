import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

void main() {
  test('build, local synchronization and model changes never generate', () {
    final key = _key(24);
    final port = _FakePort(latestValues: {key: _result(key, '已有回顾')});
    final container = ProviderContainer(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);

    final controller = container.read(aiRecapControllerProvider.notifier);
    expect(container.read(aiRecapControllerProvider).status.configured, isTrue);
    controller.synchronize(key);
    controller.selectModel(AiRecapModel.pro);

    final state = container.read(aiRecapControllerProvider);
    expect(state.results[key]?.summary.text, '已有回顾');
    expect(state.model, AiRecapModel.pro);
    expect(port.generateCalls, 0);
  });

  test(
    'generation keeps the old result visible and coalesces duplicate calls',
    () async {
      final key = _key(24);
      final pending = Completer<AiRecapResult>();
      final port = _FakePort(
        latestValues: {key: _result(key, '旧结果')},
        pending: pending,
      );
      final container = ProviderContainer(
        overrides: [aiRecapPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier)
        ..synchronize(key);

      final first = controller.generate(key);
      final second = controller.generate(key);
      expect(
        container.read(aiRecapControllerProvider).results[key]?.summary.text,
        '旧结果',
      );
      expect(container.read(aiRecapControllerProvider).pendingKey, key);
      expect(port.generateCalls, 1);

      pending.complete(_result(key, '新结果'));
      await Future.wait([first, second]);
      expect(
        container.read(aiRecapControllerProvider).results[key]?.summary.text,
        '新结果',
      );
      expect(container.read(aiRecapControllerProvider).pendingKey, isNull);
    },
  );

  test('typed failure preserves the previous recap', () async {
    final key = _key(24);
    final port = _FakePort(
      latestValues: {key: _result(key, '保留内容')},
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    final container = ProviderContainer(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier)
      ..synchronize(key);

    await controller.generate(key);
    final projection = container
        .read(aiRecapControllerProvider)
        .projection(key);
    expect(projection.result?.summary.text, '保留内容');
    expect(projection.failure?.code, AiRecapFailureCode.timeout);
    expect(projection.generating, isFalse);
  });

  test(
    'successful local synchronization clears a stale range failure',
    () async {
      final key = _key(24);
      final port = _FakePort(
        latestValues: {key: _result(key, '恢复后的本地结果')},
        failure: const AiRecapFailure(
          code: AiRecapFailureCode.timeout,
          retryable: true,
        ),
      );
      final container = ProviderContainer(
        overrides: [aiRecapPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier);

      await controller.generate(key);
      expect(
        container.read(aiRecapControllerProvider).failures[key],
        isNotNull,
      );
      controller.synchronize(key);

      final projection = container
          .read(aiRecapControllerProvider)
          .projection(key);
      expect(projection.result?.summary.text, '恢复后的本地结果');
      expect(projection.failure, isNull);
    },
  );

  test('result cache is bounded to the four most recent ranges', () async {
    final port = _FakePort();
    final container = ProviderContainer(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier);

    for (var day = 20; day <= 24; day++) {
      await controller.generate(_key(day));
    }

    final results = container.read(aiRecapControllerProvider).results;
    expect(results.length, 4);
    expect(results.containsKey(_key(20)), isFalse);
    expect(results.containsKey(_key(24)), isTrue);
  });

  test('failure cache is bounded to the four most recent ranges', () async {
    final port = _FakePort(
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    final container = ProviderContainer(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
    );
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier);

    for (var day = 20; day <= 24; day++) {
      await controller.generate(_key(day));
    }

    final failures = container.read(aiRecapControllerProvider).failures;
    expect(failures.length, 4);
    expect(failures.containsKey(_key(20)), isFalse);
    expect(failures.containsKey(_key(24)), isTrue);
  });

  test(
    'today and week-to-date remain distinct when Monday dates collide',
    () async {
      final today = _key(24);
      final week = AiRecapRangeKey(
        scope: AiRecapScope.weekToDate,
        startDate: DateTime(2026, 8, 24),
        endDate: DateTime(2026, 8, 24),
      );
      final port = _FakePort();
      final container = ProviderContainer(
        overrides: [aiRecapPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier);

      await controller.generate(today);
      await controller.generate(week);

      final results = container.read(aiRecapControllerProvider).results;
      expect(results[today], isNotNull);
      expect(results[week], isNotNull);
      expect(results.length, 2);
      expect(port.generateCalls, 2);
    },
  );

  test(
    'unsupported and malformed logical scopes fail before the bridge',
    () async {
      final port = _FakePort();
      final container = ProviderContainer(
        overrides: [aiRecapPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier);
      final invalid = [
        AiRecapRangeKey(
          scope: AiRecapScope.unsupported,
          startDate: DateTime(2026, 8, 24),
          endDate: DateTime(2026, 8, 24),
        ),
        AiRecapRangeKey(
          scope: AiRecapScope.weekToDate,
          startDate: DateTime(2026, 8, 25),
          endDate: DateTime(2026, 8, 25),
        ),
      ];

      for (final key in invalid) {
        await controller.generate(key);
        expect(
          container.read(aiRecapControllerProvider).failures[key]?.code,
          AiRecapFailureCode.invalidRange,
        );
      }
      expect(port.generateCalls, 0);
    },
  );

  test(
    'generation completion preserves another range failure added while awaiting',
    () async {
      final today = _key(24);
      final other = _key(23);
      final pending = Completer<AiRecapResult>();
      final port = _FakePort(pending: pending, latestFailures: {other});
      final container = ProviderContainer(
        overrides: [aiRecapPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier);

      final generation = controller.generate(today);
      controller.synchronize(other);
      expect(
        container.read(aiRecapControllerProvider).failures[other],
        isNotNull,
      );

      pending.complete(_result(today, '生成完成'));
      await generation;
      expect(
        container.read(aiRecapControllerProvider).failures[other],
        isNotNull,
      );
    },
  );
}

AiRecapRangeKey _key(int day) => AiRecapRangeKey(
  scope: AiRecapScope.today,
  startDate: DateTime(2026, 8, day),
  endDate: DateTime(2026, 8, day),
);

AiRecapResult _result(AiRecapRangeKey key, String summary) => AiRecapResult(
  rangeKey: key,
  generatedAt: DateTime.utc(2026, 8, 24, 1, 30),
  model: AiRecapModel.flash,
  summary: _statement(summary),
  highlights: [_statement('保持稳定节奏')],
  suggestions: [_statement('安排一次复盘')],
  totalActiveSeconds: 3600,
  applicationCount: 2,
);

AiRecapStatement _statement(String text) => AiRecapStatement(
  text: text,
  evidence: const [AiRecapEvidence(appName: 'Editor', activeSeconds: 3600)],
);

class _FakePort implements AiRecapPort {
  _FakePort({
    this.latestValues = const {},
    this.latestFailures = const {},
    this.pending,
    this.failure,
  });

  final Map<AiRecapRangeKey, AiRecapResult> latestValues;
  final Set<AiRecapRangeKey> latestFailures;
  final Completer<AiRecapResult>? pending;
  final AiRecapFailure? failure;
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() =>
      const AiRecapProviderStatus(configured: true);

  @override
  AiRecapResult? latest(AiRecapRangeKey key) {
    if (latestFailures.contains(key)) {
      throw const AiRecapFailure(
        code: AiRecapFailureCode.bridgeUnavailable,
        retryable: true,
      );
    }
    return latestValues[key];
  }

  @override
  Future<AiRecapResult> generate(
    AiRecapRangeKey key,
    AiRecapModel model,
  ) async {
    generateCalls++;
    if (failure case final value?) throw value;
    if (pending case final value?) return value.future;
    return _result(key, '生成 ${key.startDate.day}');
  }
}
