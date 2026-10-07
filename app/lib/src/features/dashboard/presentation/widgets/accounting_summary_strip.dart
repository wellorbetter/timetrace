import 'package:flutter/material.dart';
import '../../../../core/material/material.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';

/// Compact accounting totals for the selected dashboard range.
///
/// This is one aligned surface rather than a row of independent metric cards.
/// All values come from one canonical accounting snapshot.
class AccountingSummaryStrip extends StatelessWidget {
  const AccountingSummaryStrip({
    required this.activeSeconds,
    required this.idleSeconds,
    required this.accountedSeconds,
    required this.pausedSeconds,
    required this.privacyExcludedSeconds,
    required this.systemGapSeconds,
    required this.unknownSeconds,
    required this.integrity,
    super.key,
  });

  factory AccountingSummaryStrip.fromState(DashboardState state, {Key? key}) {
    return AccountingSummaryStrip(
      key: key,
      activeSeconds: state.totalActiveSeconds,
      idleSeconds: state.totalIdleSeconds,
      accountedSeconds: state.accountedSeconds,
      pausedSeconds: state.pausedSeconds,
      privacyExcludedSeconds: state.privacyExcludedSeconds,
      systemGapSeconds: state.systemGapSeconds,
      unknownSeconds: state.unknownSeconds,
      integrity: state.integrity,
    );
  }

  final int activeSeconds;
  final int idleSeconds;
  final int accountedSeconds;
  final int pausedSeconds;
  final int privacyExcludedSeconds;
  final int systemGapSeconds;
  final int unknownSeconds;
  final SnapshotIntegrityDto integrity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasCompletenessNotice = integrity == SnapshotIntegrityDto.partial;

    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            MaterialScope.maybeOf(context)?.policy.contentSurface ??
            scheme.surfaceContainerLow.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.58),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 300 ? 3 : 1;
                const gap = 8.0;
                final metricWidth =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;

                return Wrap(
                  spacing: gap,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: metricWidth,
                      child: _AccountingMetric(
                        icon: Icons.play_circle_outline,
                        iconColor: scheme.primary,
                        label: '活跃',
                        value: _formatAccountingDuration(activeSeconds),
                        semanticsLabel:
                            '活跃时间，${_formatAccountingDuration(activeSeconds)}',
                      ),
                    ),
                    SizedBox(
                      width: metricWidth,
                      child: _AccountingMetric(
                        icon: Icons.bedtime_outlined,
                        iconColor: scheme.tertiary,
                        label: '离开',
                        value: _formatAccountingDuration(idleSeconds),
                        semanticsLabel:
                            '离开时间，${_formatAccountingDuration(idleSeconds)}',
                      ),
                    ),
                    SizedBox(
                      width: metricWidth,
                      child: _AccountingMetric(
                        icon: Icons.check_circle_outline,
                        iconColor: scheme.onSurfaceVariant,
                        label: '已计入',
                        value: _formatAccountingDuration(accountedSeconds),
                        semanticsLabel:
                            '已计入时间，${_formatAccountingDuration(accountedSeconds)}',
                      ),
                    ),
                  ],
                );
              },
            ),
            if (hasCompletenessNotice) ...[
              const SizedBox(height: 8),
              Divider(height: 1, color: scheme.outlineVariant),
              const SizedBox(height: 8),
              Semantics(
                container: true,
                label: _completenessSemanticsLabel(
                  pausedSeconds: pausedSeconds,
                  privacyExcludedSeconds: privacyExcludedSeconds,
                  systemGapSeconds: systemGapSeconds,
                  unknownSeconds: unknownSeconds,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _completenessVisibleLabel(
                            pausedSeconds: pausedSeconds,
                            privacyExcludedSeconds: privacyExcludedSeconds,
                            systemGapSeconds: systemGapSeconds,
                            unknownSeconds: unknownSeconds,
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountingMetric extends StatelessWidget {
  const _AccountingMetric({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.semanticsLabel,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final valueStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Semantics(
      container: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatAccountingDuration(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
  if (hours > 0) return '$hours 小时';
  if (minutes > 0) return '$minutes 分钟';
  if (safeSeconds > 0) return '$safeSeconds 秒';
  return '0 分钟';
}

String _completenessVisibleLabel({
  required int pausedSeconds,
  required int privacyExcludedSeconds,
  required int systemGapSeconds,
  required int unknownSeconds,
}) {
  final parts = <String>[
    if (pausedSeconds > 0) '暂停 ${_formatAccountingDuration(pausedSeconds)}',
    if (privacyExcludedSeconds > 0)
      '隐私排除 ${_formatAccountingDuration(privacyExcludedSeconds)}',
    if (systemGapSeconds > 0)
      '系统间隔 ${_formatAccountingDuration(systemGapSeconds)}',
    if (unknownSeconds > 0) '未知 ${_formatAccountingDuration(unknownSeconds)}',
  ];
  return parts.isEmpty ? '数据完整性：部分时段未确认' : '数据完整性：${parts.join('，')}';
}

String _completenessSemanticsLabel({
  required int pausedSeconds,
  required int privacyExcludedSeconds,
  required int systemGapSeconds,
  required int unknownSeconds,
}) {
  final parts = <String>[
    if (pausedSeconds > 0) '暂停时间，${_formatAccountingDuration(pausedSeconds)}',
    if (privacyExcludedSeconds > 0)
      '隐私排除时间，${_formatAccountingDuration(privacyExcludedSeconds)}',
    if (systemGapSeconds > 0)
      '系统间隔时间，${_formatAccountingDuration(systemGapSeconds)}',
    if (unknownSeconds > 0) '未知时间，${_formatAccountingDuration(unknownSeconds)}',
  ];
  return parts.isEmpty ? '数据完整性提示。部分时段未确认' : '数据完整性提示。${parts.join('；')}';
}
