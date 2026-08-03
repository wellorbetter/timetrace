import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';

/// A startup entry row: icon + app name + status + toggle.
/// Full path shown via info icon tooltip / long-press.
class StartupTile extends ConsumerStatefulWidget {
  const StartupTile({required this.entry, required this.onToggle, super.key});

  final StartupDto entry;
  final void Function(bool) onToggle;

  @override
  ConsumerState<StartupTile> createState() => _StartupTileState();
}

class _StartupTileState extends ConsumerState<StartupTile> {
  String? _exePath;
  String? _appName;
  bool _showPath = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant StartupTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.exePath != widget.entry.exePath) _resolve();
  }

  void _resolve() {
    try {
      final api = ref.read(apiProvider);
      final path = api.resolveExePath(command: widget.entry.exePath);
      setState(() {
        _exePath = path;
        _appName = path?.split('\\').last ?? widget.entry.name;
      });
    } catch (_) {
      setState(() {
        _exePath = null;
        _appName = widget.entry.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSys = widget.entry.source == 'HKLM' ||
        widget.entry.exePath.contains('System32') ||
        widget.entry.exePath.contains('Windows');

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
        onTap: () => widget.onToggle(!widget.entry.enabled),
        onLongPress: () => setState(() => _showPath = !_showPath),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Icon (real exe icon, resolved via Rust)
              if (_exePath != null)
                AppIcon(exePath: _exePath!, size: 32)
              else
                _LetterAvatar(name: _appName ?? '?', isSys: isSys),
              const SizedBox(width: 12),
              // App name only (path hidden by default)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _appName ?? widget.entry.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Path revealed on long-press (secondary)
                    if (_showPath)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          widget.entry.exePath,
                          style:
                              TextStyle(fontSize: 11, color: scheme.outline),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Path info tooltip button
              IconButton(
                icon: Icon(Icons.info_outline, size: 18, color: scheme.outline),
                tooltip: widget.entry.exePath,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _showPath = !_showPath),
              ),
              // Status badge
              _StatusBadge(enabled: widget.entry.enabled),
              // Toggle
              Switch(
                value: widget.entry.enabled,
                onChanged: widget.onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled ? Colors.green.shade700 : scheme.outline;
    final bg = enabled
        ? Colors.green.withValues(alpha: 0.12)
        : scheme.surfaceContainerHighest;
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
