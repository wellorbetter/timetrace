library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'marketplace_controller.dart';
import 'marketplace_models.dart';
import 'marketplace_port.dart';

class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({required this.port, super.key});

  final MarketplaceCatalogPort port;

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  late final MarketplaceCatalogController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MarketplaceCatalogController(widget.port)..load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('插件商店')),
    body: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => switch (_controller.state) {
        MarketplaceListState.initial || MarketplaceListState.loading =>
          const Center(child: CircularProgressIndicator()),
        MarketplaceListState.failed => Center(
          child: TextButton(
            onPressed: _controller.load,
            child: const Text('目录暂不可用，重试'),
          ),
        ),
        MarketplaceListState.ready => _CatalogList(
          port: widget.port,
          plugins: _controller.snapshot!.plugins,
          canLoadMore: _controller.canLoadMore,
          isLoadingMore: _controller.isLoadingMore,
          onLoadMore: _controller.loadMore,
        ),
      },
    ),
  );
}

class _CatalogList extends StatelessWidget {
  const _CatalogList({
    required this.port,
    required this.plugins,
    required this.canLoadMore,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final MarketplaceCatalogPort port;
  final List<MarketplacePluginSummary> plugins;
  final bool canLoadMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (plugins.isEmpty) return const Center(child: Text('暂无可用插件'));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: plugins.length + (canLoadMore || isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == plugins.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: isLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: onLoadMore,
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        final plugin = plugins[index];
        return Card(
          child: ListTile(
            title: Text(plugin.displayName),
            subtitle: Text('${plugin.summary}\n${_compatibilityLabel(plugin)}'),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(
              'marketplace-detail',
              pathParameters: {
                'publisherId': plugin.publisherId.value,
                'pluginId': plugin.id.value,
              },
            ),
          ),
        );
      },
    );
  }

  String _compatibilityLabel(MarketplacePluginSummary plugin) {
    if (!plugin.compatibility.allowsInstall) return '不兼容或状态未知';
    if (!plugin.risk.isKnown) return '风险信息未知，已阻止安装';
    return 'v${plugin.version}';
  }
}

class MarketplaceDetailScreen extends StatefulWidget {
  const MarketplaceDetailScreen({
    required this.port,
    required this.publisherId,
    required this.pluginId,
    super.key,
  });

  final MarketplaceCatalogPort port;
  final MarketplacePublisherId publisherId;
  final MarketplacePluginId pluginId;

  @override
  State<MarketplaceDetailScreen> createState() =>
      _MarketplaceDetailScreenState();
}

/// Stable fail-closed destination for invalid or unavailable deep links.
///
/// This intentionally has no retry/install action. A valid route still needs
/// the typed host detail response before installation can become possible.
class MarketplaceUnavailableScreen extends StatelessWidget {
  const MarketplaceUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('此插件当前不可用')));
}

class _MarketplaceDetailScreenState extends State<MarketplaceDetailScreen> {
  late final MarketplaceDetailController _controller;
  final Set<MarketplaceConsentCapability> _consent = {};

  @override
  void initState() {
    super.initState();
    _controller = MarketplaceDetailController(
      widget.port,
      widget.publisherId,
      widget.pluginId,
    )..load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('插件详情')),
    body: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final detail = _controller.detail;
        if (_controller.state == MarketplaceDetailState.loading ||
            _controller.state == MarketplaceDetailState.initial) {
          return const Center(child: CircularProgressIndicator());
        }
        if (detail == null) return const Center(child: Text('此插件当前不可用'));
        final installEnabled =
            detail.isInstallable &&
            _controller.installState != MarketplaceInstallState.installing &&
            _controller.installState != MarketplaceInstallState.installed;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              detail.summary.displayName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(detail.description),
            const SizedBox(height: 20),
            Text('权限变更', style: Theme.of(context).textTheme.titleMedium),
            ...detail.permissionDiff.requested.map(
              (permission) => CheckboxListTile(
                value: _consent.contains(permission.consentCapability),
                onChanged: installEnabled
                    ? (selected) => setState(() {
                        if (selected ?? false) {
                          _consent.add(permission.consentCapability);
                        } else {
                          _consent.remove(permission.consentCapability);
                        }
                      })
                    : null,
                title: Text(permission.summary),
                subtitle: permission.rationale == null
                    ? null
                    : Text(permission.rationale!),
              ),
            ),
            if (!detail.isInstallable)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('兼容性或风险信息无法安全确认，已阻止安装。'),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: installEnabled
                  ? () => _controller.install(_consent.toList(growable: false))
                  : null,
              child: Text(_installLabel(_controller.installState)),
            ),
            if (_controller.installFailureCode case final code?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_failureLabel(code)),
              ),
          ],
        );
      },
    ),
  );

  String _installLabel(MarketplaceInstallState state) => switch (state) {
    MarketplaceInstallState.idle => '安装',
    MarketplaceInstallState.installing => '正在安装…',
    MarketplaceInstallState.installed => '已安装',
    MarketplaceInstallState.blocked => '安装已阻止',
    MarketplaceInstallState.publisherSuspended => '发布者已暂停',
    MarketplaceInstallState.revoked => '发布版本已撤回',
    MarketplaceInstallState.signatureInvalid => '签名验证失败',
    MarketplaceInstallState.failed => '重新安装',
  };

  String _failureLabel(MarketplaceInstallErrorCode code) => switch (code) {
    MarketplaceInstallErrorCode.packageUnavailable => '安装包暂不可用',
    MarketplaceInstallErrorCode.releaseRevoked => '发布版本已撤回',
    MarketplaceInstallErrorCode.publisherSuspended => '发布者已暂停',
    MarketplaceInstallErrorCode.signatureInvalid => '签名验证失败',
    MarketplaceInstallErrorCode.digestMismatch => '安装包校验失败',
    MarketplaceInstallErrorCode.compatibilityChanged => '兼容性已变更',
    MarketplaceInstallErrorCode.permissionChanged => '权限声明已变更',
    MarketplaceInstallErrorCode.verificationFailed => '发布验证失败',
    MarketplaceInstallErrorCode.storageUnavailable => '本地存储暂不可用',
    MarketplaceInstallErrorCode.unknown => '安装未完成',
  };
}
