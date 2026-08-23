import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_format.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_state.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';
import 'package:timetrace_app/src/features/flight/presentation/private_flight_contract.dart';
import 'package:timetrace_app/src/features/flight/presentation/widgets/flight_complete_sheet.dart';
import 'package:timetrace_app/src/features/flight/presentation/widgets/flight_recent_list.dart';

/// "起飞" feature screen: today's stats, start/stop controls, recent records.
class FlightScreen extends StatelessWidget {
  const FlightScreen({required this.model, required this.actions, super.key});

  final PrivateFlightViewModel model;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final controller = model.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('起飞'),
        actions: [
          if (controller.activeSession != null)
            IconButton(
              tooltip: '丢弃进行中的起飞',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDiscard(context),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          _TodayStatsCard(stats: model.today, actions: actions),
          const SizedBox(height: 20),
          _ActiveFlightCard(controller: controller, actions: actions),
          const SizedBox(height: 24),
          const _SectionHeader(title: '最近起飞'),
          const SizedBox(height: 8),
          FlightRecentList(recent: model.recent, actions: actions),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('丢弃这次起飞？'),
        content: const Text('进行中的记录将被永久丢弃，无法回味。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('丢弃'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await actions.discard();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

class _TodayStatsCard extends StatelessWidget {
  const _TodayStatsCard({required this.stats, required this.actions});
  final PrivateFlightLoad<FlightTodayStats> stats;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: switch (stats.status) {
          PrivateFlightLoadStatus.loading => const SizedBox(
            height: 72,
            child: Center(child: CircularProgressIndicator()),
          ),
          PrivateFlightLoadStatus.error => Row(
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              const Expanded(child: Text('加载失败，请重试。')),
              TextButton(
                onPressed: actions.refreshToday,
                child: const Text('重试'),
              ),
            ],
          ),
          PrivateFlightLoadStatus.data => Row(
            children: [
              _StatTile(
                icon: Icons.flight_takeoff,
                label: '今日次数',
                value: '${stats.value!.count}',
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 16),
              _StatTile(
                icon: Icons.timer_outlined,
                label: '今日总时长',
                value: formatDuration(stats.value!.totalSeconds),
                color: theme.colorScheme.tertiary,
              ),
            ],
          ),
        },
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveFlightCard extends StatelessWidget {
  const _ActiveFlightCard({required this.controller, required this.actions});
  final FlightControllerState controller;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = controller.activeSession;

    if (active == null) {
      return _StartCard(
        isLoading: controller.isLoading,
        error: controller.error,
        actions: actions,
      );
    }

    final session = active;
    final elapsed = elapsedSeconds(session);

    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.flight,
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '飞行中',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '起飞于 ${formatTime(session.startedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                formatDuration(elapsed),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: controller.isLoading
                  ? null
                  : () => _openCompleteSheet(context, session),
              icon: const Icon(Icons.flight_land),
              label: const Text('降落'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (controller.error != null) ...[
              const SizedBox(height: 12),
              Text(
                controller.error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openCompleteSheet(
    BuildContext context,
    PrivateFlightSession session,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => FlightCompleteSheet(session: session, actions: actions),
    );
  }
}

class _StartCard extends StatelessWidget {
  const _StartCard({
    required this.isLoading,
    required this.actions,
    this.error,
  });
  final bool isLoading;
  final PrivateFlightActions actions;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary,
                    theme.colorScheme.tertiary,
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.flight_takeoff,
                color: Colors.white,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '准备好起飞了吗？',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '点击开始一次新的起飞，记录你专注的时光。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: isLoading ? null : actions.start,
              icon: const Icon(Icons.flight_takeoff),
              label: const Text('开始起飞'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
