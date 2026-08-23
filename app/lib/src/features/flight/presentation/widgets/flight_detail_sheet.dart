import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';

/// Bottom sheet showing the details of a completed flight session
/// (note, satisfaction, duration) and its linked materials.
class FlightDetailSheet extends StatefulWidget {
  const FlightDetailSheet({
    required this.session,
    required this.loadMaterials,
    super.key,
  });

  final PrivateFlightSession session;
  final Future<List<PrivateFlightMaterialLink>> Function(
    PrivateFlightSession session,
  )
  loadMaterials;

  @override
  State<FlightDetailSheet> createState() => _FlightDetailSheetState();
}

class _FlightDetailSheetState extends State<FlightDetailSheet> {
  late Future<List<PrivateFlightMaterialLink>> _materialsFuture;

  @override
  void initState() {
    super.initState();
    _materialsFuture = _loadMaterials();
  }

  Future<List<PrivateFlightMaterialLink>> _loadMaterials() async {
    return widget.loadMaterials(widget.session);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = widget.session;
    final started = _parseLocal(session.startedAt);
    final ended = session.endedAt != null
        ? _parseLocal(session.endedAt!)
        : null;
    final duration = session.durationSecs?.toInt() ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.flight_land,
                    color: theme.colorScheme.tertiary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '起飞记录',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (started != null)
                        Text(
                          '${started.year}-${started.month.toString().padLeft(2, '0')}-${started.day.toString().padLeft(2, '0')} '
                          '${started.hour.toString().padLeft(2, '0')}:${started.minute.toString().padLeft(2, '0')}'
                          '${ended != null ? ' → ${ended.hour.toString().padLeft(2, '0')}:${ended.minute.toString().padLeft(2, '0')}' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  formatDuration(duration),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (session.satisfaction != null) ...[
              _DetailRow(
                label: '满意度',
                child: Row(
                  children: List.generate(
                    5,
                    (i) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(
                        i < (session.satisfaction?.toInt() ?? 0)
                            ? Icons.star
                            : Icons.star_border,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (session.note.isNotEmpty) ...[
              _DetailRow(label: '备注', child: Text(session.note)),
              const SizedBox(height: 12),
            ],
            const Divider(),
            const SizedBox(height: 8),
            Text(
              '关联材料',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<PrivateFlightMaterialLink>>(
              future: _materialsFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '加载材料失败: ${snap.error}',
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  );
                }
                final mats = snap.data ?? const [];
                if (mats.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '本次起飞未关联材料。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final fm in mats) _MaterialTile(material: fm.material),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({required this.material});
  final PrivateFlightMaterial material;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    material.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (material.kind.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      material.kind,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            if (material.tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                material.tags,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (material.sourceUrl != null &&
                material.sourceUrl!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                material.sourceUrl!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

DateTime? _parseLocal(String iso) {
  final dt = DateTime.tryParse(iso);
  return dt?.toLocal();
}
