import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Reusable stat chip. Keep the treatment quiet: color marks the datum while
/// text stays neutral, so several chips can coexist without competing.
class StatChip extends StatelessWidget {
  const StatChip({
    required this.label,
    required this.color,
    this.icon,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.065),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: TimeTraceSpace.xxs),
          ] else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: TimeTraceSpace.xxs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small contextual help affordance for desktop hover / mobile long-press.
class HelpIcon extends StatelessWidget {
  const HelpIcon({required this.message, this.size = 14, super.key});

  final String message;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 300),
      child: SizedBox.square(
        dimension: size + 8,
        child: Center(
          child: Icon(
            Icons.help_outline_rounded,
            size: size,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Reusable session/app row (colored dot + time + name + duration).
class DotRow extends StatelessWidget {
  const DotRow({
    required this.name,
    required this.color,
    required this.trailing,
    this.time,
    this.icon,
    this.fontSize = 12,
    super.key,
  });

  final String name;
  final Color color;
  final String trailing;
  final String? time;
  final IconData? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xxs),
      child: Row(
        children: [
          if (icon != null)
            Icon(icon, size: 13, color: scheme.onSurfaceVariant)
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: TimeTraceSpace.xs),
          if (time != null) ...[
            SizedBox(
              width: 42,
              child: Text(
                time!,
                style: TextStyle(
                  fontSize: fontSize - 2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xxs),
          ],
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fontSize),
            ),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Text(
            trailing,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header used inside compact data/settings surfaces.
class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.icon, required this.title, super.key});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(icon, size: 17, color: scheme.primary),
        const SizedBox(width: TimeTraceSpace.xs),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}
