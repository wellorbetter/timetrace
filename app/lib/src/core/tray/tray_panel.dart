import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../bridge/accounting.dart';
import '../../features/browsing/domain/canonical_feed_projection.dart';
import '../../features/browsing/models/browsing_state.dart';
import '../../features/browsing/providers/accounting_snapshot_provider.dart';
import '../bridge/api_provider.dart';
import '../format/app_identity.dart';
import '../material/material.dart';
import '../widgets/app_icon.dart';

class TrayPanelVisibility extends Notifier<bool> {
  @override
  bool build() => false;
  void setVisible(bool value) => state = value;
}

final trayPanelVisibleProvider = NotifierProvider<TrayPanelVisibility, bool>(
  TrayPanelVisibility.new,
);

class TrayOverview {
  const TrayOverview({required this.projection, required this.paused});
  final CanonicalFeedProjection projection;
  final bool paused;
}

final trayOverviewProvider = FutureProvider.autoDispose<TrayOverview>((
  ref,
) async {
  final timer = Timer(const Duration(seconds: 10), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final query = accountingQueryFor(
    const DateRangeSelection(DateRange.today),
    ref.watch(browsingClockProvider)(),
    timezone: ref.watch(dashboardIanaTimezoneProvider),
  );
  final projection = await ref.watch(accountingSnapshotProvider)(
    query,
    const FeedFilter(),
  );
  return TrayOverview(
    projection: projection,
    paused: ref.read(apiProvider).isTrackingPaused(),
  );
});

/// Pure positioning seam, clamps to the selected monitor's work area.
Rect trayPanelBounds(Rect work, Rect anchor) {
  final width = work.width.clamp(0, 380).toDouble();
  final height = work.height.clamp(0, 560).toDouble();
  return Rect.fromLTWH(
    (anchor.right - width).clamp(work.left, work.right - width).toDouble(),
    (anchor.top - height - MaterialTokens.spaceSm)
        .clamp(work.top, work.bottom - height)
        .toDouble(),
    width,
    height,
  );
}

class TrayPanel extends ConsumerWidget {
  const TrayPanel({
    required this.onOpenWorkspace,
    required this.onSettings,
    required this.onTogglePaused,
    required this.onDismiss,
    super.key,
  });
  final VoidCallback onOpenWorkspace, onSettings, onDismiss;
  final Future<void> Function() onTogglePaused;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(trayOverviewProvider);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onDismiss},
      child: Focus(
        autofocus: true,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(MaterialTokens.spaceMd),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.history_toggle_off_rounded),
                    const SizedBox(width: MaterialTokens.spaceSm),
                    Expanded(
                      child: Text(
                        'TimeTrace',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      overview.asData == null
                          ? '读取中'
                          : overview.asData!.value.paused
                          ? '已暂停'
                          : '记录中',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    IconButton(
                      tooltip: '设置',
                      onPressed: onSettings,
                      icon: const Icon(Icons.tune_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: MaterialTokens.spaceMd),
                Expanded(
                  child: overview.when(
                    skipLoadingOnRefresh: true,
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, _) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('暂时无法读取今天的记录'),
                          TextButton(
                            onPressed: () =>
                                ref.invalidate(trayOverviewProvider),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                    data: (data) => TrayPanelContent(
                      data: data,
                      onTogglePaused: onTogglePaused,
                    ),
                  ),
                ),
                const SizedBox(height: MaterialTokens.spaceSm),
                Row(
                  children: [
                    Text(
                      '记录保存在本机',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const Spacer(),
                    TextButton(
                      key: const Key('tray_open_workspace'),
                      onPressed: onOpenWorkspace,
                      child: const Text('打开工作台'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TrayPanelContent extends StatelessWidget {
  const TrayPanelContent({
    required this.data,
    required this.onTogglePaused,
    super.key,
  });
  final TrayOverview data;
  final Future<void> Function() onTogglePaused;
  @override
  Widget build(BuildContext context) {
    final rows = data.projection.allFragments
        .where((row) => row.state == AccountingStateDto.active)
        .toList()
        .reversed
        .take(6)
        .toList();
    final recent = rows.isEmpty ? null : rows.first;
    final date = data.projection.requestedStartUtc.toLocal();
    final updated = data.projection.observedThroughUtc.toLocal();
    final style = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(MaterialTokens.spaceMd),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('最近活动', style: style.labelSmall),
              const SizedBox(height: MaterialTokens.spaceSm),
              Text(
                recent == null
                    ? '暂无活动记录'
                    : appDisplayLabel(recent.appDisplayName ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.titleMedium,
              ),
              const SizedBox(height: MaterialTokens.spaceSm),
              Text(
                data.paused ? '追踪已暂停，恢复后继续记录' : '仅展示已有记录，不推断任务',
                style: style.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: MaterialTokens.spaceMd),
        Row(
          children: [
            Expanded(
              child: Text(
                '今天 · ${date.month}月${date.day}日',
                style: style.titleSmall,
              ),
            ),
            TextButton(
              onPressed: () async {
                await onTogglePaused();
              },
              child: Text(data.paused ? '恢复追踪' : '暂停追踪'),
            ),
          ],
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('今天还没有活动记录'))
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final time = row.visibleStartUtc.toLocal();
                    final name = row.appDisplayName ?? '';
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: AppIcon(appName: name, exePath: '', size: 24),
                      title: Text(
                        appDisplayLabel(name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                      ),
                      trailing: Text(
                        row.visibleDuration.inSeconds < 60
                            ? '${row.visibleDuration.inSeconds} 秒'
                            : '${row.visibleDuration.inMinutes} 分钟',
                        style: style.labelSmall,
                      ),
                    );
                  },
                ),
        ),
        if (data.projection.integrity != SnapshotIntegrityDto.complete)
          Text('部分时段记录不完整', style: style.labelSmall),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '更新 ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}',
            style: style.labelSmall,
          ),
        ),
      ],
    );
  }
}
