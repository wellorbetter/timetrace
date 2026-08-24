import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

void main() {
  test('build and local synchronization never generate or contact AI', () {
    final daily = _daily(24);
    final weekly = _weekly();
    final port = _FakePort(
      reports: [
        _result(daily, '已有日报', generatedAtMinute: 1),
        _result(weekly, '已有周报', generatedAtMinute: 2),
      ],
    );
    final container = _container(port);
    addTearDown(container.dispose);

    var state = container.read(aiRecapControllerProvider);
    expect(state.results[daily]?.summary.text, '已有日报');
    expect(state.latestReportFor(AiRecapScope.weekly)?.summary.text, '已有周报');
    expect(state.latestReport?.summary.text, '已有周报');

    container.read(aiRecapControllerProvider.notifier).synchronize();
    state = container.read(aiRecapControllerProvider);
    expect(state.results, hasLength(2));
    expect(port.generateCalls, 0);
  });

  test('settings revision locally reloads redacted status and reports', () {
    final key = _daily(24);
    final port = _FakePort();
    final container = _container(port);
    addTearDown(container.dispose);
    expect(container.read(aiRecapControllerProvider).results, isEmpty);

    port
      ..reports = [_result(key, '设置变更后读取')]
      ..statusValue = const AiRecapProviderStatus(
        configured: true,
        defaultModel: AiRecapModel.pro,
      );
    container.read(aiCredentialRevisionProvider.notifier).bump();

    final state = container.read(aiRecapControllerProvider);
    expect(state.results[key]?.summary.text, '设置变更后读取');
    expect(state.status.defaultModel, AiRecapModel.pro);
    expect(port.generateCalls, 0);
  });

  test('generation keeps an old report readable and coalesces calls', () async {
    final key = _daily(24);
    final pending = Completer<AiRecapResult>();
    final port = _FakePort(reports: [_result(key, '旧报告')], pending: pending);
    final container = _container(port);
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier);

    final first = controller.generate(key);
    final second = controller.generate(key);
    var projection = container.read(aiRecapControllerProvider).projection(key);
    expect(projection.result?.summary.text, '旧报告');
    expect(projection.generating, isTrue);
    expect(port.generateCalls, 1);

    pending.complete(_result(key, '新报告'));
    await Future.wait([first, second]);
    projection = container.read(aiRecapControllerProvider).projection(key);
    expect(projection.result?.summary.text, '新报告');
    expect(projection.generating, isFalse);
  });

  test(
    'typed failure preserves the previous report and is retryable',
    () async {
      final key = _daily(24);
      final port = _FakePort(
        reports: [_result(key, '超时前的报告')],
        failure: const AiRecapFailure(
          code: AiRecapFailureCode.timeout,
          retryable: true,
        ),
      );
      final container = _container(port);
      addTearDown(container.dispose);

      await container.read(aiRecapControllerProvider.notifier).generate(key);
      final projection = container
          .read(aiRecapControllerProvider)
          .projection(key);
      expect(projection.result?.summary.text, '超时前的报告');
      expect(projection.failure?.code, AiRecapFailureCode.timeout);
      expect(projection.failure?.retryable, isTrue);
    },
  );

  test('local synchronization clears failure for a persisted report', () async {
    final key = _daily(24);
    final port = _FakePort(
      failure: const AiRecapFailure(
        code: AiRecapFailureCode.timeout,
        retryable: true,
      ),
    );
    final container = _container(port);
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier);

    await controller.generate(key);
    expect(container.read(aiRecapControllerProvider).failures[key], isNotNull);

    port
      ..failure = null
      ..reports = [_result(key, '磁盘中恢复的报告')];
    controller.synchronize();

    final projection = container
        .read(aiRecapControllerProvider)
        .projection(key);
    expect(projection.result?.summary.text, '磁盘中恢复的报告');
    expect(projection.failure, isNull);
    expect(port.generateCalls, 1);
  });

  test(
    'successful generation keeps only the newest report of each type',
    () async {
      final daily = _daily(24);
      final weekly = _weekly();
      final monthly = _monthly();
      final port = _FakePort();
      final container = _container(port);
      addTearDown(container.dispose);
      final controller = container.read(aiRecapControllerProvider.notifier);

      await controller.generate(daily);
      await controller.generate(weekly);
      await controller.generate(monthly);
      await controller.generate(_daily(23));

      final state = container.read(aiRecapControllerProvider);
      expect(state.results, hasLength(3));
      expect(state.results.containsKey(daily), isFalse);
      expect(state.results.containsKey(_daily(23)), isTrue);
      expect(state.latestReportFor(AiRecapScope.weekly), isNotNull);
      expect(state.latestReportFor(AiRecapScope.monthly), isNotNull);
    },
  );

  test('unconfigured and invalid periods fail before generation', () async {
    final port = _FakePort(
      statusValue: const AiRecapProviderStatus.unconfigured(),
    );
    final container = _container(port);
    addTearDown(container.dispose);
    final controller = container.read(aiRecapControllerProvider.notifier);

    final daily = _daily(24);
    await controller.generate(daily);
    expect(
      container.read(aiRecapControllerProvider).failures[daily]?.code,
      AiRecapFailureCode.notConfigured,
    );

    port.statusValue = const AiRecapProviderStatus(configured: true);
    final invalid = AiRecapRangeKey(
      scope: AiRecapScope.weekly,
      startDate: DateTime(2026, 8, 25),
      endDate: DateTime(2026, 8, 25),
    );
    await controller.generate(invalid);
    expect(
      container.read(aiRecapControllerProvider).failures[invalid]?.code,
      AiRecapFailureCode.invalidRange,
    );
    expect(port.generateCalls, 0);
  });

  test(
    'cold build defers status reads and action failures stay redacted',
    () async {
      final key = _daily(24);
      final port = _FakePort(throwOnStatus: true);
      final container = _container(port);
      addTearDown(container.dispose);

      final coldState = container.read(aiRecapControllerProvider);
      expect(coldState.status.serviceAvailable, isTrue);
      expect(coldState.status.configured, isFalse);
      expect(port.statusCalls, 0);
      await container.read(aiRecapControllerProvider.notifier).generate(key);

      final state = container.read(aiRecapControllerProvider);
      expect(state.status.serviceAvailable, isFalse);
      expect(state.failures[key]?.code, AiRecapFailureCode.bridgeUnavailable);
      expect(port.statusCalls, 1);
      expect(port.generateCalls, 0);
    },
  );

  test(
    'mismatched generated range is rejected without replacing saved data',
    () async {
      final requested = _daily(24);
      final port = _FakePort(
        reports: [_result(requested, '原报告')],
        generated: _result(_daily(23), '错误周期'),
      );
      final container = _container(port);
      addTearDown(container.dispose);

      await container
          .read(aiRecapControllerProvider.notifier)
          .generate(requested);
      final projection = container
          .read(aiRecapControllerProvider)
          .projection(requested);
      expect(projection.result?.summary.text, '原报告');
      expect(projection.failure?.code, AiRecapFailureCode.invalidResponse);
    },
  );
}

