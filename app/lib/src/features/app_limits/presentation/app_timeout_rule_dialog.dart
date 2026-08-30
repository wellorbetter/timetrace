import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_view_models.dart';

/// Searchable editor for one application timeout rule.
///
/// Application keys are used only as callback identities and are never
/// rendered. The host should provide display names and optional safe
/// qualifiers that contain no full paths or window titles.
class AppTimeoutRuleDialog extends StatefulWidget {
  const AppTimeoutRuleDialog({
    this.strings = ReminderL10n.zh,
    this.runningApplications = const [],
    this.initialValue,
    this.duplicateApplicationKeys = const {},
    this.defaultThresholdMinutes = 60,
    this.defaultCooldownMinutes = 30,
    this.duplicateErrorText,
    this.errorText,
    this.saving = false,
    this.onRefreshRunningApps,
    this.onSubmit,
    super.key,
  });

  final ReminderL10n strings;
  final List<RunningApplicationViewModel> runningApplications;
  final AppTimeoutRuleDraftViewModel? initialValue;
  final Set<String> duplicateApplicationKeys;
  final int defaultThresholdMinutes;
  final int defaultCooldownMinutes;
  final String? duplicateErrorText;
  final String? errorText;
  final bool saving;
  final VoidCallback? onRefreshRunningApps;
  final ValueChanged<AppTimeoutRuleDraftViewModel>? onSubmit;

  @override
  State<AppTimeoutRuleDialog> createState() => _AppTimeoutRuleDialogState();
}

