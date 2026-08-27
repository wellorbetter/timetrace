import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

/// Release-app-only acceptance harness used by CI/demo recordings.
///
/// It is completely inert unless TIMETRACE_ACCEPTANCE_CAPTURE_DIR is set.
/// Frames come from the real Flutter render tree, so recordings do not depend
/// on system-level screen recording permissions. Native recorders are still
/// kept separately as acceptance evidence when a hosted runner permits them.
class AcceptanceCapture {
  AcceptanceCapture._();

  static final String? outputDirectory =
      Platform.environment['TIMETRACE_ACCEPTANCE_CAPTURE_DIR'];

  static bool get enabled =>
      outputDirectory != null && outputDirectory!.trim().isNotEmpty;

  static Future<void> run({
    required GlobalKey boundaryKey,
    required GoRouter router,
  }) async {
    if (!enabled) return;

    final directory = Directory(outputDirectory!);
    await directory.create(recursive: true);
    final doneFile = File('${directory.path}${Platform.pathSeparator}capture.done');
    if (await doneFile.exists()) await doneFile.delete();

    await windowManager.ensureInitialized();

    // Hosted runners have different usable work areas. Use a conservative
    // desktop viewport, then show lower-page content through real scrolling
    // instead of relying on oversized windows that macOS/Windows may clamp.
    await windowManager.setSize(const Size(1120, 680));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();

    await Future<void>.delayed(const Duration(seconds: 2));

    const frameInterval = Duration(milliseconds: 100);
    const captureDuration = Duration(seconds: 36);
    final capture = _captureFrames(
      boundaryKey: boundaryKey,
      directory: directory,
      duration: captureDuration,
      frameInterval: frameInterval,
    );

    await _showRoute(router, boundaryKey, '/dashboard');
    await _hold(const Duration(milliseconds: 2200));
    await _scrollPrimary(boundaryKey, 0.55);
    await _hold(const Duration(milliseconds: 2200));
    await _scrollPrimary(boundaryKey, 1.0);
    await _hold(const Duration(milliseconds: 1800));

    await _showRoute(router, boundaryKey, '/recap');
    await _hold(const Duration(milliseconds: 2800));
    await _scrollPrimary(boundaryKey, 0.52);
    await _hold(const Duration(milliseconds: 2400));
    await _scrollPrimary(boundaryKey, 1.0);
    await _hold(const Duration(milliseconds: 2200));

    await _showRoute(router, boundaryKey, '/settings');
    await _hold(const Duration(milliseconds: 2200));
    await _scrollPrimary(boundaryKey, 0.46);
    await _hold(const Duration(milliseconds: 2200));
    await _scrollPrimary(boundaryKey, 1.0);
    await _hold(const Duration(milliseconds: 2200));

    await _showRoute(router, boundaryKey, '/recap');
    await _hold(const Duration(milliseconds: 1800));
    await _scrollPrimary(boundaryKey, 0.60);
    await _hold(const Duration(milliseconds: 2200));

    final frameCount = await capture;
    final boundary = boundaryKey.currentContext?.findRenderObject();
    final width = boundary is RenderBox ? boundary.size.width.round() : 0;
    final height = boundary is RenderBox ? boundary.size.height.round() : 0;

    await File('${directory.path}${Platform.pathSeparator}capture.json')
        .writeAsString(
      '{"capture":"flutter-render-tree","frames":$frameCount,'
      '"frame_interval_ms":${frameInterval.inMilliseconds},'
      '"width":$width,"height":$height,'
      '"platform":"${Platform.operatingSystem}",'
      '"walkthrough":"dashboard-scroll,recap-scroll,settings-scroll,recap"}',
      flush: true,
    );
    await doneFile.writeAsString('ok\n', flush: true);
  }

  static Future<void> _showRoute(
    GoRouter router,
    GlobalKey boundaryKey,
    String route,
  ) async {
    router.go(route);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _scrollPrimary(boundaryKey, 0.0, animate: false);
  }

  static Future<void> _hold(Duration duration) => Future<void>.delayed(duration);

  static Future<void> _scrollPrimary(
    GlobalKey boundaryKey,
    double fraction, {
    bool animate = true,
  }) async {
    final rootContext = boundaryKey.currentContext;
    if (rootContext is! Element) return;

    ScrollableState? best;
    var bestExtent = 0.0;

    void visit(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        final position = state.position;
        if (position.hasContentDimensions &&
            (position.axisDirection == AxisDirection.down ||
                position.axisDirection == AxisDirection.up)) {
          final extent = position.maxScrollExtent - position.minScrollExtent;
          if (extent > bestExtent) {
            bestExtent = extent;
            best = state;
          }
        }
      }
      element.visitChildren(visit);
    }

    rootContext.visitChildren(visit);
    final scrollable = best;
    if (scrollable == null || bestExtent < 20) return;

    final position = scrollable.position;
    final clamped = fraction.clamp(0.0, 1.0);
    final target = position.minScrollExtent + bestExtent * clamped;
    if (!animate) {
      position.jumpTo(target);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return;
    }
    await position.animateTo(
      target,
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeInOutCubic,
    );
  }

  static Future<int> _captureFrames({
    required GlobalKey boundaryKey,
    required Directory directory,
    required Duration duration,
    required Duration frameInterval,
  }) async {
    final deadline = DateTime.now().add(duration);
    var index = 0;

    while (DateTime.now().isBefore(deadline)) {
      final renderObject = boundaryKey.currentContext?.findRenderObject();
      if (renderObject is RenderRepaintBoundary) {
        final image = await renderObject.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes != null) {
            final path = '${directory.path}${Platform.pathSeparator}'
                'frame-${index.toString().padLeft(5, '0')}.png';
            await File(path).writeAsBytes(
              bytes.buffer.asUint8List(),
              flush: false,
            );
            index += 1;
          }
        } finally {
          image.dispose();
        }
      }
      await Future<void>.delayed(frameInterval);
    }

    return index;
  }
}
