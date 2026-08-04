import 'dart:io';

import 'package:flutter/material.dart';

/// Reusable image album widget:
/// - collapsed: peeking stack (each image reveals a corner) + "+N"
/// - expanded: flat grid (平铺)
/// - hidden: single-line summary, tap to bring back
/// Tap any image → fullscreen gallery (looping swipe + ◀ ▶ navigation).
class ImageAlbum extends StatefulWidget {
  const ImageAlbum({
    required this.images,
    this.thumbSize = 76,
    this.maxPeek = 4,
    this.title,
    super.key,
  });

  final List<String> images;
  final double thumbSize;
  final int maxPeek;
  final String? title;

  @override
  State<ImageAlbum> createState() => _ImageAlbumState();
}

enum _AlbumMode { stack, grid }

class _ImageAlbumState extends State<ImageAlbum> {
  _AlbumMode _mode = _AlbumMode.stack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = widget.images;
    if (images.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top row: stack ↔ grid toggle pinned right (not over the images)
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: Icon(
                _mode == _AlbumMode.grid
                    ? Icons.view_stream_outlined
                    : Icons.grid_view_outlined,
                size: 15),
            tooltip:
                _mode == _AlbumMode.grid ? '收起为堆叠' : '平铺展开',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _mode = _mode == _AlbumMode.grid
                ? _AlbumMode.stack
                : _AlbumMode.grid),
          ),
        ),
        const SizedBox(height: 2),
        // Images
        switch (_mode) {
          _AlbumMode.grid => _GridBody(
              images: images,
              thumbSize: widget.thumbSize,
              scheme: scheme),
          _AlbumMode.stack => _StackBody(
              images: images,
              maxPeek: widget.maxPeek,
              thumbSize: widget.thumbSize,
              scheme: scheme),
        },
        // Count BELOW the images (never covering them)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('×${images.length} 张图片',
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.outline,
                  fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }
}

/// Flat grid of thumbnails (平铺), tap → gallery.
class _GridBody extends StatelessWidget {
  const _GridBody({
    required this.images,
    required this.thumbSize,
    required this.scheme,
  });

  final List<String> images;
  final double thumbSize;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < images.length; i++)
          GestureDetector(
            onTap: () => showImageGallery(context, images, initial: i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(images[i]),
                width: thumbSize,
                height: thumbSize,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: thumbSize,
                  height: thumbSize,
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.broken_image, size: 20, color: scheme.outline),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Peeking stack (each image reveals a corner) + "+N" badge.
class _StackBody extends StatelessWidget {
  const _StackBody({
    required this.images,
    required this.maxPeek,
    required this.thumbSize,
    required this.scheme,
  });

  final List<String> images;
  final int maxPeek;
  final double thumbSize;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final shown = images.take(maxPeek).toList();
    final step = thumbSize * 0.18;
    return GestureDetector(
      onTap: () => showImageGallery(context, images),
      child: SizedBox(
        height: thumbSize + 4,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: i * step,
                top: 2 + i * 3.0,
                child: Transform.rotate(
                  angle: (i - (shown.length - 1) / 2) * 0.02,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(shown[i]),
                        width: thumbSize,
                        height: thumbSize,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: thumbSize,
                          height: thumbSize,
                          color: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen image gallery: looping swipe (PageView) + ◀ ▶ navigation +
/// InteractiveViewer pinch zoom + index counter.
Future<void> showImageGallery(
  BuildContext context,
  List<String> images, {
  int initial = 0,
  String? title,
}) async {
  if (images.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (_) => ImageGallery(images: images, initial: initial, title: title),
  );
}

class ImageGallery extends StatefulWidget {
  const ImageGallery({
    required this.images,
    required this.initial,
    this.title,
    super.key,
  });

  final List<String> images;
  final int initial;
  final String? title;

  @override
  State<ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<ImageGallery> {
  late final PageController _ctrl;
  late int _index;

  // Loop trick: render a huge page count, map to the real list with modulo.
  static const _loopBase = 1000;
  late final int _base = widget.images.length * _loopBase ~/ 2;

  @override
  void initState() {
    super.initState();
    _index = widget.initial;
    _ctrl = PageController(initialPage: _base + widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _go(int delta) {
    _ctrl.animateToPage(
      _ctrl.page!.round() + delta,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    return Stack(
      children: [
        // Looping pages
        PageView.builder(
          controller: _ctrl,
          onPageChanged: (p) => setState(() => _index = ((p - _base) % n + n) % n),
          itemCount: _base * 2,
          itemBuilder: (context, p) {
            final img = widget.images[(p % n + n) % n];
            return InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(img),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                      size: 48, color: Colors.white54),
                ),
              ),
            );
          },
        ),
        // Top bar: title + counter + close
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (widget.title != null)
                  Expanded(
                    child: Text(widget.title!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${_index + 1} / $n',
                      style: const TextStyle(fontSize: 12, color: Colors.white)),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
        // Left / right navigation arrows
        Positioned(
          left: 8,
          top: 0,
          bottom: 0,
          child: Center(
            child: IconButton(
              icon: const Icon(Icons.chevron_left, color: Colors.white, size: 32),
              onPressed: () => _go(-1),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 0,
          bottom: 0,
          child: Center(
            child: IconButton(
              icon: const Icon(Icons.chevron_right, color: Colors.white, size: 32),
              onPressed: () => _go(1),
            ),
          ),
        ),
      ],
    );
  }
}
