import 'package:flutter/material.dart';

/// Reusable Material 3 stat chip (colored dot + label + value).
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ] else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500),
          ),
        ],
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (icon != null)
            Icon(icon, size: 13, color: scheme.outline)
          else
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          if (time != null) ...[
            SizedBox(
              width: 42,
              child: Text(time!,
                  style: TextStyle(fontSize: fontSize - 2, color: scheme.outline)),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fontSize)),
          ),
          Text(trailing,
              style: TextStyle(
                  fontSize: fontSize, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Section header (icon + title, M3 styling).
class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.icon, required this.title, super.key});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: scheme.primary)),
      ],
    );
  }
}
