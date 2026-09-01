import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_view_models.dart';

/// A provider-free timeout-rule list.
///
/// It intentionally renders no executable identity, full path, or window
/// title. Hosts receive the selected view model through callbacks.
class AppTimeoutRulesSection extends StatelessWidget {
  const AppTimeoutRulesSection({
    this.strings = ReminderL10n.zh,
    this.rules = const [],
    this.remindersEnabled = false,
    this.busy = false,
    this.errorText,
    this.onAdd,
    this.onEdit,
    this.onDelete,
    this.onEnabledChanged,
    this.onRetry,
    super.key,
  });

  final ReminderL10n strings;
  final List<AppTimeoutRuleViewModel> rules;
  final bool remindersEnabled;
  final bool busy;
  final String? errorText;
  final VoidCallback? onAdd;
  final ValueChanged<AppTimeoutRuleViewModel>? onEdit;
  final ValueChanged<AppTimeoutRuleViewModel>? onDelete;
  final void Function(AppTimeoutRuleViewModel rule, bool enabled)?
  onEnabledChanged;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Card(
      key: const ValueKey('app-timeout-rules-section'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.md),
            child: Row(
              children: [
                Expanded(
                  child: SectionTitle(
                    icon: Icons.apps_outlined,
                    title: strings.rulesTitle,
                  ),
                ),
                if (!remindersEnabled)
                  Padding(
                    padding: const EdgeInsets.only(right: TimeTraceSpace.xs),
                    child: Text(
                      strings.globalSwitchOff,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                Tooltip(
                  message: strings.addRuleTooltip,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('add-app-timeout-rule'),
                    onPressed: busy ? null : onAdd,
                    icon: const Icon(Icons.add_rounded, size: 17),
                    label: Text(strings.add),
                  ),
                ),
              ],
            ),
          ),
          if (errorText?.trim().isNotEmpty ?? false)
            Container(
              key: const ValueKey('app-timeout-rules-error'),
              margin: const EdgeInsets.fromLTRB(
                TimeTraceSpace.md,
                0,
                TimeTraceSpace.md,
                TimeTraceSpace.sm,
              ),
              padding: const EdgeInsets.all(TimeTraceSpace.sm),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(TimeTraceRadius.control),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: scheme.error),
                  const SizedBox(width: TimeTraceSpace.xs),
                  Expanded(child: Text(errorText!)),
                  if (onRetry != null) ...[
                    const SizedBox(width: TimeTraceSpace.xs),
                    TextButton.icon(
                      key: const ValueKey('retry-app-timeout-rules'),
                      onPressed: busy ? null : onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: Text(strings.retry),
                    ),
                  ],
                ],
              ),
            ),
          const Divider(height: 1),
          if (rules.isEmpty)
            Padding(
              key: const ValueKey('app-timeout-rules-empty'),
              padding: const EdgeInsets.all(TimeTraceSpace.lg),
              child: Column(
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 28,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  Text(
                    strings.noRules,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: TimeTraceSpace.xxs),
                  Text(
                    strings.noRulesSubtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            for (var index = 0; index < rules.length; index++) ...[
              _RuleTile(
                key: ValueKey('app-timeout-rule-${rules[index].id}'),
                rule: rules[index],
                busy: busy,
                onEdit: onEdit,
                onDelete: onDelete,
                onEnabledChanged: onEnabledChanged,
                strings: strings,
              ),
              if (index != rules.length - 1) const Divider(height: 1),
            ],
        ],
      ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
    required this.onEnabledChanged,
    required this.strings,
    super.key,
  });

  final AppTimeoutRuleViewModel rule;
  final bool busy;
  final ValueChanged<AppTimeoutRuleViewModel>? onEdit;
  final ValueChanged<AppTimeoutRuleViewModel>? onDelete;
  final void Function(AppTimeoutRuleViewModel rule, bool enabled)?
  onEnabledChanged;
  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final title = strings.applicationName(rule.displayName);
    final details = rule.repeatEnabled
        ? strings.repeatingRuleDetails(
            rule.thresholdMinutes,
            rule.cooldownMinutes,
          )
        : strings.singleRuleDetails(rule.thresholdMinutes);

    final information = Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.52),
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          ),
          child: Icon(Icons.desktop_windows_outlined, color: scheme.primary),
        ),
        const SizedBox(width: TimeTraceSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                details,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: strings.ruleToggleSemantics(title, rule.enabled),
          child: Switch(
            key: ValueKey('app-timeout-rule-toggle-${rule.id}'),
            value: rule.enabled,
            onChanged: busy || onEnabledChanged == null
                ? null
                : (value) => onEnabledChanged!(rule, value),
          ),
        ),
        Tooltip(
          message: strings.editRuleTooltip(title),
          child: IconButton(
            key: ValueKey('app-timeout-rule-edit-${rule.id}'),
            onPressed: busy || onEdit == null ? null : () => onEdit!(rule),
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
        Tooltip(
          message: strings.deleteRuleTooltip(title),
          child: IconButton(
            key: ValueKey('app-timeout-rule-delete-${rule.id}'),
            onPressed: busy || onDelete == null ? null : () => onDelete!(rule),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.md,
        vertical: TimeTraceSpace.sm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                information,
                const SizedBox(height: TimeTraceSpace.xs),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: information),
              const SizedBox(width: TimeTraceSpace.sm),
              actions,
            ],
          );
        },
      ),
    );
  }
}
