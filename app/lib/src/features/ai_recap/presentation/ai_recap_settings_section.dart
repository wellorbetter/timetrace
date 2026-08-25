import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';

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
                'AI 与报告',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        _ProviderRow(
          status: state.status,
          enabled: !state.busy && state.status.serviceAvailable,
          onSelected: _setProvider,
        ),
        const Divider(indent: 12, endIndent: 12),
        if ((selectedProvider?.models.length ?? 0) == 1)
          ListTile(
            key: const ValueKey('ai-fixed-model'),
            leading: const Icon(Icons.memory_outlined),
            title: const Text('生成器版本'),
            subtitle: Text(state.status.selectedModel.description),
            trailing: Text(selectedProvider!.models.single.displayName),
          )
        else ...[
          ListTile(
            leading: const Icon(Icons.tune_outlined),
            title: const Text('默认模型'),
            subtitle: Text(state.status.selectedModel.description),
          ),
          Column(
            key: const ValueKey('ai-default-model-selector'),
            children: [
              for (final model in selectedProvider?.models ?? const [])
                _ModelTile(
                  option: model,
                  selected: state.status.selectedModel == model.model,
                  enabled: !state.busy && state.status.serviceAvailable,
                  onSelected: _setDefaultModel,
                ),
            ],
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
              text: '连接成功，可以生成报告。',
            ),
          ),
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.status,
    required this.enabled,
    required this.onSelected,
  });

  final AiRecapProviderStatus status;
  final bool enabled;
  final ValueChanged<AiRecapProviderId> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('服务提供方'),
      subtitle: Text(
        status.selectedProviderOption?.description ?? '选择报告的生成方式。',
      ),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<AiRecapProviderId>(
          key: const ValueKey('ai-provider-selector'),
          value: status.selectedProvider,
          items: [
            for (final provider in status.providers)
              DropdownMenuItem(
                value: provider.id,
                child: Text(provider.displayName),
              ),
          ],
          onChanged: enabled
              ? (provider) {
                  if (provider != null && provider != status.selectedProvider) {
                    onSelected(provider);
                  }
                }
              : null,
        ),
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
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 52, right: 12),
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
      color: selected ? Theme.of(context).colorScheme.primary : null,
    ),
    enabled: enabled,
    selected: selected,
    onTap: enabled ? () => onSelected(option.model) : null,
  );
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
