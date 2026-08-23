import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/plugin_platform/bundled/bundled.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/rendering.dart';

/// Generic host route for every canonical plugin page contribution.
class PluginPageHost extends ConsumerWidget {
  const PluginPageHost({
    required this.pluginId,
    required this.viewId,
    super.key,
  });

  final String pluginId;
  final String viewId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(contributionControllerProvider);
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => _UnavailablePage(
        title: '扩展暂不可用',
        message: '插件状态无法安全读取，相关页面已暂时隐藏。',
        actionLabel: '重试',
        onAction: () => ref.invalidate(contributionControllerProvider),
      ),
      data: (snapshot) => _buildSnapshot(context, ref, snapshot),
    );
  }

  Widget _buildSnapshot(
    BuildContext context,
    WidgetRef ref,
    ContributionSnapshot snapshot,
  ) {
    final route = '/extensions/$pluginId/$viewId';
    final page = snapshot.pages
        .where(
          (candidate) =>
              candidate.pluginId == pluginId && candidate.route == route,
        )
        .firstOrNull;
    if (page != null) {
      if (page.rendererMode == 'declarative_v1') {
        final document = page.declarativeDocument;
        if (document == null) {
          return const Scaffold(body: Center(child: declarativeV1Unavailable));
        }
        return Scaffold(
          appBar: AppBar(title: Text(page.title)),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: DeclarativeV1Renderer(document: document),
          ),
        );
      }
      if (page.rendererMode != 'bundled_typed' ||
          page.rendererContractId == null ||
          page.rendererSchemaVersion == null) {
        return const Scaffold(
          body: Center(
            child: PluginRendererErrorPlaceholder(
              failure: RendererFailure.unknownContract,
            ),
          ),
        );
      }
      return bundledPluginRendererRegistry.render(
        RenderEnvelope(
          contributionId: page.contributionId,
          contractId: page.rendererContractId!,
          schemaVersion: page.rendererSchemaVersion!,
          routeParameters: {'pluginId': pluginId, 'viewId': viewId},
        ),
      );
    }

    final plugin = snapshot.pluginsById[pluginId];
    if (plugin == null) {
      return const _UnavailablePage(
        title: '未找到扩展',
        message: '这个扩展没有注册到当前 TimeTrace 主机。',
      );
    }
    final declaredView = plugin.manifest.contributions.any(
      (contribution) =>
          contribution.kind == 'page' &&
          contribution.descriptor['view_id'] == viewId,
    );
    if (!declaredView) {
      return const _UnavailablePage(
        title: 'Extension page not found',
        message: 'This page is not declared by the extension manifest.',
      );
    }
    if (plugin.desiredState == CanonicalDesiredState.disabled) {
      return _UnavailablePage(
        title: '${plugin.manifest.displayName} 已禁用',
        message: '启用后才会显示它的导航和页面。',
        actionLabel: '启用扩展',
        onAction: () => unawaited(
          ref
              .read(contributionControllerProvider.notifier)
              .setEnabled(pluginId, true),
        ),
      );
    }
    final detail = switch (plugin.runtimeState) {
      CanonicalRuntimeState.incompatible => '当前版本或平台不兼容。',
      CanonicalRuntimeState.failed => '扩展启动失败，已与其他功能隔离。',
      CanonicalRuntimeState.starting => '扩展正在启动。',
      CanonicalRuntimeState.stopping => '扩展正在停止。',
      _ => '扩展当前没有可显示的页面。',
    };
    return _UnavailablePage(
      title: plugin.manifest.displayName,
      message: detail,
    );
  }
}

class _UnavailablePage extends StatelessWidget {
  const _UnavailablePage({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.extension_off_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 20),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
