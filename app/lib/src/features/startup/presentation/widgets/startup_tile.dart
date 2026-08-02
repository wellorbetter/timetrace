import 'package:flutter/material.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';

/// A single startup entry tile with real exe icon + toggle.
class StartupTile extends StatelessWidget {
  const StartupTile({required this.entry, required this.onToggle, super.key});

  final StartupDto entry;
  final void Function(bool) onToggle;

  @override
  Widget build(BuildContext context) {
    final isSys = entry.source == 'HKLM' ||
        entry.exePath.contains('System32') ||
        entry.exePath.contains('Windows');
    final name = _exeName(entry.exePath) ?? entry.name;
    final exePath = _exePath(entry.exePath);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: exePath != null
            ? AppIcon(exePath: exePath, size: 32)
            : _LetterAvatar(name: name, isSys: isSys),
        title: Text(name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          isSys ? '系统级 · ${entry.source}' : '用户级 · ${entry.source}',
          style: TextStyle(
            fontSize: 12,
            color: isSys ? Colors.orange : Colors.blueGrey,
          ),
        ),
        trailing: Switch(value: entry.enabled, onChanged: onToggle),
      ),
    );
  }

  String? _exeName(String cmd) => _exePath(cmd)?.split('\\').last;

  String? _exePath(String cmd) {
    final lower = cmd.toLowerCase();
    final idx = lower.indexOf('.exe');
    if (idx < 0) return null;
    final end = idx + 4;
    var start = cmd.lastIndexOf('"', end);
    start = start < 0 ? cmd.lastIndexOf(' ', end) : start;
    if (start < 0) start = 0;
    final path = cmd.substring(
        start + (start < cmd.length && (cmd[start] == '"' || cmd[start] == ' ') ? 1 : 0), end);
    return path.startsWith('%') ? null : path;
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
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(first,
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}