ProviderContainer _container(AiRecapPort port) =>
    ProviderContainer(overrides: [aiRecapPortProvider.overrideWithValue(port)]);

AiRecapRangeKey _daily(int day) => AiRecapRangeKey(
  scope: AiRecapScope.daily,
  startDate: DateTime(2026, 8, day),
  endDate: DateTime(2026, 8, day),
);

AiRecapRangeKey _weekly() => AiRecapRangeKey(
  scope: AiRecapScope.weekly,
  startDate: DateTime(2026, 8, 24),
  endDate: DateTime(2026, 8, 24),
);

AiRecapRangeKey _monthly() => AiRecapRangeKey(
  scope: AiRecapScope.monthly,
  startDate: DateTime(2026, 8, 1),
  endDate: DateTime(2026, 8, 24),
);

AiRecapResult _result(
  AiRecapRangeKey key,
  String summary, {
  int generatedAtMinute = 0,
}) => AiRecapResult(
  rangeKey: key,
  generatedAt: DateTime.utc(2026, 8, 24, 1, generatedAtMinute),
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
    List<AiRecapResult> reports = const [],
    this.statusValue = const AiRecapProviderStatus(configured: true),
    this.pending,
    this.failure,
    this.generated,
    this.throwOnStatus = false,
  }) : reports = List.of(reports);

  List<AiRecapResult> reports;
  AiRecapProviderStatus statusValue;
  final Completer<AiRecapResult>? pending;
  AiRecapFailure? failure;
  final AiRecapResult? generated;
  final bool throwOnStatus;
  int generateCalls = 0;
  int statusCalls = 0;

  @override
  AiRecapProviderStatus status() {
    statusCalls++;
    if (throwOnStatus) throw StateError('secret-free status failure');
    return statusValue;
  }

  @override
  List<AiRecapResult> latestReports() => List.unmodifiable(reports);

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) async {
    generateCalls++;
    if (failure case final value?) throw value;
    if (pending case final value?) return value.future;
    return generated ?? _result(key, '生成的${key.scope.label}');
  }
}
