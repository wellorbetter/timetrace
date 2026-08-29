import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

class NowlineTimelineView extends StatelessWidget {
  const NowlineTimelineView({
    required this.timeline,
    required this.preferences,
    this.compact = false,
    this.fadeHistory = true,
    super.key,
  });

  final NowlineTimeline timeline;
  final NowlinePreferences preferences;
  final bool compact;
  final bool fadeHistory;

  @override
  Widget build(BuildContext context) {
    if (timeline.lines.isEmpty) {
      return Center(
        child: Text(
          timeline.paused ? '追踪已暂停' : '等待下一次前台活动…',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        for (var index = 0; index < timeline.lines.length; index++)
          _NowlineRow(
            key: ValueKey(timeline.lines[index].id),
            line: timeline.lines[index],
            distanceFromCurrent: timeline.lines.length - index - 1,
            showTimestamp: preferences.showTimestamps,
            compact: compact,
            fadeHistory: fadeHistory,
          ),
      ],
    );
  }
}

class _NowlineRow extends StatelessWidget {
  const _NowlineRow({
    required this.line,
    required this.distanceFromCurrent,
    required this.showTimestamp,
    required this.compact,
    required this.fadeHistory,
    super.key,
  });

  final NowlineLine line;
  final int distanceFromCurrent;
  final bool showTimestamp;
  final bool compact;
  final bool fadeHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final opacity = !fadeHistory || line.isCurrent
        ? 1.0
        : (0.72 - distanceFromCurrent * 0.12).clamp(0.28, 0.72);
    final foreground = line.isCurrent
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    final time = _time(line.startedAt);

    return AnimatedOpacity(
      duration: TimeTraceMotion.normal,
      opacity: opacity,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 3 : 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTimestamp) ...[
              SizedBox(
                width: 42,
                child: Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: TimeTraceSpace.xs),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: AnimatedContainer(
                duration: TimeTraceMotion.fast,
                width: line.isCurrent ? 7 : 5,
                height: line.isCurrent ? 7 : 5,
                decoration: BoxDecoration(
                  color: line.isCurrent
                      ? scheme.primary
                      : scheme.outline.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                  boxShadow: line.isCurrent
                      ? [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.38),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (compact
                                ? theme.textTheme.bodyMedium
                                : theme.textTheme.titleSmall)
                            ?.copyWith(
                              color: foreground,
                              fontWeight: line.isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                  ),
                  if (line.detail case final detail?)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.78),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
