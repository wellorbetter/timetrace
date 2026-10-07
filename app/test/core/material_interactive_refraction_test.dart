import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/material/refractive_backdrop.dart';
import 'material_scroll_sampling_test.dart' show pattern, pixels;

const safeSignals = MaterialSignals(
  highContrast: AccessibilitySignal.disabled,
  reduceTransparency: AccessibilitySignal.disabled,
);

class ManualProvider extends ImageProvider<ManualProvider> {
  final frames = ManualFrames();
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    ManualProvider key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(frames);
  }

  @override
  Future<ManualProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
}

class ManualFrames extends ImageStreamCompleter {
  final listeners = <ImageStreamListener>[];
  @override
  void addListener(ImageStreamListener listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners.remove(listener);
  }

  void emit(ImageInfo info) {
    for (final l in List.of(listeners)) {
      l.onImage(info, false);
    }
  }

  void fail() {
    for (final l in List.of(listeners)) {
      l.onError!(StateError('synthetic'), StackTrace.current);
    }
  }
}

class OwnedInfo extends ImageInfo {
  OwnedInfo(ui.Image image, this.beforeDispose) : super(image: image);
  final VoidCallback beforeDispose;
  final _disposals = <int>[0];
  int get disposals => _disposals.single;
  @override
  void dispose() {
    beforeDispose();
    _disposals[0]++;
    super.dispose();
  }
}

