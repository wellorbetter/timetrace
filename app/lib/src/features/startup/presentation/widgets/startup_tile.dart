import 'package:flutter/material.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';

/// A startup entry row: icon + name + command + status + toggle.
class StartupTile extends StatelessWidget {
  const StartupTile({required this.entry, required this.onToggle, super.key});

  final StartupDto entry;
  final void Function(bool) onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSys = entry.source == 'HKLM' ||
        entry.exePath.contains('System32') ||
        entry.exePath.contains('Windows');
    final exePath = _exePath(entry.exePath);
    final name = _exeName(entry.exePath) ?? entry.name;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onToggle(!entry.enabled),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Icon
              exePath != null
                  ? AppIcon(exePath: exePath, size: 32)
                  : _LetterAvatar(name: name, isSys: isSys),
              const SizedBox(width: 12),
              // Name + command
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _commandPreview(entry.exePath),
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Status badge
              _StatusBadge(enabled: entry.enabled),
              // Toggle
              Switch(
                value: entry.enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _commandPreview(String cmd) {
    final cleaned = cmd.trim();
    if (cleaned.length > 42) return '${cleaned.substring(0, 42)}…';
    return cleaned;
  }

  String? _exeName(String cmd) => _exePath(cmd)?.split('\\').last;

  String? _exePath(String cmd) {
    final lower = cmd.toLowerCase();
    final idx = lower.indexOf('.exe');
    if (idx < 0) return null;
    final end = (idx + 4).clamp(0, cmd.length);
    if (end <= 0) return null;
    var start = cmd.lastIndexOf('"', end);
    start = start < 0 ? cmd.lastIndexOf(' ', end) : start;
    if (start < 0) start = 0;
    if (start >= end) return null;
    final path = cmd.substring(
        start + (start < cmd.length && (cmd[start] == '"' || cmd[start] == ' ') ? 1 : 0), end);
    return path.startsWith('%') ? null : path;
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? Colors.green.shade700 : scheme.outline;
    final bg = enabled ? Colors.green.withValues(alpha: 0.12) : scheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            enabled ? 'ON' : 'OFF',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _LetterAvatar extends StatelessWidget {
  const _LetterAvatar({required this.name, required this.isSys});

  final String name;
  final bool isSys;

  @override
  Widget build(BuildContext context) {
    final color = isSys ? Colors.orange : Colors.blueGrey;
    final first = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(first,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 16)),
    );
  }
}
