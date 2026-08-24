import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_credential_port.dart';

final aiCredentialPortProvider = Provider<AiCredentialPort>(
  (ref) => BridgeAiCredentialPort(
    TimeTraceAiCredentialBridgeApi(ref.watch(apiProvider)),
  ),
);

/// Dependency-only invalidation signal for report state.
///
/// Report providers can watch this counter and re-read their own local status
/// without creating a credential-provider/report-provider import cycle.
class AiCredentialRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state += 1;
}

final aiCredentialRevisionProvider =
    NotifierProvider<AiCredentialRevision, int>(AiCredentialRevision.new);

enum AiCredentialOperation {
  save,
  remove,
  importEnvironment,
  updateModel,
  testConnection,
}

@immutable
class AiCredentialState {
  const AiCredentialState({
    required this.status,
    this.operation,
    this.failure,
    this.connectionTestSucceeded,
  });

  final AiRecapProviderStatus status;
  final AiCredentialOperation? operation;
  final AiCredentialFailureCode? failure;
  final bool? connectionTestSucceeded;

  bool get busy => operation != null;

  AiCredentialState copyWith({
    AiRecapProviderStatus? status,
    Object? operation = _unchanged,
    Object? failure = _unchanged,
    Object? connectionTestSucceeded = _unchanged,
  }) {
    return AiCredentialState(
      status: status ?? this.status,
      operation: identical(operation, _unchanged)
          ? this.operation
          : operation as AiCredentialOperation?,
      failure: identical(failure, _unchanged)
          ? this.failure
          : failure as AiCredentialFailureCode?,
      connectionTestSucceeded: identical(connectionTestSucceeded, _unchanged)
          ? this.connectionTestSucceeded
          : connectionTestSucceeded as bool?,
    );
  }

  static const Object _unchanged = Object();
}

class AiCredentialController extends Notifier<AiCredentialState> {
  AiCredentialPort get _port => ref.read(aiCredentialPortProvider);

  @override
  AiCredentialState build() {
    return AiCredentialState(status: _readStatus());
  }

  void refresh() {
    if (state.busy) return;
    state = state.copyWith(
      status: _readStatus(),
      failure: null,
      connectionTestSucceeded: null,
    );
  }

  Future<bool> saveApiKey(String value) async {
    if (state.busy) return false;
    final apiKey = value.trim();
    if (apiKey.isEmpty) {
      state = state.copyWith(
        failure: AiCredentialFailureCode.invalidKey,
        connectionTestSucceeded: null,
      );
      return false;
    }
    return _runStatusOperation(
      AiCredentialOperation.save,
      () => _port.saveApiKey(apiKey),
    );
  }

  Future<bool> removeApiKey() =>
      _runStatusOperation(AiCredentialOperation.remove, _port.removeApiKey);

  Future<bool> importEnvironmentApiKey() => _runStatusOperation(
    AiCredentialOperation.importEnvironment,
    _port.importEnvironmentApiKey,
  );

  Future<bool> setDefaultModel(AiRecapModel model) async {
    if (state.status.defaultModel == model) return true;
    return _runStatusOperation(
      AiCredentialOperation.updateModel,
      () => _port.setDefaultModel(model),
    );
  }

  Future<bool> testConnection() async {
    if (state.busy || !state.status.configured) return false;
    state = state.copyWith(
      operation: AiCredentialOperation.testConnection,
      failure: null,
      connectionTestSucceeded: null,
    );
    try {
      await _port.testConnection();
      state = state.copyWith(
        operation: null,
        failure: null,
        connectionTestSucceeded: true,
      );
      return true;
    } on AiCredentialFailure catch (failure) {
      state = state.copyWith(
        operation: null,
        failure: failure.code,
        connectionTestSucceeded: false,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        operation: null,
        failure: AiCredentialFailureCode.bridgeUnavailable,
        connectionTestSucceeded: false,
      );
      return false;
    }
  }

  Future<bool> _runStatusOperation(
    AiCredentialOperation operation,
    Future<AiRecapProviderStatus> Function() action,
  ) async {
    if (state.busy) return false;
    state = state.copyWith(
      operation: operation,
      failure: null,
      connectionTestSucceeded: null,
    );
    try {
      final status = await action();
      state = state.copyWith(status: status, operation: null, failure: null);
      return true;
    } on AiCredentialFailure catch (failure) {
      state = state.copyWith(
        status: _readStatus(),
        operation: null,
        failure: failure.code,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        status: _readStatus(),
        operation: null,
        failure: AiCredentialFailureCode.bridgeUnavailable,
      );
      return false;
    } finally {
      ref.read(aiCredentialRevisionProvider.notifier).bump();
    }
  }

  AiRecapProviderStatus _readStatus() {
    try {
      return ref.read(aiCredentialPortProvider).status();
    } catch (_) {
      return const AiRecapProviderStatus.unavailable();
    }
  }
}

final aiCredentialControllerProvider =
    NotifierProvider<AiCredentialController, AiCredentialState>(
      AiCredentialController.new,
    );
