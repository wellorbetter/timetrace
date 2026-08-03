import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

/// Renders a real exe icon extracted via the Rust bridge.
class AppIcon extends ConsumerStatefulWidget {
  const AppIcon({required this.exePath, this.size = 32, super.key});

  final String exePath;
  final double size;

  @override
  ConsumerState<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends ConsumerState<AppIcon> {
  ui.Image? _image;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exePath != widget.exePath) {
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading || widget.exePath.isEmpty) return;
    _loading = true;
    try {
      final api = ref.read(apiProvider);
      final icon = api.getAppIcon(exePath: widget.exePath);
      if (icon == null || icon.rgba.isEmpty) return;
      final w = icon.width.toInt();
      final h = icon.height.toInt();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(icon.rgba, w, h, ui.PixelFormat.rgba8888,
          completer.complete);
      final img = await completer.future;
      if (mounted) setState(() => _image = img);
    } catch (_) {
      // Fall back to letter avatar.
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img != null) {
      return RawImage(
        image: img,
        width: widget.size,
        height: widget.size,
        filterQuality: FilterQuality.high,
      );
    }
    // Letter avatar fallback
    final name = _exeName(widget.exePath) ?? '?';
    final color = Colors.blueGrey;
    final first = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        first,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: widget.size * 0.5,
        ),
      ),
    );
  }

  String? _exeName(String cmd) {
    final lower = cmd.toLowerCase();
    final idx = lower.indexOf('.exe');
    if (idx < 0) return null;
    // Clamp end to string length — prevents RangeError on truncated paths.
    final end = (idx + 4).clamp(0, cmd.length);
    if (end <= 0) return null;
    var start = cmd.lastIndexOf('"', end);
    start = start < 0 ? cmd.lastIndexOf(' ', end) : start;
    if (start < 0) start = 0;
    if (start >= end) return null;
    final path = cmd.substring(
        start + (start < cmd.length && (cmd[start] == '"' || cmd[start] == ' ') ? 1 : 0), end);
    final slash = path.lastIndexOf('\\');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
