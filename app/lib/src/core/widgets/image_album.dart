import 'dart:io';

import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Reusable diary image album.
/// Collapsed mode uses a quiet, aligned overlap instead of decorative rotation
/// or shadows; expanded mode is a simple thumbnail grid.
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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: TimeTraceMotion.normal,
            switchInCurve: TimeTraceMotion.standard,
            switchOutCurve: TimeTraceMotion.standard,
            child: switch (_mode) {
              _AlbumMode.grid => _GridBody(
                  key: const ValueKey('grid'),
                  images: images,
                  thumbSize: widget.thumbSize,
                  scheme: scheme,
                ),
              _AlbumMode.stack => _StackBody(
                  key: const ValueKey('stack'),
                  images: images,
                  maxPeek: widget.maxPeek,
                  thumbSize: widget.thumbSize,
                  scheme: scheme,
                ),
            },
          ),
        ),
        const SizedBox(width: TimeTraceSpace.xxs),
        IconButton(
          icon: Icon(
            _mode == _AlbumMode.grid
                ? Icons.view_agenda_outlined
                : Icons.grid_view_outlined,
            size: 15,
          ),
          tooltip: _mode == _AlbumMode.grid ? '收起' : '展开图片',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: () => setState(
            () => _mode = _mode == _AlbumMode.grid
                ? _AlbumMode.stack
                : _AlbumMode.grid,
          ),
        ),
      ],
    );
  }
}

class _GridBody extends StatelessWidget {
  const _GridBody({
    required this.images,
    required this.thumbSize,
    required this.scheme,
    super.key,
  });

  final List<String> images;
  final double thumbSize;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: TimeTraceSpace.xs,
      runSpacing: TimeTraceSpace.xs,
      children: [
        for (var i = 0; i < images.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            onTap: () => showImageGallery(context, images, initial: i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
              child: Image.file(
                File(images[i]),
                width: thumbSize,
                height: thumbSize,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: thumbSize,
                  height: thumbSize,
                  color: scheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StackBody extends StatelessWidget {
  const _StackBody({
    required this.images,
    required this.maxPeek,
    required this.thumbSize,
    required this.scheme,
    super.key,
  });

  final List<String> images;
  final int maxPeek;
  final double thumbSize;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final shown = images.take(maxPeek).toList();
    final step = thumbSize * 0.22;
    final width = thumbSize + step * (shown.length - 1);

    return InkWell(
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      onTap: () => showImageGallery(context, images),
      child: SizedBox(
        width: width,
        height: thumbSize,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: i * step,
                child: Container(
                  width: thumbSize,
                  height: thumbSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                    border: Border.all(
                      color: scheme.surface,
                      width: 2,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    File(shown[i]),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(
                      color: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ),
            if (images.length > shown.length)
              Positioned(
                right: TimeTraceSpace.xxs,
                bottom: TimeTraceSpace.xxs,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TimeTraceSpace.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.inverseSurface.withValues(alpha: 0.86),
                    borderRadius: BorderRadius.circular(TimeTraceRadius.small),
                  ),
                  child: Text(
                    '+${images.length - shown.length}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: scheme.onInverseSurface,
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
      duration: TimeTraceMotion.normal,
      curve: TimeTraceMotion.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    return Stack(
      children: [
        PageView.builder(
          controller: _ctrl,
          onPageChanged: (p) =>
              setState(() => _index = ((p - _base) % n + n) % n),
          itemCount: _base * 2,
          itemBuilder: (context, p) {
            final img = widget.images[(p % n + n) % n];
            return InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(img),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.broken_image_outlined,
                    size: 42,
                    color: Colors.white54,
                  ),
                ),
              ),
            );
          },
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: Row(
              children: [
                if (widget.title != null)
                  Expanded(
                    child: Text(
                      widget.title!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TimeTraceSpace.xs,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(TimeTraceRadius.small),
                  ),
                  child: Text(
                    '${_index + 1} / $n',
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xxs),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: TimeTraceSpace.xs,
          top: 0,
          bottom: 0,
          child: Center(
            child: IconButton(
              icon: const Icon(
                Icons.chevron_left_rounded,
                color: Colors.white,
                size: 30,
              ),
              onPressed: () => _go(-1),
            ),
          ),
        ),
        Positioned(
          right: TimeTraceSpace.xs,
          top: 0,
          bottom: 0,
          child: Center(
            child: IconButton(
              icon: const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white,
                size: 30,
              ),
              onPressed: () => _go(1),
            ),
          ),
        ),
      ],
    );
  }
}