class _AppTimeoutRuleDialogState extends State<AppTimeoutRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _search;
  late final TextEditingController _threshold;
  late final TextEditingController _cooldown;
  String? _selectedKey;
  late bool _enabled;
  late bool _repeatEnabled;
  String? _selectionError;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialValue;
    _search = TextEditingController()..addListener(_refreshSearch);
    _threshold = TextEditingController(
      text: (initial?.thresholdMinutes ?? widget.defaultThresholdMinutes)
          .clamp(1, 1440)
          .toString(),
    );
    _cooldown = TextEditingController(
      text: (initial?.cooldownMinutes ?? widget.defaultCooldownMinutes)
          .clamp(1, 1440)
          .toString(),
    );
    _selectedKey = initial?.applicationKey;
    _enabled = initial?.enabled ?? true;
    _repeatEnabled = initial?.repeatEnabled ?? false;
  }

  @override
  void dispose() {
    _search
      ..removeListener(_refreshSearch)
      ..dispose();
    _threshold.dispose();
    _cooldown.dispose();
    super.dispose();
  }

  void _refreshSearch() {
    if (mounted) setState(() {});
  }

  List<RunningApplicationViewModel> get _applications {
    final unique = <String, RunningApplicationViewModel>{};
    for (final app in widget.runningApplications) {
      if (app.applicationKey.trim().isEmpty || app.displayName.trim().isEmpty) {
        continue;
      }
      unique.putIfAbsent(
        app.applicationKey,
        () => RunningApplicationViewModel(
          applicationKey: app.applicationKey,
          displayName: widget.strings.applicationName(app.displayName),
          safeQualifier: _safeQualifier(app.safeQualifier),
        ),
      );
    }
    final initial = widget.initialValue;
    if (initial != null && !unique.containsKey(initial.applicationKey)) {
      unique[initial.applicationKey] = RunningApplicationViewModel(
        applicationKey: initial.applicationKey,
        displayName: widget.strings.applicationName(initial.displayName),
      );
    }
    final query = _search.text.trim().toLowerCase();
    final result = unique.values.where((app) {
      if (query.isEmpty) return true;
      final qualifier = _safeQualifier(app.safeQualifier)?.toLowerCase() ?? '';
      return app.displayName.toLowerCase().contains(query) ||
          qualifier.contains(query);
    }).toList();
    result.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
    return result;
  }

  bool _isDuplicate(String key) {
    if (widget.initialValue?.applicationKey == key) return false;
    return widget.duplicateApplicationKeys.contains(key);
  }

  RunningApplicationViewModel? get _selectedApplication {
    final key = _selectedKey;
    if (key == null) return null;
    for (final app in _applications) {
      if (app.applicationKey == key) return app;
    }
    final initial = widget.initialValue;
    if (initial?.applicationKey == key) {
      return RunningApplicationViewModel(
        applicationKey: initial!.applicationKey,
        displayName: widget.strings.applicationName(initial.displayName),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.initialValue != null;
    final applications = _applications;
    final compactFields = MediaQuery.sizeOf(context).width < 600;

    return AlertDialog(
      key: const ValueKey('app-timeout-rule-dialog'),
      title: Text(widget.strings.dialogTitle(editing)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('app-rule-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: widget.strings.searchRunningApps,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: widget.onRefreshRunningApps == null
                        ? null
                        : IconButton(
                            tooltip: widget.strings.refreshRunningApps,
                            onPressed: widget.saving
                                ? null
                                : widget.onRefreshRunningApps,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                  ),
                ),
                const SizedBox(height: TimeTraceSpace.sm),
                if (applications.isEmpty)
                  Container(
                    key: const ValueKey('running-apps-empty'),
                    padding: const EdgeInsets.all(TimeTraceSpace.md),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(
                        TimeTraceRadius.control,
                      ),
                    ),
                    child: Text(
                      widget.strings.noRunningApps,
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Container(
                    key: const ValueKey('running-apps-list'),
                    height: 176,
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(
                        TimeTraceRadius.control,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: RadioGroup<String>(
                      groupValue: _selectedKey,
                      onChanged: (value) {
                        if (widget.saving ||
                            value == null ||
                            _isDuplicate(value)) {
                          return;
                        }
                        setState(() {
                          _selectedKey = value;
                          _selectionError = null;
                        });
                      },
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (
                              var index = 0;
                              index < applications.length;
                              index++
                            ) ...[
                              _RunningAppOption(
                                app: applications[index],
                                duplicate: _isDuplicate(
                                  applications[index].applicationKey,
                                ),
                                saving: widget.saving,
                                duplicateErrorText:
                                    widget.duplicateErrorText ??
                                    widget.strings.duplicateRule,
                                strings: widget.strings,
                              ),
                              if (index != applications.length - 1)
                                const Divider(height: 1),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_selectionError != null) ...[
                  const SizedBox(height: TimeTraceSpace.xs),
                  Text(
                    _selectionError!,
                    key: const ValueKey('app-selection-error'),
                    style: TextStyle(color: scheme.error),
                  ),
                ],
                const SizedBox(height: TimeTraceSpace.md),
                if (compactFields) ...[
                  _MinuteField(
                    key: const ValueKey('app-rule-threshold'),
                    controller: _threshold,
                    label: widget.strings.threshold,
                    strings: widget.strings,
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  _MinuteField(
                    key: const ValueKey('app-rule-cooldown'),
                    controller: _cooldown,
                    label: widget.strings.repeatCooldown,
                    strings: widget.strings,
                    enabled: _repeatEnabled,
                  ),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _MinuteField(
                          key: const ValueKey('app-rule-threshold'),
                          controller: _threshold,
                          label: widget.strings.threshold,
                          strings: widget.strings,
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.sm),
                      Expanded(
                        child: _MinuteField(
                          key: const ValueKey('app-rule-cooldown'),
                          controller: _cooldown,
                          label: widget.strings.repeatCooldown,
                          strings: widget.strings,
                          enabled: _repeatEnabled,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: TimeTraceSpace.xs),
                SwitchListTile(
                  key: const ValueKey('app-rule-repeat'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.strings.allowRepeats),
                  subtitle: Text(widget.strings.allowRepeatsSubtitle),
                  value: _repeatEnabled,
                  onChanged: widget.saving
                      ? null
                      : (value) => setState(() => _repeatEnabled = value),
                ),
                SwitchListTile(
                  key: const ValueKey('app-rule-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.strings.enableRule),
                  subtitle: Text(widget.strings.enableRuleSubtitle),
                  value: _enabled,
                  onChanged: widget.saving
                      ? null
                      : (value) => setState(() => _enabled = value),
                ),
                if (widget.errorText?.trim().isNotEmpty ?? false)
                  Container(
                    key: const ValueKey('app-rule-external-error'),
                    padding: const EdgeInsets.all(TimeTraceSpace.sm),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(
                        TimeTraceRadius.control,
                      ),
                    ),
                    child: Text(widget.errorText!),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.saving
              ? null
              : () => Navigator.of(context).maybePop(),
          child: Text(widget.strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('save-app-timeout-rule'),
          onPressed: widget.saving || widget.onSubmit == null ? null : _submit,
          child: widget.saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.strings.save),
        ),
      ],
    );
  }

  void _submit() {
    final app = _selectedApplication;
    if (app == null) {
      setState(() => _selectionError = widget.strings.selectRunningApp);
      return;
    }
    if (_isDuplicate(app.applicationKey)) {
      setState(
        () => _selectionError =
            widget.duplicateErrorText ?? widget.strings.duplicateRule,
      );
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;

    widget.onSubmit!(
      AppTimeoutRuleDraftViewModel(
        id: widget.initialValue?.id,
        applicationKey: app.applicationKey,
        displayName: widget.strings.applicationName(app.displayName),
        thresholdMinutes: int.parse(_threshold.text),
        cooldownMinutes: _repeatEnabled
            ? int.parse(_cooldown.text)
            : (_parseMinutes(_cooldown.text) ?? widget.defaultCooldownMinutes)
                  .clamp(1, 1440),
        enabled: _enabled,
        repeatEnabled: _repeatEnabled,
      ),
    );
  }
}

class _RunningAppOption extends StatelessWidget {
  const _RunningAppOption({
    required this.app,
    required this.duplicate,
    required this.saving,
    required this.duplicateErrorText,
    required this.strings,
  });

  final RunningApplicationViewModel app;
  final bool duplicate;
  final bool saving;
  final String duplicateErrorText;
  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    final qualifier = _safeQualifier(app.safeQualifier);
    return RadioListTile<String>(
      key: ValueKey('running-app-option-${app.applicationKey.hashCode}'),
      value: app.applicationKey,
      enabled: !duplicate && !saving,
      title: Text(
        strings.applicationName(app.displayName),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        duplicate ? duplicateErrorText : qualifier ?? strings.ruleAvailable,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _MinuteField extends StatelessWidget {
  const _MinuteField({
    required this.controller,
    required this.label,
    required this.strings,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final ReminderL10n strings;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        suffixText: strings.minutesShort,
        helperText: '1–1440',
      ),
      validator: (value) {
        if (!enabled) return null;
        final minutes = _parseMinutes(value);
        if (minutes == null || minutes < 1 || minutes > 1440) {
          return strings.invalidMinutes;
        }
        return null;
      },
    );
  }
}

int? _parseMinutes(String? value) => int.tryParse(value?.trim() ?? '');

String? _safeQualifier(String? value) {
  final qualifier = value?.trim();
  if (qualifier == null || qualifier.isEmpty) return null;
  if (qualifier.contains('\\') ||
      qualifier.contains('/') ||
      qualifier.contains(':')) {
    return null;
  }
  final safe = safeDisplayLabel(qualifier, fallback: '');
  return safe.isEmpty ? null : safe;
}
