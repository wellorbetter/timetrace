import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';

/// User-editable fields for one executable timeout rule.
final class AppTimeoutRuleDraft {
  const AppTimeoutRuleDraft({
    required this.executablePath,
    required this.displayName,
    required this.threshold,
    required this.cooldown,
    required this.enabled,
    required this.repeatEnabled,
  });

  factory AppTimeoutRuleDraft.fromRule(AppTimeoutRule rule) {
    return AppTimeoutRuleDraft(
      executablePath: rule.executablePath,
      displayName: rule.displayName,
      threshold: rule.threshold,
      cooldown: rule.cooldown,
      enabled: rule.enabled,
      repeatEnabled: rule.repeatEnabled,
    );
  }

  final String executablePath;
  final String displayName;
  final Duration threshold;
  final Duration cooldown;
  final bool enabled;
  final bool repeatEnabled;
}

/// Privacy-minimal process-selector entry; CPU and window data are excluded.
final class RunningApplication {
  const RunningApplication({
    required this.executablePath,
    required this.displayName,
  });

  final String executablePath;
  final String displayName;

  @override
  bool operator ==(Object other) {
    return other is RunningApplication &&
        other.executablePath == executablePath &&
        other.displayName == displayName;
  }

  @override
  int get hashCode => Object.hash(executablePath, displayName);
}

abstract interface class AppTimeoutRuleRepository {
  List<AppTimeoutRule> listRules();

  AppTimeoutRule upsertRule(AppTimeoutRuleDraft draft);

  void deleteRule(int id);

  List<RunningApplication> refreshRunningApplications();
}

/// Generated-bridge implementation of the narrow reminder-rule repository.
final class RustAppTimeoutRuleRepository implements AppTimeoutRuleRepository {
  const RustAppTimeoutRuleRepository(this._api);

  final TimeTraceApi _api;

  @override
  List<AppTimeoutRule> listRules() {
    return _api.listAppTimeoutRules().map(appTimeoutRuleFromDto).toList();
  }

  @override
  AppTimeoutRule upsertRule(AppTimeoutRuleDraft draft) {
    final dto = _api.upsertAppTimeoutRule(
      draft: AppTimeoutRuleDraftDto(
        appPath: draft.executablePath,
        appName: draft.displayName,
        thresholdSecs: draft.threshold.inSeconds,
        cooldownSecs: draft.cooldown.inSeconds,
        enabled: draft.enabled,
        notifyRepeatedly: draft.repeatEnabled,
      ),
    );
    return appTimeoutRuleFromDto(dto);
  }

  @override
  void deleteRule(int id) => _api.deleteAppTimeoutRule(id: id);

  @override
  List<RunningApplication> refreshRunningApplications() {
    return _api
        .listRunningApps()
        .map(runningApplicationFromDto)
        .where((application) => application != null)
        .cast<RunningApplication>()
        .toList(growable: false);
  }
}

AppTimeoutRule appTimeoutRuleFromDto(AppTimeoutRuleDto dto) {
  return AppTimeoutRule(
    id: dto.id.toInt(),
    executablePath: dto.appPath,
    displayName: safeDisplayLabel(dto.appName),
    threshold: Duration(seconds: dto.thresholdSecs.toInt()),
    cooldown: Duration(seconds: dto.cooldownSecs.toInt()),
    enabled: dto.enabled,
    repeatEnabled: dto.notifyRepeatedly,
  );
}

RunningApplication? runningApplicationFromDto(RunningAppDto dto) {
  final path = dto.appPath.trim();
  final name = dto.appName.trim();
  if (path.isEmpty || name.isEmpty) {
    return null;
  }
  return RunningApplication(
    executablePath: path,
    displayName: safeDisplayLabel(name),
  );
}
