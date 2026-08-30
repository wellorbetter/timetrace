import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';
import 'package:timetrace_app/src/features/app_limits/data/app_timeout_rule_repository.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_rule_dialog.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_rules_section.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_view_models.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';

/// Connects timeout-rule persistence to the provider-free rule widgets.
class AppTimeoutRulesControllerSection extends ConsumerStatefulWidget {
  const AppTimeoutRulesControllerSection({required this.settings, super.key});

  final AppTimeoutSettings settings;

  @override
  ConsumerState<AppTimeoutRulesControllerSection> createState() =>
      _AppTimeoutRulesControllerSectionState();
}

class _AppTimeoutRulesControllerSectionState
    extends ConsumerState<AppTimeoutRulesControllerSection> {
  bool _busy = false;
  _RuleError? _operationError;

  @override
  Widget build(BuildContext context) {
    final asyncRules = ref.watch(appTimeoutRulesProvider);
    final notifier = ref.read(appTimeoutRulesProvider.notifier);
    final data = asyncRules.value ?? notifier.lastSuccessfulState;
    final rules = data?.rules ?? const <AppTimeoutRule>[];
    final byId = {for (final rule in rules) rule.id: rule};
    final strings = ReminderL10n(ref.watch(localeProvider));

    return AppTimeoutRulesSection(
      strings: strings,
      rules: rules.map(_ruleViewModel).toList(growable: false),
      remindersEnabled: widget.settings.enabled,
      busy: _busy || asyncRules.isLoading,
      errorText:
          _operationError?.text(strings) ??
          (asyncRules.hasError ? strings.ruleOperationFailed : null),
      onAdd: data == null ? null : () => _openEditor(),
      onEdit: (viewModel) {
        final rule = byId[viewModel.id];
        if (rule != null) unawaited(_openEditor(rule));
      },
      onDelete: (viewModel) {
        final rule = byId[viewModel.id];
        if (rule != null) unawaited(_confirmDelete(rule));
      },
      onEnabledChanged: (viewModel, enabled) {
        final rule = byId[viewModel.id];
        if (rule != null) unawaited(_setEnabled(rule, enabled));
      },
      onRetry: data == null && asyncRules.hasError
          ? () {
              setState(() => _operationError = null);
              ref.invalidate(appTimeoutRulesProvider);
            }
          : null,
    );
  }

  Future<void> _openEditor([AppTimeoutRule? rule]) async {
    setState(() => _operationError = null);
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AppTimeoutRuleEditorController(
        initialRule: rule,
        defaultThresholdMinutes: widget.settings.defaultThresholdMinutes,
        defaultCooldownMinutes: widget.settings.defaultCooldownMinutes,
      ),
    );
  }

  Future<void> _setEnabled(AppTimeoutRule rule, bool enabled) async {
    await _runOperation(() {
      return ref
          .read(appTimeoutRulesProvider.notifier)
          .upsert(
            AppTimeoutRuleDraft(
              executablePath: rule.executablePath,
              displayName: safeDisplayLabel(rule.displayName),
              threshold: rule.threshold,
              cooldown: rule.cooldown,
              enabled: enabled,
              repeatEnabled: rule.repeatEnabled,
            ),
          );
    });
  }

  Future<void> _confirmDelete(AppTimeoutRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final strings = ReminderL10n(ref.read(localeProvider));
        final name = strings.applicationName(rule.displayName);
        return AlertDialog(
          key: const ValueKey('delete-app-timeout-rule-dialog'),
          title: Text(strings.deleteRuleTitle),
          content: Text(strings.deleteRuleConfirmation(name)),
          actions: [
            TextButton(
              key: const ValueKey('cancel-delete-app-timeout-rule'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const ValueKey('confirm-delete-app-timeout-rule'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.delete),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _runOperation(
      () => ref.read(appTimeoutRulesProvider.notifier).delete(rule.id),
    );
  }

  Future<void> _runOperation(Future<Object?> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _operationError = null;
    });
    try {
      await operation();
    } catch (error, stackTrace) {
      AppLogger.log(
        'Application reminder rule operation failed: '
        '$error\n$stackTrace',
      );
      if (mounted) {
        setState(() => _operationError = _RuleError.operation);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _AppTimeoutRuleEditorController extends ConsumerStatefulWidget {
  const _AppTimeoutRuleEditorController({
    required this.defaultThresholdMinutes,
    required this.defaultCooldownMinutes,
    this.initialRule,
  });

  final AppTimeoutRule? initialRule;
  final int defaultThresholdMinutes;
  final int defaultCooldownMinutes;

  @override
  ConsumerState<_AppTimeoutRuleEditorController> createState() =>
      _AppTimeoutRuleEditorControllerState();
}

class _AppTimeoutRuleEditorControllerState
    extends ConsumerState<_AppTimeoutRuleEditorController> {
  bool _refreshing = false;
  bool _saving = false;
  _RuleError? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshRunningApplications());
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncRules = ref.watch(appTimeoutRulesProvider);
    final notifier = ref.read(appTimeoutRulesProvider.notifier);
    final data = asyncRules.value ?? notifier.lastSuccessfulState;
    final initialRule = widget.initialRule;
    final runningApplications =
        data?.runningApplications
            .where(
              (application) =>
                  initialRule == null ||
                  application.executablePath == initialRule.executablePath,
            )
            .map(_runningApplicationViewModel)
            .toList(growable: false) ??
        const <RunningApplicationViewModel>[];
    final rules = data?.rules ?? const <AppTimeoutRule>[];
    final strings = ReminderL10n(ref.watch(localeProvider));

    return AppTimeoutRuleDialog(
      strings: strings,
      runningApplications: runningApplications,
      initialValue: initialRule == null ? null : _draftViewModel(initialRule),
      duplicateApplicationKeys: rules
          .map((rule) => rule.executablePath)
          .toSet(),
      defaultThresholdMinutes: widget.defaultThresholdMinutes,
      defaultCooldownMinutes: widget.defaultCooldownMinutes,
      saving: _refreshing || _saving,
      errorText:
          _error?.text(strings) ??
          (asyncRules.hasError ? strings.runningAppsRefreshFailed : null),
      onRefreshRunningApps: () => unawaited(_refreshRunningApplications()),
      onSubmit: (draft) => unawaited(_save(draft)),
    );
  }

  Future<void> _refreshRunningApplications() async {
    if (_refreshing || _saving) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await ref
          .read(appTimeoutRulesProvider.notifier)
          .refreshRunningApplications();
    } catch (error, stackTrace) {
      AppLogger.log(
        'Refreshing running applications failed: '
        '$error\n$stackTrace',
      );
      if (mounted) {
        setState(() => _error = _RuleError.refresh);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _save(AppTimeoutRuleDraftViewModel viewModel) async {
    if (_saving || _refreshing) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final initialRule = widget.initialRule;
    final executablePath =
        initialRule?.executablePath ?? viewModel.applicationKey;
    final displayName = initialRule == null
        ? _safeDisplayName(viewModel.displayName)
        : _safeDisplayName(initialRule.displayName);
    try {
      await ref
          .read(appTimeoutRulesProvider.notifier)
          .upsert(
            AppTimeoutRuleDraft(
              executablePath: executablePath,
              displayName: displayName,
              threshold: Duration(minutes: viewModel.thresholdMinutes),
              cooldown: Duration(minutes: viewModel.cooldownMinutes),
              enabled: viewModel.enabled,
              repeatEnabled: viewModel.repeatEnabled,
            ),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stackTrace) {
      AppLogger.log(
        'Saving application reminder rule failed: '
        '$error\n$stackTrace',
      );
      if (mounted) {
        setState(() => _error = _RuleError.save);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

AppTimeoutRuleViewModel _ruleViewModel(AppTimeoutRule rule) {
  return AppTimeoutRuleViewModel(
    id: rule.id,
    applicationKey: rule.executablePath,
    displayName: _safeDisplayName(rule.displayName),
    thresholdMinutes: rule.threshold.inMinutes,
    cooldownMinutes: rule.cooldown.inMinutes,
    enabled: rule.enabled,
    repeatEnabled: rule.repeatEnabled,
  );
}

RunningApplicationViewModel _runningApplicationViewModel(
  RunningApplication application,
) {
  return RunningApplicationViewModel(
    applicationKey: application.executablePath,
    displayName: _safeDisplayName(application.displayName),
  );
}

AppTimeoutRuleDraftViewModel _draftViewModel(AppTimeoutRule rule) {
  return AppTimeoutRuleDraftViewModel(
    id: rule.id,
    applicationKey: rule.executablePath,
    displayName: _safeDisplayName(rule.displayName),
    thresholdMinutes: rule.threshold.inMinutes,
    cooldownMinutes: rule.cooldown.inMinutes,
    enabled: rule.enabled,
    repeatEnabled: rule.repeatEnabled,
  );
}

String _safeDisplayName(String value) {
  return safeDisplayLabel(value);
}

enum _RuleError {
  operation,
  refresh,
  save;

  String text(ReminderL10n strings) => switch (this) {
    operation => strings.ruleOperationFailed,
    refresh => strings.runningAppsRefreshFailed,
    save => strings.ruleSaveFailed,
  };
}
