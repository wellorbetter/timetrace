import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';

final aiRecapPortProvider = Provider<AiRecapPort>(
  (ref) => BridgeAiRecapPort(TimeTraceAiRecapBridgeApi(ref.watch(apiProvider))),
);

@immutable
class AiRecapRangeProjection {
  const AiRecapRangeProjection({
    required this.result,
    required this.generating,
    required this.failure,
  });

  final AiRecapResult? result;
  final bool generating;
  final AiRecapFailure? failure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapRangeProjection &&
          result == other.result &&
          generating == other.generating &&
          failure == other.failure;

  @override
  int get hashCode => Object.hash(result, generating, failure);
}

@immutable
class AiRecapState {
  const AiRecapState({
    required this.status,
    this.results = const {},
    this.failures = const {},
    this.pendingKey,
  });

  final AiRecapProviderStatus status;
  final Map<AiRecapRangeKey, AiRecapResult> results;
  final Map<AiRecapRangeKey, AiRecapFailure> failures;
  final AiRecapRangeKey? pendingKey;

  AiRecapRangeProjection projection(AiRecapRangeKey key) =>
      AiRecapRangeProjection(
        result: results[key],
        generating: pendingKey == key,
        failure: failures[key],
      );

  AiRecapResult? get latestReport {
    AiRecapResult? newest;
    for (final result in results.values) {
      if (newest == null || result.generatedAt.isAfter(newest.generatedAt)) {
        newest = result;
      }
    }
    return newest;
  }

  AiRecapResult? latestReportFor(AiRecapScope scope) {
    AiRecapResult? newest;
    for (final result in results.values) {
      if (result.rangeKey.scope != scope) continue;
      if (newest == null || result.generatedAt.isAfter(newest.generatedAt)) {
        newest = result;
      }
    }
    return newest;
  }

  AiRecapState copyWith({
    AiRecapProviderStatus? status,
    Map<AiRecapRangeKey, AiRecapResult>? results,
    Map<AiRecapRangeKey, AiRecapFailure>? failures,
    Object? pendingKey = _unchanged,
  }) {
    return AiRecapState(
      status: status ?? this.status,
      results: results ?? this.results,
      failures: failures ?? this.failures,
      pendingKey: identical(pendingKey, _unchanged)
          ? this.pendingKey
          : pendingKey as AiRecapRangeKey?,
    );
  }

  static const Object _unchanged = Object();
}

class AiRecapController extends Notifier<AiRecapState> {
  static const int _scopeCapacity = 3;

  AiRecapPort get _port => ref.read(aiRecapPortProvider);

  @override
  AiRecapState build() {
    final credentialRevision = ref.watch(aiCredentialRevisionProvider);
    final port = ref.watch(aiRecapPortProvider);
    try {
      return AiRecapState(
        status: credentialRevision == 0
            ? const AiRecapProviderStatus.unconfigured()
            : port.status(),
        results: _reportMap(port.latestReports()),
      );
    } catch (_) {
      return const AiRecapState(status: AiRecapProviderStatus.unavailable());
    }
  }

  /// Reloads redacted settings and persisted reports. This is local-only and
  /// never contacts the provider.
  void synchronize() {
    try {
      final results = _reportMap(_port.latestReports());
      final failures = Map<AiRecapRangeKey, AiRecapFailure>.of(state.failures)
        ..removeWhere((key, _) => results.containsKey(key));
      state = state.copyWith(
        status: _port.status(),
        results: results,
        failures: Map.unmodifiable(failures),
      );
    } catch (_) {
      state = state.copyWith(status: const AiRecapProviderStatus.unavailable());
    }
  }

  /// Refreshes only redacted settings after the Settings screen mutates them.
  void refreshStatus() {
    try {
      state = state.copyWith(status: _port.status());
    } catch (_) {
      state = state.copyWith(status: const AiRecapProviderStatus.unavailable());
    }
  }

  /// Generates a report after an explicit user action. The native service
  /// chooses the persisted default model.
  Future<void> generate(AiRecapRangeKey key) async {
    if (state.pendingKey != null) return;

    AiRecapProviderStatus status;
    try {
      status = _port.status();
    } catch (_) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.bridgeUnavailable,
          retryable: true,
        ),
        status: const AiRecapProviderStatus.unavailable(),
      );
      return;
    }
    if (!status.serviceAvailable) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.bridgeUnavailable,
          retryable: true,
        ),
        status: status,
      );
      return;
    }
    if (!status.configured) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.notConfigured,
          retryable: false,
        ),
        status: status,
      );
      return;
    }
    if (!key.isValid) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.invalidRange,
          retryable: false,
        ),
        status: status,
      );
      return;
    }

    final failures = Map<AiRecapRangeKey, AiRecapFailure>.of(state.failures)
      ..remove(key);
    state = state.copyWith(
      status: status,
      failures: Map.unmodifiable(failures),
      pendingKey: key,
    );

    try {
      final result = await _port.generate(key);
      if (result.rangeKey != key) {
        throw const AiRecapFailure(
          code: AiRecapFailureCode.invalidResponse,
          retryable: true,
        );
      }
      final currentFailures = Map<AiRecapRangeKey, AiRecapFailure>.of(
        state.failures,
      )..remove(key);
      state = state.copyWith(
        results: _withResult(result),
        failures: Map.unmodifiable(currentFailures),
        pendingKey: null,
      );
    } on AiRecapFailure catch (failure) {
      _setFailure(key, failure, pendingKey: null);
    } catch (_) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.bridgeUnavailable,
          retryable: true,
        ),
        pendingKey: null,
      );
    }
  }

  Map<AiRecapRangeKey, AiRecapResult> _withResult(AiRecapResult result) {
    final bounded = LinkedHashMap<AiRecapRangeKey, AiRecapResult>.of(
      state.results,
    );
    bounded.removeWhere(
      (_, value) => value.rangeKey.scope == result.rangeKey.scope,
    );
    bounded[result.rangeKey] = result;
    while (bounded.length > _scopeCapacity) {
      bounded.remove(bounded.keys.first);
    }
    return Map.unmodifiable(bounded);
  }

  void _setFailure(
    AiRecapRangeKey key,
    AiRecapFailure failure, {
    AiRecapProviderStatus? status,
    Object? pendingKey = AiRecapState._unchanged,
  }) {
    final failures = LinkedHashMap<AiRecapRangeKey, AiRecapFailure>.of(
      state.failures,
    )..remove(key);
    failures[key] = failure;
    while (failures.length > _scopeCapacity) {
      failures.remove(failures.keys.first);
    }
    state = state.copyWith(
      status: status,
      failures: Map.unmodifiable(failures),
      pendingKey: pendingKey,
    );
  }
}

Map<AiRecapRangeKey, AiRecapResult> _reportMap(
  Iterable<AiRecapResult> reports,
) {
  final newestByScope = <AiRecapScope, AiRecapResult>{};
  for (final report in reports) {
    if (!report.rangeKey.isValid || !report.rangeKey.scope.isSupported) {
      continue;
    }
    final existing = newestByScope[report.rangeKey.scope];
    if (existing == null || report.generatedAt.isAfter(existing.generatedAt)) {
      newestByScope[report.rangeKey.scope] = report;
    }
  }
  final values = <AiRecapRangeKey, AiRecapResult>{};
  for (final report in newestByScope.values) {
    values[report.rangeKey] = report;
  }
  return Map.unmodifiable(values);
}

final aiRecapControllerProvider =
    NotifierProvider<AiRecapController, AiRecapState>(AiRecapController.new);
