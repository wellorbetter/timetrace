import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// In-memory cache of decoded exe icons (keyed by exe path).
class _IconCache {
  static final Map<String, ui.Image> _cache = {};

  static ui.Image? get(String path) => _cache[path];
  static void put(String path, ui.Image img) {
    // Bound cache size (prevents unbounded growth with many apps).
    if (_cache.length > 128) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
    }
    _cache[path] = img;
  }
}

/// Renders a real exe icon extracted via the Rust bridge, with caching.
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
    _image = _IconCache.get(widget.exePath);
    if (_image == null) _load();
  }

  @override
  void didUpdateWidget(covariant AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.exePath != widget.exePath) {
      _image = _IconCache.get(widget.exePath);
      if (_image == null) _load();
    }
  }

  Future<void> _load() async {
    if (_loading || widget.exePath.isEmpty) return;
    // Another instance may have loaded it while we waited.
    final cached = _IconCache.get(widget.exePath);
    if (cached != null) {
      setState(() => _image = cached);
      return;
    }
    _loading = true;
    try {
      final api = ref.read(apiProvider);
      final icon = api.getAppIcon(exePath: widget.exePath);
      if (icon == null || icon.rgba.isEmpty) {
        AppLogger.log('icon NULL for: ${widget.exePath}');
        return;
      }
      final w = icon.width.toInt();
      final h = icon.height.toInt();
      // decodeImageFromPixels expects NON-premultiplied rgba8888.
      final rgba = _unPremultiply(icon.rgba);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
      final img = await completer.future;
      _IconCache.put(widget.exePath, img);
      if (mounted) setState(() => _image = img);
    } catch (e, st) {
      AppLogger.log('icon load FAIL ${widget.exePath}: $e\n$st');
    }
  }

  /// Convert premultiplied RGBA back to straight alpha.
  Uint8List _unPremultiply(Uint8List src) {
    final out = Uint8List(src.length);
    for (var i = 0; i < src.length; i += 4) {
      final a = src[i + 3];
      if (a == 0) {
        out[i] = out[i + 1] = out[i + 2] = 0;
      } else {
        out[i] = (src[i] * 255 ~/ a).clamp(0, 255);
        out[i + 1] = (src[i + 1] * 255 ~/ a).clamp(0, 255);
        out[i + 2] = (src[i + 2] * 255 ~/ a).clamp(0, 255);
      }
      out[i + 3] = a;
    }
    return out;
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