void main() {
  for (final dispose in [false, true]) {
    testWidgets(
      'late shader after closed scope dispose$dispose attaches nothing',
      (tester) async {
        final image = (await tester.runAsync(pattern))!;
        final program = (await tester.runAsync(
          () => ui.FragmentProgram.fromAsset(cardRefractionAsset),
        ))!;
        final completer = Completer<ui.FragmentProgram>();
        final root = GlobalKey();
        final policy = MaterialPolicy.resolve(
          colorScheme: ThemeData().colorScheme,
          wallpaper: WallpaperLoadState.ready,
          signals: safeSignals,
        );
        final handle = MaterialSamplingHandle(
          MaterialSamplingSnapshot(
            generation: 1,
            policy: policy,
            tokens: MaterialTokens.forWidth(400),
            viewportKey: root,
            image: image,
            active: true,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(
              key: root,
              children: [
                MaterialSamplingInput(
                  handle: handle,
                  child: SizedBox(
                    width: 80,
                    height: 52,
                    child: RefractiveBackdrop(
                      image: image,
                      viewportKey: root,
                      policy: policy,
                      loadProgram: () => completer.future,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_RefractionPaint',
          ),
          findsNothing,
        );
        handle.close();
        image.dispose();
        if (dispose) await tester.pumpWidget(const SizedBox());
        completer.complete(program);
        await tester.pump();
        expect(
          find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_RefractionPaint',
          ),
          findsNothing,
        );
        expect(tester.binding.hasScheduledFrame, false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final guard in [
    'off',
    'motion',
    'contrast',
    'transparency',
    'unknown',
    'noImage',
  ]) {
    testWidgets(
      'interaction guard $guard never activates and schedules no ticker',
      (tester) async {
        final provider = ManualProvider();
        MaterialSamplingInput? input;
        final body = MaterialSheen(
          child: Builder(
            builder: (context) {
              input = MaterialSamplingInput.maybeOf(context);
              return const SizedBox(
                width: 120,
                height: 80,
                child: ColoredBox(color: Colors.transparent),
              );
            },
          ),
        );
        final signals = switch (guard) {
          'contrast' => const MaterialSignals(
            highContrast: AccessibilitySignal.enabled,
            reduceTransparency: AccessibilitySignal.disabled,
          ),
          'transparency' => const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.enabled,
          ),
          'unknown' => const MaterialSignals(),
          _ => safeSignals,
        };
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: guard == 'motion'),
              child: WallpaperEnvironment(
                wallpaper: provider,
                signals: signals,
                appearance: MaterialAppearance(
                  interactiveRefraction: guard != 'off',
                ),
                child: Align(alignment: Alignment.topLeft, child: body),
              ),
            ),
          ),
        );
        if (guard != 'noImage') {
          final image = (await tester.runAsync(pattern))!;
          provider.frames.emit(ImageInfo(image: image));
        }
        await tester.pumpAndSettle();
        final touch = await tester.startGesture(const Offset(30, 30));
        await touch.moveBy(const Offset(4, 4));
        await tester.pump();
        expect(input!.pointer!.value.active, false);
        await touch.cancel();
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(600, 500));
        await mouse.moveTo(const Offset(30, 30));
        await tester.pump();
        expect(input!.pointer!.value.active, false);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, false);
        if ([
          'contrast',
          'transparency',
          'unknown',
          'noImage',
        ].contains(guard)) {
          expect(find.byType(RefractiveBackdrop), findsNothing);
        }
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'independent scroll branches repaint only geometry and preserve business',
    (tester) async {
      final provider = ManualProvider();
      final left = ScrollController(), right = ScrollController();
      final leftPixels = GlobalKey(), rightPixels = GlobalKey();
      var version = 0, businessBuilds = 0;
      late StateSetter fresh;
      final body = StatefulBuilder(
        builder: (context, setState) {
          fresh = setState;
          businessBuilds++;
          Widget pane(ScrollController controller, GlobalKey boundary) =>
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      const SizedBox(height: 120),
                      Builder(
                        builder: (context) {
                          final scope = MaterialScope.of(context);
                          if (scope.wallpaper == null) {
                            return const SizedBox(width: 120, height: 80);
                          }
                          return MaterialSamplingInput(
                            handle: scope.samplingHandle,
                            child: RepaintBoundary(
                              key: boundary,
                              child: SizedBox(
                                width: 120,
                                height: 80,
                                child: RefractiveBackdrop(
                                  key: ValueKey(version),
                                  image: scope.wallpaper!,
                                  viewportKey: scope.viewportKey!,
                                  policy: scope.policy,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 700),
                    ],
                  ),
                ),
              );
          return Row(
            children: [pane(left, leftPixels), pane(right, rightPixels)],
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: WallpaperEnvironment(
            wallpaper: provider,
            signals: safeSignals,
            child: body,
          ),
        ),
      );
      final image = (await tester.runAsync(pattern))!;
      provider.frames.emit(ImageInfo(image: image));
      await tester.pumpAndSettle();
      final originalRight = await pixels(tester, rightPixels);
      final builds = businessBuilds;
      left.jumpTo(60);
      await tester.pumpAndSettle();
      final movedLeft = await pixels(tester, leftPixels);
      expect(right.offset, 0);
      expect(await pixels(tester, rightPixels), originalRight);
      expect(businessBuilds, builds);
      fresh(() => version++);
      await tester.pumpAndSettle();
      expect(await pixels(tester, leftPixels), movedLeft);
      expect(await pixels(tester, rightPixels), originalRight);
      await tester.pumpWidget(const SizedBox());
      left.dispose();
      right.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'root outside scroll invalidates captured sibling at stationary pointer',
    (tester) async {
      final provider = ManualProvider();
      final outer = ScrollController();
      final capturePixels = GlobalKey();
      MaterialOverlayCapture? captured;
      var version = 0;
      late StateSetter fresh;
      final source = Builder(
        builder: (context) {
          captured = MaterialOverlayCapture.of(context);
          return const SizedBox();
        },
      );
      final capturedChild = StatefulBuilder(
        builder: (context, setState) {
          fresh = setState;
          return captured == null
              ? const SizedBox()
              : captured!.wrap(
                  MaterialSheen(
                    key: ValueKey(version),
                    child: const SizedBox(width: 120, height: 80),
                  ),
                );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              SingleChildScrollView(
                controller: outer,
                child: Column(
                  children: [
                    const SizedBox(height: 100),
                    SizedBox(
                      height: 300,
                      child: WallpaperEnvironment(
                        wallpaper: provider,
                        signals: safeSignals,
                        child: source,
                      ),
                    ),
                    const SizedBox(height: 800),
                  ],
                ),
              ),
              Positioned(
                left: 40,
                top: 150,
                child: RepaintBoundary(
                  key: capturePixels,
                  child: capturedChild,
                ),
              ),
            ],
          ),
        ),
      );
      final image = (await tester.runAsync(pattern))!;
      provider.frames.emit(ImageInfo(image: image));
      await tester.pumpAndSettle();
      fresh(() {});
      await tester.pumpAndSettle();
      final before = await pixels(tester, capturePixels);
      outer.jumpTo(50);
      await tester.pumpAndSettle();
      final moved = await pixels(tester, capturePixels);
      expect(moved, isNot(before));
      fresh(() => version++);
      await tester.pumpAndSettle();
      expect(await pixels(tester, capturePixels), moved);
      await tester.pumpWidget(const SizedBox());
      outer.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'enabled hover and touch are local, exit/cancel/off restore exact base',
    (tester) async {
      final image = (await tester.runAsync(pattern))!;
      final root = GlobalKey(), capture = GlobalKey();
      final policy = MaterialPolicy.resolve(
        colorScheme: ThemeData().colorScheme,
        wallpaper: WallpaperLoadState.ready,
        signals: safeSignals,
        appearance: const MaterialAppearance(contentOpacity: 0, cardBlur: 0),
      );
      final handle = MaterialSamplingHandle(
        MaterialSamplingSnapshot(
          generation: 1,
          policy: policy,
          tokens: MaterialTokens.forWidth(400),
          viewportKey: root,
          image: image,
          active: true,
          interactionEnabled: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            key: root,
            children: [
              Positioned(
                left: 40,
                top: 40,
                child: MaterialScope(
                  policy: policy,
                  tokens: MaterialTokens.forWidth(400),
                  samplingHandle: handle,
                  child: RepaintBoundary(
                    key: capture,
                    child: const MaterialSheen(
                      child: SizedBox(
                        width: 160,
                        height: 100,
                        child: ColoredBox(color: Colors.transparent),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.runAsync(() async {
        await ui.FragmentProgram.fromAsset(cardRefractionAsset);
      });
      await tester.pumpAndSettle();
      final base = await pixels(tester, capture);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(const Offset(110, 90));
      await tester.pump();
      final active = await pixels(tester, capture);
      expect(active, isNot(base));
      // The 64px local lens cannot alter the far right of this plane.
      final edge = (50 * 160 + 150) * 4;
      expect(active.sublist(edge, edge + 4), base.sublist(edge, edge + 4));
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(await pixels(tester, capture), base);
      final touch = await tester.startGesture(const Offset(110, 90));
      await touch.moveBy(const Offset(3, 2));
      await tester.pump();
      expect(await pixels(tester, capture), isNot(base));
      await touch.cancel();
      await tester.pump();
      expect(await pixels(tester, capture), base);
      handle.publish(
        MaterialSamplingSnapshot(
          generation: 2,
          policy: policy,
          tokens: handle.current.tokens,
          viewportKey: root,
          image: image,
          active: true,
        ),
      );
      await tester.pump();
      await mouse.moveTo(const Offset(110, 90));
      await tester.pump();
      expect(await pixels(tester, capture), base);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, false);
      await mouse.removePointer();
      handle.close();
      image
          .dispose(); // Paint after synchronous close must not read this image.
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'environment owns each image once; invalidation precedes replacement failure and close',
    (tester) async {
      final a = ManualProvider(), b = ManualProvider();
      MaterialSamplingHandle? handle;
      final stable = Builder(
        builder: (context) {
          handle = MaterialScope.of(context).samplingHandle;
          return const MaterialSheen(child: SizedBox(width: 80, height: 52));
        },
      );
      Widget page(ManualProvider provider, {bool off = false}) => MaterialApp(
        home: WallpaperEnvironment(
          wallpaper: provider,
          signals: safeSignals,
          appearance: MaterialAppearance(
            cardEffects: !off,
            interactiveRefraction: true,
          ),
          child: stable,
        ),
      );
      await tester.pumpWidget(page(a));
      final original = handle;
      final image = (await tester.runAsync(pattern))!;
      final first = OwnedInfo(image, () {
        expect(handle!.current.image, isNull);
      });
      a.frames.emit(first);
      await tester.pumpAndSettle();
      expect(handle!.current.image, same(image));
      expect(handle!.current.allowsInteraction, true);
      await tester.pumpWidget(page(a, off: true));
      expect(handle, same(original));
      expect(handle!.current.image, isNull);
      expect(first.disposals, 0);
      await tester.pumpWidget(page(b));
      expect(a.frames.listeners, isEmpty);
      expect(first.disposals, 1);
      final nextImage = (await tester.runAsync(pattern))!;
      final second = OwnedInfo(nextImage, () {
        expect(handle!.current.image, isNull);
        expect(handle!.closed, true);
      });
      b.frames.emit(second);
      await tester.pumpAndSettle();
      final late = b.frames.listeners.single;
      await tester.pumpWidget(const SizedBox());
      expect(handle!.closed, true);
      expect(second.disposals, 1);
      expect(b.frames.listeners, isEmpty);
      final staleImage = (await tester.runAsync(pattern))!;
      final stale = OwnedInfo(staleImage, () {
        expect(handle!.closed, true);
      });
      late.onImage(stale, false);
      late.onError!(StateError('late synthetic error'), StackTrace.current);
      expect(stale.disposals, 1);
      handle!.invalidatePaint();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failure publishes image-free before deferred release', (
    tester,
  ) async {
    final provider = ManualProvider();
    MaterialSamplingHandle? handle;
    await tester.pumpWidget(
      MaterialApp(
        home: WallpaperEnvironment(
          wallpaper: provider,
          signals: safeSignals,
          child: Builder(
            builder: (context) {
              handle = MaterialScope.of(context).samplingHandle;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final image = (await tester.runAsync(pattern))!;
    final info = OwnedInfo(image, () {
      expect(handle!.current.image, isNull);
    });
    provider.frames.emit(info);
    await tester.pump();
    expect(handle!.current.image, same(image));
    provider.frames.fail();
    expect(handle!.current.image, isNull);
    expect(provider.frames.listeners, isEmpty);
    await tester.pump();
    expect(info.disposals, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
