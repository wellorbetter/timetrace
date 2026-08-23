import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

const _aiRecapPageContributionId = 'ai-recap.page';

/// Narrow host boundary for the first-party AI Recap renderer.
///
/// The Marketplace package has no access to this provider or to Flutter-Rust
/// Bridge. Before reading even the safe status DTO, the adapter confirms that
/// the current host publication still projects the AI Recap page.
final aiRecapStatusProvider = FutureProvider<AiRecapStatusDto>((ref) async {
  final snapshot = ref.watch(contributionControllerProvider).value;
  final projectable = snapshot?.pages.any(
        (page) => page.contributionId == _aiRecapPageContributionId,
      ) ??
      false;
  if (!projectable) {
    throw StateError('plugin_not_projectable');
  }
  return ref.watch(apiProvider).aiRecapStatus();
});

/// Projects the entitlement-gated native status into a passive, safe setup
/// screen. It deliberately exposes no profile editing or secret entry point.
final class AiRecapHostAdapter extends ConsumerWidget {
  const AiRecapHostAdapter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(aiRecapStatusProvider);
    return status.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const AiRecapUnavailableScreen(),
      data: (value) => switch (value.state) {
        'configuration_required' => const AiRecapConfigurationRequiredScreen(),
        _ => const AiRecapUnavailableScreen(),
      },
    );
  }
}

/// Visible only after the verified entitlement has been installed, enabled,
/// granted, and projected by the native plugin host.
class AiRecapConfigurationRequiredScreen extends StatelessWidget {
  const AiRecapConfigurationRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Recap')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  '需要安全配置',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'AI Recap 已启用，但尚未配置受信任的 AI 提供方。'
                  '在完成本机安全配置前，不会读取使用记录、发送内容或生成摘要。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                const FilledButton.tonal(
                  onPressed: null,
                  child: Text('安全配置入口即将提供'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opaque fallback used on entitlement revocation, lifecycle races, or an
/// unexpected status token. It deliberately reveals no provider details.
class AiRecapUnavailableScreen extends StatelessWidget {
  const AiRecapUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('AI Recap 当前不可用。'),
      ),
    );
  }
}
