import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_recap_port.dart';

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
    required this.model,
    this.results = const {},
    this.failures = const {},
    this.pendingKey,
  });

  final AiRecapProviderStatus status;
  final AiRecapModel model;
  final Map<AiRecapRangeKey, AiRecapResult> results;
  final Map<AiRecapRangeKey, AiRecapFailure> failures;
  final AiRecapRangeKey? pendingKey;

  AiRecapRangeProjection projection(AiRecapRangeKey key) =>
      AiRecapRangeProjection(
        result: results[key],
        generating: pendingKey == key,
        failure: failures[key],
      );

  AiRecapState copyWith({
    AiRecapProviderStatus? status,
    AiRecapModel? model,
    Map<AiRecapRangeKey, AiRecapResult>? results,
    Map<AiRecapRangeKey, AiRecapFailure>? failures,
    Object? pendingKey = _unchanged,
  }) {
    return AiRecapState(
      status: status ?? this.status,
      model: model ?? this.model,
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
  static const int _resultCapacity = 4;

  AiRecapPort get _port => ref.read(aiRecapPortProvider);

  @override
  AiRecapState build() {
    final status = ref.watch(aiRecapPortProvider).status();
    return AiRecapState(status: status, model: status.defaultModel);
  }

  /// Refreshes only local provider status and the in-process result for [key].
  /// This method never performs network I/O and never exposes a loading state.
  void synchronize(AiRecapRangeKey key) {
    final status = _port.status();
    try {
      final latest = state.results[key] ?? _port.latest(key);
      if (latest != null && latest.rangeKey != key) {
        _setFailure(
          key,
          const AiRecapFailure(
            code: AiRecapFailureCode.invalidResponse,
            retryable: true,
          ),
          status: status,
        );
        return;
      }
      final failures = Map<AiRecapRangeKey, AiRecapFailure>.of(state.failures)
        ..remove(key);
      state = state.copyWith(
        status: status,
        results: latest == null ? state.results : _withResult(key, latest),
        failures: Map.unmodifiable(failures),
      );
    } on AiRecapFailure catch (failure) {
      _setFailure(key, failure, status: status);
    } catch (_) {
      _setFailure(
        key,
        const AiRecapFailure(
          code: AiRecapFailureCode.bridgeUnavailable,
          retryable: true,
        ),
        status: status,
      );
    }
  }

  /// Changes the next explicitly requested model without triggering work.
  void selectModel(AiRecapModel model) {
    if (state.model == model) return;
    state = state.copyWith(model: model);
  }

  /// Generates a recap for [key] after an explicit user action.
  Future<void> generate(AiRecapRangeKey key) async {
    if (state.pendingKey != null) return;

    final status = _port.status();
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
      final result = await _port.generate(key, state.model);
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
        results: _withResult(key, result),
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

  Map<AiRecapRangeKey, AiRecapResult> _withResult(
    AiRecapRangeKey key,
    AiRecapResult result,
  ) {
    final bounded = LinkedHashMap<AiRecapRangeKey, AiRecapResult>.of(
      state.results,
    )..remove(key);
    bounded[key] = result;
    while (bounded.length > _resultCapacity) {
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
    while (failures.length > _resultCapacity) {
      failures.remove(failures.keys.first);
    }
    state = state.copyWith(
      status: status,
      failures: Map.unmodifiable(failures),
      pendingKey: pendingKey,
    );
  }
}

final aiRecapControllerProvider =
    NotifierProvider<AiRecapController, AiRecapState>(AiRecapController.new);
