import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/flight/presentation/private_flight_contract.dart';
import 'package:timetrace_app/src/features/flight/presentation/widgets/flight_detail_sheet.dart';

/// Renders the most recent completed flight sessions.
class FlightRecentList extends StatelessWidget {
  const FlightRecentList({
    required this.recent,
    required this.actions,
    super.key,
  });

  final PrivateFlightLoad<List<PrivateFlightSession>> recent;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return switch (recent.status) {
      PrivateFlightLoadStatus.loading => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      PrivateFlightLoadStatus.error => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            const Expanded(child: Text('加载失败，请重试。')),
            TextButton(
              onPressed: actions.refreshRecent,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
      PrivateFlightLoadStatus.data => _RecentData(
        sessions: recent.value!,
        actions: actions,
      ),
    };
  }
}

class _RecentData extends StatelessWidget {
  const _RecentData({required this.sessions, required this.actions});

  final List<PrivateFlightSession> sessions;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Filter out any stray active session from the recent list.
    final completed = sessions.where((s) => s.status != 'active').toList();
    if (completed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(
              Icons.flight_land_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
            Text(
              '还没有起飞记录，开始你的第一次起飞吧。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final s in completed) _RecentTile(session: s, actions: actions),
      ],
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.session, required this.actions});
  final PrivateFlightSession session;
  final PrivateFlightActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started = _parseLocal(session.startedAt);
    final dateLabel = started != null
        ? '${started.month}/${started.day} ${started.hour.toString().padLeft(2, '0')}:${started.minute.toString().padLeft(2, '0')}'
        : session.startedAt;
    final duration = session.durationSecs?.toInt() ?? 0;
    final notePreview = session.note.isEmpty ? '无备注' : session.note;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(context, session),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.flight_land,
                  color: theme.colorScheme.tertiary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dateLabel,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      notePreview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatDuration(duration),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(
    BuildContext context,
    PrivateFlightSession session,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FlightDetailSheet(
        session: session,
        loadMaterials: actions.loadMaterials,
      ),
    );
  }
}

DateTime? _parseLocal(String iso) {
  final dt = DateTime.tryParse(iso);
  return dt?.toLocal();
}
