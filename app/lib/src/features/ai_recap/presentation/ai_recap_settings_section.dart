import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';

class AiRecapSettingsSection extends ConsumerStatefulWidget {
  const AiRecapSettingsSection({super.key});

  @override
  ConsumerState<AiRecapSettingsSection> createState() =>
      _AiRecapSettingsSectionState();
}

class _AiRecapSettingsSectionState
    extends ConsumerState<AiRecapSettingsSection> {
  final TextEditingController _apiKeyController = TextEditingController();

  @override
  void dispose() {
    _apiKeyController.clear();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiCredentialControllerProvider);
    final preferences = ref.watch(aiDiaryPreferencesProvider);
    final colors = Theme.of(context).colorScheme;
    final selectedProvider = state.status.selectedProviderOption;

    return Column(
      key: const ValueKey('ai-service-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 18,
                color: colors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '智能回顾',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('ai-recap-enabled-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: const Text('启用智能回顾'),
          subtitle: const Text('开启后，可在日记区域生成每日、每周或每月回顾。'),
          value: preferences.enabled,
          onChanged: (enabled) {
            ref.read(aiDiaryPreferencesProvider.notifier).setEnabled(enabled);
          },
        ),
        if (preferences.enabled) ...[
          const Divider(indent: 12, endIndent: 12),
          _ProviderSelector(
            status: state.status,
            enabled: !state.busy && state.status.serviceAvailable,
            onSelected: _setProvider,
          ),
          const SizedBox(height: 8),
          if ((selectedProvider?.models.length ?? 0) == 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _ReadOnlyModelCard(
                key: const ValueKey('ai-fixed-model'),
                option: selectedProvider!.models.single,
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                '选择模型',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              key: const ValueKey('ai-default-model-selector'),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: [
                  for (final model in selectedProvider?.models ?? const []) ...[
                    _ModelTile(
                      option: model,
                      selected: state.status.selectedModel == model.model,
                      enabled: !state.busy && state.status.serviceAvailable,
                      onSelected: _setDefaultModel,
                    ),
                    if (model != selectedProvider?.models.last)
                      const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
          if (state.status.requiresApiKey) ...[
            const Divider(indent: 12, endIndent: 12),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('API Key'),
              subtitle: Text(_statusDescription(state.status)),
              trailing: _StatusBadge(status: state.status),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _CredentialEditor(
                controller: _apiKeyController,
                state: state,
                onSave: _saveApiKey,
                onImport: _importEnvironmentApiKey,
                onRemove: _confirmRemoveApiKey,
              ),
            ),
          ],
          if (state.status.supportsConnectionTest) ...[
            const Divider(indent: 12, endIndent: 12),
            _ConnectionTest(state: state, onTest: _testConnection),
          ],
          if (state.failure != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _InlineMessage(
                icon: Icons.error_outline,
                color: colors.error,
                text: _failureMessage(state.failure!),
              ),
            )
          else if (state.connectionTestSucceeded == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _InlineMessage(
                icon: Icons.check_circle_outline,
                color: colors.primary,
                text: '连接成功，可以生成回顾。',
              ),
            ),
          const Divider(indent: 12, endIndent: 12),
          _DiaryCoverSettings(
            preferences: preferences,
            onSelectBuiltIn: (coverId) {
              ref
                  .read(aiDiaryPreferencesProvider.notifier)
                  .selectBuiltIn(coverId);
            },
            onPickCustom: _pickCustomCover,
            onSelectNone: () {
              ref.read(aiDiaryPreferencesProvider.notifier).setNone();
            },
            onRemoveCustom: _removeCustomCover,
          ),
        ],
      ],
    );
  }

  Future<void> _saveApiKey() async {
    final apiKey = _apiKeyController.text;
    _apiKeyController.clear();
    final saved = await ref
        .read(aiCredentialControllerProvider.notifier)
        .saveApiKey(apiKey);
    if (!mounted) return;
    if (saved) {
      _showMessage('API Key 已安全保存');
    }
  }

  Future<void> _importEnvironmentApiKey() async {
    final imported = await ref
        .read(aiCredentialControllerProvider.notifier)
        .importEnvironmentApiKey();
    if (!mounted) return;
    if (imported) _showMessage('环境变量中的 API Key 已安全导入');
  }

  Future<void> _confirmRemoveApiKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除 API Key？'),
        content: const Text(
          '只会移除 TimeTrace 保存的系统凭据；已有报告不会受到影响。若系统仍设置了 '
          'DEEPSEEK_API_KEY，应用会继续使用该环境变量。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await ref
        .read(aiCredentialControllerProvider.notifier)
        .removeApiKey();
    if (!mounted) return;
    if (removed) {
      _apiKeyController.clear();
      final source = ref
          .read(aiCredentialControllerProvider)
          .status
          .credentialSource;
      _showMessage(
        source == AiCredentialSource.legacyEnvironment
            ? '系统凭据已移除，当前继续使用环境变量'
            : 'API Key 已移除',
      );
    }
  }

  Future<void> _setDefaultModel(AiRecapModel model) async {
    final updated = await ref
        .read(aiCredentialControllerProvider.notifier)
        .setProviderSelection(
          ref.read(aiCredentialControllerProvider).status.selectedProvider,
          model,
        );
    if (!mounted) return;
    if (updated) _showMessage('默认模型已更新');
  }

  Future<void> _setProvider(AiRecapProviderId provider) async {
    final status = ref.read(aiCredentialControllerProvider).status;
    final option = status.providers
        .where((candidate) => candidate.id == provider)
        .firstOrNull;
    final model = option?.models.firstOrNull?.model;
    if (model == null) return;
    await ref
        .read(aiCredentialControllerProvider.notifier)
        .setProviderSelection(provider, model);
  }

  Future<void> _testConnection() async {
    await ref.read(aiCredentialControllerProvider.notifier).testConnection();
  }

  Future<void> _pickCustomCover() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      if (!mounted || result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        _showMessage('未能读取所选图片，请重新选择。');
        return;
      }
      final imported = await ref
          .read(aiDiaryPreferencesProvider.notifier)
          .importCustomCover(path);
      if (!mounted) return;
      _showMessage(
        imported
            ? '自定义封面已保存到 TimeTrace。'
            : '未能导入图片，请选择 10 MB 以内的 PNG、JPG 或 WebP 文件。',
      );
    } catch (_) {
      if (!mounted) return;
      _showMessage('未能打开图片选择器，请稍后重试。');
    }
  }

  void _removeCustomCover() {
    ref.read(aiDiaryPreferencesProvider.notifier).setNone();
    _showMessage('自定义封面已移除。');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector({
    required this.status,
    required this.enabled,
    required this.onSelected,
  });

  final AiRecapProviderStatus status;
  final bool enabled;
  final ValueChanged<AiRecapProviderId> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('ai-provider-selector'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '生成方式',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '本地方式完全离线；使用云端前请确认愿意发送聚合后的应用名与时长。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final choices = [
                for (final provider in status.providers)
                  _ProviderChoiceCard(
                    option: provider,
                    selected: provider.id == status.selectedProvider,
                    enabled: enabled,
                    onTap: () {
                      if (provider.id != status.selectedProvider) {
                        onSelected(provider.id);
                      }
                    },
                  ),
              ];
              if (constraints.maxWidth >= 680) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < choices.length; index++) ...[
                      Expanded(child: choices[index]),
                      if (index != choices.length - 1)
                        const SizedBox(width: 10),
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  for (var index = 0; index < choices.length; index++) ...[
                    choices[index],
                    if (index != choices.length - 1) const SizedBox(height: 8),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ProviderChoiceCard extends StatelessWidget {
  const _ProviderChoiceCard({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final AiRecapProviderOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final local = option.id == AiRecapProviderId.localSummary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '生成方式：${option.displayName}',
      child: Material(
        key: ValueKey(
          local ? 'ai-provider-local-card' : 'ai-provider-deepseek-card',
        ),
        color: selected
            ? colors.secondaryContainer.withValues(alpha: 0.72)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primaryContainer
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    local ? Icons.offline_bolt_outlined : Icons.cloud_outlined,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              option.displayName,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: local
                                  ? colors.tertiaryContainer
                                  : colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              local ? '免费 · 本地' : '需 API Key',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        option.description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? colors.primary : colors.outline,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyModelCard extends StatelessWidget {
  const _ReadOnlyModelCard({super.key, required this.option});

  final AiRecapModelOption option;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_outlined),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('生成器版本', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  option.model.description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(option.displayName),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final AiRecapModelOption option;
  final bool selected;
  final bool enabled;
  final ValueChanged<AiRecapModel> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.secondaryContainer.withValues(alpha: 0.62)
          : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(
          option.model == AiRecapModel.flash
              ? Icons.bolt_outlined
              : option.model == AiRecapModel.pro
              ? Icons.psychology_outlined
              : Icons.computer_outlined,
        ),
        title: Text(option.displayName),
        subtitle: Text(option.model.description),
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? colors.primary : colors.outline,
        ),
        enabled: enabled,
        selected: selected,
        onTap: enabled ? () => onSelected(option.model) : null,
      ),
    );
  }
}

const _builtInCoverOptions = <_BuiltInCoverOption>[
  _BuiltInCoverOption(
    id: 'night_focus',
    title: '夜间专注',
    assetPath: 'assets/ai_diary/night_focus.jpg',
  ),
  _BuiltInCoverOption(
    id: 'warm_afternoon',
    title: '暖阳午后',
    assetPath: 'assets/ai_diary/warm_afternoon.jpg',
  ),
  _BuiltInCoverOption(
    id: 'rainy_evening',
    title: '雨夜回声',
    assetPath: 'assets/ai_diary/rainy_evening.jpg',
  ),
  _BuiltInCoverOption(
    id: 'spring_morning',
    title: '春日清晨',
    assetPath: 'assets/ai_diary/spring_morning.jpg',
  ),
];

class _BuiltInCoverOption {
  const _BuiltInCoverOption({
    required this.id,
    required this.title,
    required this.assetPath,
  });

  final String id;
  final String title;
  final String assetPath;
}

class _DiaryCoverSettings extends StatelessWidget {
  const _DiaryCoverSettings({
    required this.preferences,
    required this.onSelectBuiltIn,
    required this.onPickCustom,
    required this.onSelectNone,
    required this.onRemoveCustom,
  });

  final AiDiaryPreferences preferences;
  final ValueChanged<String> onSelectBuiltIn;
  final VoidCallback onPickCustom;
  final VoidCallback onSelectNone;
  final VoidCallback onRemoveCustom;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final customSelected = preferences.coverSource == AiDiaryCoverSource.custom;
    return Padding(
      key: const ValueKey('ai-diary-cover-settings'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.image_outlined, size: 19, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                '日记封面',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '封面用于智能日记卡。自定义图片会复制到 TimeTrace 的应用目录。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth < 560
                  ? (constraints.maxWidth - 10) / 2
                  : 158.0;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final option in _builtInCoverOptions)
                    SizedBox(
                      width: itemWidth,
                      child: _BuiltInCoverCard(
                        option: option,
                        selected:
                            preferences.coverSource ==
                                AiDiaryCoverSource.builtIn &&
                            preferences.builtInCoverId == option.id,
                        onTap: () => onSelectBuiltIn(option.id),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('ai-pick-custom-cover-button'),
                onPressed: onPickCustom,
                icon: Icon(
                  customSelected
                      ? Icons.check_circle_outline
                      : Icons.add_photo_alternate_outlined,
                ),
                label: Text(customSelected ? '更换本地图片' : '选择本地图片'),
              ),
              ChoiceChip(
                key: const ValueKey('ai-no-cover-choice'),
                avatar: const Icon(Icons.hide_image_outlined, size: 18),
                label: const Text('不显示封面'),
                selected: preferences.coverSource == AiDiaryCoverSource.none,
                onSelected: (_) => onSelectNone(),
              ),
            ],
          ),
          if (customSelected) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 19,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('正在使用已安全复制的自定义封面')),
                  TextButton(
                    key: const ValueKey('ai-remove-custom-cover-button'),
                    onPressed: onRemoveCustom,
                    child: const Text('移除'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BuiltInCoverCard extends StatelessWidget {
  const _BuiltInCoverCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _BuiltInCoverOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '日记封面：${option.title}',
      child: Material(
        key: ValueKey('ai-cover-${option.id}'),
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      option.assetPath,
                      fit: BoxFit.cover,
                      cacheWidth: 360,
                      cacheHeight: 225,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (context, error, stackTrace) => ColoredBox(
                        color: colors.surfaceContainerHighest,
                        child: Icon(
                          Icons.image_outlined,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (selected)
                      Positioned(
                        top: 7,
                        right: 7,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check,
                            size: 14,
                            color: colors.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                child: Text(
                  option.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final AiRecapProviderStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (
      icon,
      label,
      background,
      foreground,
    ) = switch (status.credentialSource) {
      AiCredentialSource.secureStore => (
        Icons.verified_user_outlined,
        '已连接',
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      AiCredentialSource.legacyEnvironment => (
        Icons.terminal_outlined,
        '环境变量',
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      AiCredentialSource.none => (
        Icons.key_off_outlined,
        '未配置',
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      AiCredentialSource.notRequired => (
        Icons.offline_bolt_outlined,
        '无需密钥',
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      AiCredentialSource.unavailable => (
        Icons.cloud_off_outlined,
        '不可用',
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };
    return Semantics(
      label: 'DeepSeek 连接状态：$label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: foreground),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: foreground)),
          ],
        ),
      ),
    );
  }
}

class _CredentialEditor extends StatelessWidget {
  const _CredentialEditor({
    required this.controller,
    required this.state,
    required this.onSave,
    required this.onImport,
    required this.onRemove,
  });

  final TextEditingController controller;
  final AiCredentialState state;
  final VoidCallback onSave;
  final VoidCallback onImport;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final status = state.status;
    final colors = Theme.of(context).colorScheme;
    final canEdit =
        status.serviceAvailable && status.secureStorageAvailable && !state.busy;
    final hasStoredKey =
        status.credentialSource == AiCredentialSource.secureStore;
    final saving = state.operation == AiCredentialOperation.save;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final field = TextField(
              key: const ValueKey('ai-api-key-field'),
              controller: controller,
              enabled: canEdit,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: canEdit ? (_) => onSave() : null,
              decoration: InputDecoration(
                labelText: hasStoredKey ? '输入新的 API Key' : '输入 API Key',
                hintText: 'sk-••••••••',
                prefixIcon: const Icon(Icons.key_outlined),
                border: const OutlineInputBorder(),
              ),
            );
            final button = FilledButton.icon(
              key: const ValueKey('ai-save-key-button'),
              onPressed: canEdit ? onSave : null,
              icon: saving
                  ? _ButtonProgress(color: colors.onPrimary)
                  : const Icon(Icons.lock_outline),
              label: Text(hasStoredKey ? '替换密钥' : '保存密钥'),
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [field, const SizedBox(height: 10), button],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field),
                const SizedBox(width: 12),
                SizedBox(height: 56, child: button),
              ],
            );
          },
        ),
        if (!status.secureStorageAvailable) ...[
          const SizedBox(height: 8),
          _InlineMessage(
            icon: Icons.lock_outline,
            color: colors.error,
            text: '本机安全凭据存储当前不可用，无法保存或导入 API Key。',
          ),
        ],
        if (status.environmentMigrationAvailable || hasStoredKey) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (status.environmentMigrationAvailable)
                TextButton.icon(
                  key: const ValueKey('ai-import-environment-button'),
                  onPressed: canEdit ? onImport : null,
                  icon:
                      state.operation == AiCredentialOperation.importEnvironment
                      ? _ButtonProgress(color: colors.primary)
                      : const Icon(Icons.move_to_inbox_outlined),
                  label: const Text('导入环境变量密钥'),
                ),
              if (hasStoredKey)
                TextButton.icon(
                  key: const ValueKey('ai-remove-key-button'),
                  onPressed: state.busy ? null : onRemove,
                  icon: state.operation == AiCredentialOperation.remove
                      ? _ButtonProgress(color: colors.error)
                      : Icon(Icons.delete_outline, color: colors.error),
                  label: Text('移除密钥', style: TextStyle(color: colors.error)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ConnectionTest extends StatelessWidget {
  const _ConnectionTest({required this.state, required this.onTest});

  final AiCredentialState state;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final testing = state.operation == AiCredentialOperation.testConnection;
    return ListTile(
      leading: const Icon(Icons.wifi_tethering_outlined),
      title: const Text('连接检查'),
      subtitle: const Text('只验证服务连接，不会发送任何使用数据。'),
      trailing: OutlinedButton.icon(
        key: const ValueKey('ai-test-connection-button'),
        onPressed: state.status.ready && !state.busy ? onTest : null,
        icon: testing
            ? _ButtonProgress(color: colors.primary)
            : const Icon(Icons.wifi_tethering_outlined),
        label: Text(testing ? '正在测试连接…' : '测试连接'),
      ),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _ButtonProgress extends StatelessWidget {
  const _ButtonProgress({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

String _statusDescription(AiRecapProviderStatus status) {
  return switch (status.credentialSource) {
    AiCredentialSource.secureStore => 'API Key 已保存在本机安全凭据中，TimeTrace 不会显示或记录它。',
    AiCredentialSource.legacyEnvironment => '当前使用系统环境变量中的 API Key，可主动导入到应用设置。',
    AiCredentialSource.none => '还未配置 API Key，配置后才能手动生成时间报告。',
    AiCredentialSource.notRequired => '本地生成无需 API Key，数据不会离开设备。',
    AiCredentialSource.unavailable => '报告生成暂时不可用；TimeTrace 的记录与统计不受影响。',
  };
}

String _failureMessage(AiCredentialFailureCode code) => switch (code) {
  AiCredentialFailureCode.notConfigured => '还未配置 DeepSeek API Key，请先保存或导入密钥。',
  AiCredentialFailureCode.invalidKey => '请输入有效的 DeepSeek API Key。',
  AiCredentialFailureCode.unsupportedProvider => '所选生成方式暂不受支持，请重新选择。',
  AiCredentialFailureCode.unsupportedModel => '所选模型暂不受支持，请重新选择 Flash 或 Pro。',
  AiCredentialFailureCode.providerNotReady => '所选生成方式尚未配置完成。',
  AiCredentialFailureCode.connectionTestNotSupported => '当前生成方式不需要测试连接。',
  AiCredentialFailureCode.secureStorageUnavailable => '无法访问本机安全凭据存储，请稍后重试。',
  AiCredentialFailureCode.localStorageUnavailable => '无法保存 AI 设置，请检查本机存储后重试。',
  AiCredentialFailureCode.authentication => 'DeepSeek 未接受此 API Key，请检查后重新保存。',
  AiCredentialFailureCode.network => '暂时无法连接 DeepSeek，请检查网络后重试。',
  AiCredentialFailureCode.timeout => '连接 DeepSeek 超时，请稍后重试。',
  AiCredentialFailureCode.rateLimited => 'DeepSeek 请求较多，请稍后再测试连接。',
  AiCredentialFailureCode.providerUnavailable => 'DeepSeek 服务暂时不可用，请稍后重试。',
  AiCredentialFailureCode.invalidResponse => 'DeepSeek 返回了无法识别的结果，请稍后重试。',
  AiCredentialFailureCode.busy => '已有 AI 操作正在进行，请稍后再试。',
  AiCredentialFailureCode.bridgeUnavailable => '报告生成组件暂时不可用，请重启 TimeTrace 后重试。',
};
