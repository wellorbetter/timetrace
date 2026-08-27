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
/// Frames come from the real Flutter render tree, so macOS recordings do not
/// depend on Screen Recording/TCC permission. The native system recorder is
/// still attempted separately by CI so we can retain a title-bar-inclusive
/// video when the hosted runner permits it.
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

    // Keep every platform at the same deterministic viewport. This makes the
    // README videos comparable and prevents hosted-runner display differences
    // from changing responsive layout.
    await windowManager.setSize(const Size(1180, 760));
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();

    await Future<void>.delayed(const Duration(seconds: 2));

    final capture = _captureFrames(
      boundaryKey: boundaryKey,
      directory: directory,
      duration: const Duration(seconds: 23),
      frameInterval: const Duration(milliseconds: 200),
    );

    const walkthrough = <({String route, Duration hold})>[
      (route: '/dashboard', hold: Duration(seconds: 4)),
      (route: '/recap', hold: Duration(seconds: 5)),
      (route: '/settings', hold: Duration(seconds: 4)),
      (route: '/dashboard', hold: Duration(seconds: 4)),
      (route: '/recap', hold: Duration(seconds: 5)),
    ];

    for (final step in walkthrough) {
      router.go(step.route);
      await Future<void>.delayed(step.hold);
    }

    final frameCount = await capture;
    await File('${directory.path}${Platform.pathSeparator}capture.json')
        .writeAsString(
      '{"capture":"flutter-render-tree","frames":$frameCount,'
      '"frame_interval_ms":200,"width":1180,"height":760,'
      '"platform":"${Platform.operatingSystem}"}',
      flush: true,
    );
    await doneFile.writeAsString('ok\n', flush: true);
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
      if (renderObject is RenderRepaintBoundary && !renderObject.debugNeedsPaint) {
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
