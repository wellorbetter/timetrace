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
                'AI 服务',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: colors.surface.withValues(alpha: 0.72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ProviderRow(status: state.status),
                const SizedBox(height: 16),
                Divider(height: 1, color: colors.outlineVariant),
                const SizedBox(height: 16),
                _CredentialEditor(
                  controller: _apiKeyController,
                  state: state,
                  onSave: _saveApiKey,
                  onImport: _importEnvironmentApiKey,
                  onRemove: _confirmRemoveApiKey,
                ),
                const SizedBox(height: 20),
                Text(
                  '默认模型',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SegmentedButton<AiRecapModel>(
                  key: const ValueKey('ai-default-model-selector'),
                  segments: const [
                    ButtonSegment(
                      value: AiRecapModel.flash,
                      label: Text('快速（Flash）'),
                      icon: Icon(Icons.bolt_outlined),
                    ),
                    ButtonSegment(
                      value: AiRecapModel.pro,
                      label: Text('深度（Pro）'),
                      icon: Icon(Icons.psychology_outlined),
                    ),
                  ],
                  selected: {state.status.defaultModel},
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  onSelectionChanged:
                      state.busy || !state.status.serviceAvailable
                      ? null
                      : (selection) async {
                          await _setDefaultModel(selection.first);
                        },
                ),
                const SizedBox(height: 6),
                Text(
                  state.status.defaultModel == AiRecapModel.flash
                      ? 'Flash 适合快速生成日报；可随时在这里切换默认模型。'
                      : 'Pro 适合需要更深入观察的周报和月报。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                _ConnectionTest(state: state, onTest: _testConnection),
                if (state.failure != null) ...[
                  const SizedBox(height: 12),
                  _InlineMessage(
                    icon: Icons.error_outline,
                    color: colors.error,
                    text: _failureMessage(state.failure!),
                  ),
                ] else if (state.connectionTestSucceeded == true) ...[
                  const SizedBox(height: 12),
                  _InlineMessage(
                    icon: Icons.check_circle_outline,
                    color: colors.primary,
                    text: '连接成功，可以生成报告。',
                  ),
                ],
              ],
            ),
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
        .setDefaultModel(model);
    if (!mounted) return;
    if (updated) _showMessage('默认模型已更新');
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
  const _ProviderRow({required this.status});

  final AiRecapProviderStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.cloud_outlined, color: colors.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DeepSeek',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                _statusDescription(status),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _StatusBadge(status: status),
      ],
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
        Text(
          'API Key',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          hasStoredKey
              ? '密钥已安全保存在本机。输入新密钥可直接替换；已保存内容不会重新显示。'
              : '密钥将安全保存在本机，不会写入普通配置、日志或报告。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
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
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('ai-test-connection-button'),
          onPressed: state.status.configured && !state.busy ? onTest : null,
          icon: testing
              ? _ButtonProgress(color: colors.primary)
              : const Icon(Icons.wifi_tethering_outlined),
          label: Text(testing ? '正在测试连接…' : '测试连接'),
        ),
        Text(
          '测试只验证服务连接，不会发送任何使用数据。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
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
    AiCredentialSource.unavailable => 'AI 服务暂时不可用；TimeTrace 的记录与统计不受影响。',
  };
}

String _failureMessage(AiCredentialFailureCode code) => switch (code) {
  AiCredentialFailureCode.notConfigured => '还未配置 DeepSeek API Key，请先保存或导入密钥。',
  AiCredentialFailureCode.invalidKey => '请输入有效的 DeepSeek API Key。',
  AiCredentialFailureCode.unsupportedModel => '所选模型暂不受支持，请重新选择 Flash 或 Pro。',
  AiCredentialFailureCode.secureStorageUnavailable => '无法访问本机安全凭据存储，请稍后重试。',
  AiCredentialFailureCode.localStorageUnavailable => '无法保存 AI 设置，请检查本机存储后重试。',
  AiCredentialFailureCode.authentication => 'DeepSeek 未接受此 API Key，请检查后重新保存。',
  AiCredentialFailureCode.network => '暂时无法连接 DeepSeek，请检查网络后重试。',
  AiCredentialFailureCode.timeout => '连接 DeepSeek 超时，请稍后重试。',
  AiCredentialFailureCode.rateLimited => 'DeepSeek 请求较多，请稍后再测试连接。',
  AiCredentialFailureCode.providerUnavailable => 'DeepSeek 服务暂时不可用，请稍后重试。',
  AiCredentialFailureCode.invalidResponse => 'DeepSeek 返回了无法识别的结果，请稍后重试。',
  AiCredentialFailureCode.busy => '已有 AI 操作正在进行，请稍后再试。',
  AiCredentialFailureCode.bridgeUnavailable =>
    'AI 服务组件暂时不可用，请重启 TimeTrace 后重试。',
};
