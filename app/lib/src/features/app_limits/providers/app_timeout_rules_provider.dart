import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/app_limits/data/app_timeout_rule_repository.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';

/// Last successfully loaded rule state plus an explicitly refreshed app list.
final class AppTimeoutRulesState {
  AppTimeoutRulesState({
    required List<AppTimeoutRule> rules,
    required List<RunningApplication> runningApplications,
    required this.revision,
  }) : rules = List.unmodifiable(rules),
       runningApplications = List.unmodifiable(runningApplications);

  final List<AppTimeoutRule> rules;
  final List<RunningApplication> runningApplications;
  final int revision;
}

final appTimeoutRuleRepositoryProvider = Provider<AppTimeoutRuleRepository>((
  ref,
) {
  return RustAppTimeoutRuleRepository(ref.watch(apiProvider));
});

class AppTimeoutRulesNotifier extends AsyncNotifier<AppTimeoutRulesState> {
  int _revision = 0;
  AppTimeoutRulesState? _lastSuccessfulState;

  /// Last valid in-memory rules retained while a CRUD operation reports error.
  AppTimeoutRulesState? get lastSuccessfulState => _lastSuccessfulState;

  @override
  Future<AppTimeoutRulesState> build() async {
    final rules = ref.watch(appTimeoutRuleRepositoryProvider).listRules();
    final loaded = AppTimeoutRulesState(
      rules: rules,
      runningApplications: const [],
      revision: _nextRevision(),
    );
    _lastSuccessfulState = loaded;
    return loaded;
  }

  Future<AppTimeoutRule> upsert(AppTimeoutRuleDraft draft) async {
    final current = _requireCurrent();
    try {
      final saved = ref
          .read(appTimeoutRuleRepositoryProvider)
          .upsertRule(draft);
      final nextRules = [...current.rules];
      final index = nextRules.indexWhere(
        (rule) =>
            rule.id == saved.id || rule.executablePath == saved.executablePath,
      );
      if (index < 0) {
        nextRules.add(saved);
      } else {
        nextRules[index] = saved;
      }
      final next = AppTimeoutRulesState(
        rules: nextRules,
        runningApplications: current.runningApplications,
        revision: _nextRevision(),
      );
      _lastSuccessfulState = next;
      state = AsyncData(next);
      return saved;
    } catch (error, stackTrace) {
      state = AsyncError<AppTimeoutRulesState>(error, stackTrace);
      rethrow;
    }
  }

  Future<void> delete(int id) async {
    final current = _requireCurrent();
    try {
      ref.read(appTimeoutRuleRepositoryProvider).deleteRule(id);
      final next = AppTimeoutRulesState(
        rules: current.rules.where((rule) => rule.id != id).toList(),
        runningApplications: current.runningApplications,
        revision: _nextRevision(),
      );
      _lastSuccessfulState = next;
      state = AsyncData(next);
    } catch (error, stackTrace) {
      state = AsyncError<AppTimeoutRulesState>(error, stackTrace);
      rethrow;
    }
  }

  /// Refreshes the process catalog only in response to an explicit UI action.
  Future<List<RunningApplication>> refreshRunningApplications() async {
    final current = _requireCurrent();
    try {
      final applications = ref
          .read(appTimeoutRuleRepositoryProvider)
          .refreshRunningApplications();
      final next = AppTimeoutRulesState(
        rules: current.rules,
        runningApplications: applications,
        revision: current.revision,
      );
      _lastSuccessfulState = next;
      state = AsyncData(next);
      return applications;
    } catch (error, stackTrace) {
      state = AsyncError<AppTimeoutRulesState>(error, stackTrace);
      rethrow;
    }
  }

  AppTimeoutRulesState _requireCurrent() {
    final current = state.value ?? _lastSuccessfulState;
    if (current == null) {
      throw StateError('Application timeout rules are not loaded yet.');
    }
    return current;
  }

  int _nextRevision() => ++_revision;
}

final appTimeoutRulesProvider =
    AsyncNotifierProvider<AppTimeoutRulesNotifier, AppTimeoutRulesState>(
      AppTimeoutRulesNotifier.new,
    );
