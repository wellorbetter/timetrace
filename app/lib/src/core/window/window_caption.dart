import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart' show ResizeEdge;
import '../material/material.dart';
import 'window_presentation.dart';

/// Shared by the app and synthetic router/editor fixtures. No startup/native IO.
class WindowPresentationFrame extends StatefulWidget {
  const WindowPresentationFrame({
    required this.presentation, required this.immersive,
    required this.panelVisible, required this.child, super.key,
  });
  final WindowPresentation presentation;
  final bool immersive, panelVisible;
  final Widget child;
  @override
  State<WindowPresentationFrame> createState() => _WindowPresentationFrameState();
}

class _WindowPresentationFrameState extends State<WindowPresentationFrame> {
  int _intentRevision = 0;
  @override
  void didChangeDependencies() { super.didChangeDependencies(); _schedule(); }
  @override
  void didUpdateWidget(covariant WindowPresentationFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }
  void _schedule() {
    final revision = ++_intentRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _intentRevision) return;
      final contrast = MaterialScope.of(context).policy.highContrast;
      unawaited(widget.presentation.setDesired(
        widget.immersive, highContrast: contrast,
      ));
    });
  }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.presentation,
    builder: (context, _) {
      final p = widget.presentation;
      final visible = p.captionVisible && !widget.panelVisible;
      final notice = !visible && !widget.panelVisible && !p.panelVisible && p.error != null;
      return CallbackShortcuts(
        bindings: {
          if (visible)
            const SingleActivator(LogicalKeyboardKey.space, alt: true):
                () => unawaited(p.menu()),
        },
        // MaterialApp.router.builder is above its Navigator overlay.
        // Keep one full-frame host in every mode, including hidden caption
        // and standard-frame failure notice; never move the router subtree.
        child: Overlay.wrap(
          key: const Key('window_frame_overlay'),
          child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep these two slots and the router child at the same ancestry.
            Column(children: [
              SizedBox(
                height: visible || notice ? 48 : 0,
                child: Stack(fit: StackFit.expand, children: [
                  ExcludeFocus(
                    excluding: !visible,
                    child: ExcludeSemantics(
                      excluding: !visible,
                      child: TickerMode(
                        enabled: visible,
                        child: Offstage(
                          offstage: !visible,
                          child: WindowPresentationCaption(presentation: p),
                        ),
                      ),
                    ),
                  ),
                  if (notice)
                    Material(
                      color: MaterialScope.of(context).policy.fallbackSurface,
                      child: Row(children: [
                        Expanded(child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(p.error!, maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: MaterialScope.of(context).policy.foreground)),
                        )),
                        SizedBox(width: 48, height: 48, child: IconButton(
                          key: const Key('window_frame_retry'),
                          tooltip: '重试窗口外观', padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                          color: MaterialScope.of(context).policy.foreground,
                          onPressed: () => unawaited(p.retry()),
                          icon: const Icon(Icons.refresh_rounded, size: 20),
                        )),
                      ]),
                    ),
                ]),
              ),
              Expanded(child: widget.child),
            ]),
            for (final edge in ResizeEdge.values)
              _resizeRegion(edge, visible && p.resizeEnabled),
          ],
          ),
        ),
      );
    },
  );

  Widget _resizeRegion(ResizeEdge edge, bool enabled) {
    const width = 6.0;
    final corner = switch (edge) {
      ResizeEdge.topLeft || ResizeEdge.topRight ||
      ResizeEdge.bottomLeft || ResizeEdge.bottomRight => true,
      _ => false,
    };
    final top = switch (edge) {
      ResizeEdge.top || ResizeEdge.topLeft || ResizeEdge.topRight => 0.0,
      ResizeEdge.bottom || ResizeEdge.bottomLeft || ResizeEdge.bottomRight => null,
      _ => width,
    };
    final bottom = switch (edge) {
      ResizeEdge.bottom || ResizeEdge.bottomLeft || ResizeEdge.bottomRight => 0.0,
      ResizeEdge.top || ResizeEdge.topLeft || ResizeEdge.topRight => null,
      _ => width,
    };
    final left = switch (edge) {
      ResizeEdge.left || ResizeEdge.topLeft || ResizeEdge.bottomLeft => 0.0,
      ResizeEdge.right || ResizeEdge.topRight || ResizeEdge.bottomRight => null,
      _ => width,
    };
    final right = switch (edge) {
      ResizeEdge.right || ResizeEdge.topRight || ResizeEdge.bottomRight => 0.0,
      ResizeEdge.left || ResizeEdge.topLeft || ResizeEdge.bottomLeft => null,
      _ => width,
    };
    final vertical = edge == ResizeEdge.left || edge == ResizeEdge.right;
    final cursor = switch (edge) {
      ResizeEdge.left || ResizeEdge.right => SystemMouseCursors.resizeLeftRight,
      ResizeEdge.top || ResizeEdge.bottom => SystemMouseCursors.resizeUpDown,
      ResizeEdge.topLeft || ResizeEdge.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      _ => SystemMouseCursors.resizeUpRightDownLeft,
    };
    return Positioned(
      top: top, bottom: bottom, left: left, right: right,
      width: corner || vertical ? width : null,
      height: corner || !vertical ? width : null,
      child: IgnorePointer(
        ignoring: !enabled,
        child: ExcludeSemantics(
          child: MouseRegion(
            cursor: enabled ? cursor : SystemMouseCursors.basic,
            child: GestureDetector(
              key: ValueKey('window_resize_${edge.name}'),
              behavior: HitTestBehavior.opaque,
              onPanStart: enabled
                  ? (_) => unawaited(widget.presentation.resize(edge)) : null,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class WindowPresentationCaption extends StatelessWidget {
  const WindowPresentationCaption({required this.presentation, super.key});
  final WindowPresentation presentation;
  @override
  Widget build(BuildContext context) {
    final p = presentation, policy = MaterialScope.of(context).policy;
    final opaque = !policy.allowsGlass || policy.wallpaper != WallpaperLoadState.ready;
    Widget action(String id, String label, IconData icon, VoidCallback invoke) =>
        SizedBox(
          width: 48, height: 48,
          child: IconButton(
            key: ValueKey(id), tooltip: label,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            color: policy.foreground,
            onPressed: invoke, icon: Icon(icon, size: 20),
          ),
        );
    return GestureDetector(
      onSecondaryTapDown: (_) => unawaited(p.menu()),
      child: Material(
        key: const Key('window_caption'),
        color: opaque ? policy.fallbackSurface : policy.workSurface,
        child: SizedBox(
          height: 48,
          child: Row(children: [
            action('window_menu', '窗口菜单', Icons.more_vert_rounded,
                () => unawaited(p.menu())),
            Expanded(
              child: GestureDetector(
                key: const Key('window_drag'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => unawaited(p.drag()),
                onDoubleTap: () => unawaited(p.toggleMaximized()),
                child: SizedBox(
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: p.error ?? 'TimeTrace',
                      child: Text(
                        p.error == null ? 'TimeTrace' : '窗口外观未完成',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: policy.foreground, fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (p.error != null)
              action('window_frame_retry', '重试窗口外观', Icons.refresh_rounded,
                  () => unawaited(p.retry())),
            action('window_minimize', '最小化', Icons.minimize_rounded,
                () => unawaited(p.minimize())),
            action('window_maximize', p.maximized ? '还原' : '最大化',
                p.maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                () => unawaited(p.toggleMaximized())),
            action('window_close', '关闭', Icons.close_rounded,
                () => unawaited(p.close())),
          ]),
        ),
      ),
    );
  }
}
