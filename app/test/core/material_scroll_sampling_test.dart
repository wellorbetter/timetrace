import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/material/refractive_backdrop.dart';

Future<ui.Image> pattern() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var y = 0; y < 400; y += 8) {
    for (var x = 0; x < 400; x += 8) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), y.toDouble(), 8, 8),
        Paint()..color = Color.fromARGB(255, x % 256, y % 256, (x + y) % 256),
      );
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(400, 400);
  picture.dispose();
  return image;
}

Future<List<int>> pixels(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return bytes!.buffer.asUint8List().toList();
  }))!;
}

void main() {
  for (final axes in [
    (Axis.vertical, Axis.vertical),
    (Axis.vertical, Axis.horizontal),
    (Axis.horizontal, Axis.vertical),
  ]) {
    testWidgets(
      'actual nested positions rebind $axes without remount or autonomous frame',
      (tester) async {
        final image = (await tester.runAsync(pattern))!;
        final outer = ScrollController(), inner = ScrollController();
        final root = GlobalKey(), capture = GlobalKey();
        final policy = MaterialPolicy.resolve(
          colorScheme: ThemeData().colorScheme,
          wallpaper: WallpaperLoadState.ready,
          signals: const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.disabled,
          ),
          appearance: const MaterialAppearance(
            contentOpacity: 0,
            cardBlur: 0,
            refraction: 0,
          ),
        );
        var bouncing = false, version = 0, businessBuilds = 0;
        late StateSetter physics, fresh;
        final stable = StatefulBuilder(
          builder: (context, setState) {
            businessBuilds++;
            fresh = setState;
            return RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 120,
                height: 80,
                child: RefractiveBackdrop(
                  key: ValueKey(version),
                  image: image,
                  viewportKey: root,
                  policy: policy,
                ),
              ),
            );
          },
        );
        final innerContent = SizedBox(
          width: axes.$2 == Axis.horizontal ? 800 : 400,
          height: axes.$2 == Axis.vertical ? 800 : 180,
          child: Align(alignment: Alignment.topLeft, child: stable),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 400,
                height: 400,
                child: Stack(
                  key: root,
                  children: [
                    StatefulBuilder(
                      builder: (context, setState) {
                        physics = setState;
                        final mode = bouncing
                            ? const BouncingScrollPhysics()
                            : const ClampingScrollPhysics();
                        final nested = SizedBox(
                          width: 400,
                          height: 180,
                          child: SingleChildScrollView(
                            controller: inner,
                            scrollDirection: axes.$2,
                            physics: mode,
                            child: innerContent,
                          ),
                        );
                        return SingleChildScrollView(
                          controller: outer,
                          scrollDirection: axes.$1,
                          physics: mode,
                          child: SizedBox(
                            width: axes.$1 == Axis.horizontal ? 1000 : 400,
                            height: axes.$1 == Axis.vertical ? 1000 : 400,
                            child: Padding(
                              padding: axes.$1 == Axis.vertical
                                  ? const EdgeInsets.only(top: 150)
                                  : const EdgeInsets.only(left: 150),
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: nested,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => ui.FragmentProgram.fromAsset(cardRefractionAsset),
        );
        await tester.pumpAndSettle();
        final oldOuter = outer.position, oldInner = inner.position;
        final paintFinder = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_RefractionPaint',
        );
        final renderer = tester.renderObject(paintFinder) as dynamic;
        final builds = businessBuilds;
        physics(() => bouncing = true);
        await tester.pumpAndSettle();
        expect(identical(outer.position, oldOuter), false);
        expect(identical(inner.position, oldInner), false);
        expect(tester.renderObject(paintFinder), same(renderer));
        expect(businessBuilds, builds);
        expect((renderer.scrolls as List).contains(oldOuter), false);
        expect((renderer.scrolls as List).contains(oldInner), false);
        expect((renderer.scrolls as List).contains(outer.position), true);
        expect((renderer.scrolls as List).contains(inner.position), true);
        outer.jumpTo(70);
        inner.jumpTo(15);
        await tester.pumpAndSettle();
        final scrolled = await pixels(tester, capture);
        fresh(() => version++);
        await tester.pumpAndSettle();
        expect(await pixels(tester, capture), scrolled);
        final lastRender = tester.renderObject(paintFinder) as dynamic;
        await tester.pumpWidget(const SizedBox());
        expect(lastRender.attached, false);
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, false);
        outer.dispose();
        inner.dispose();
        image.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final guard in [
    'contrast',
    'transparency',
    'unknown',
    'effectsOff',
    'solid',
    'legal',
  ]) {
    testWidgets(
      'public legacy policy $guard preserves fallback and borrowed ownership',
      (tester) async {
        Future<ui.Image> colorImage(Color color) async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(color, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(100, 100);
          picture.dispose();
          return image;
        }

        final red = (await tester.runAsync(() => colorImage(Colors.red)))!;
        final blue = (await tester.runAsync(() => colorImage(Colors.blue)))!;
        final root = GlobalKey(), capture = GlobalKey();
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
          _ => const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.disabled,
          ),
        };
        final policy = MaterialPolicy.resolve(
          colorScheme: ThemeData().colorScheme,
          wallpaper: WallpaperLoadState.ready,
          signals: signals,
          backgroundOpacity: 1,
          appearance: MaterialAppearance(
            contentOpacity: 0,
            cardBlur: 0,
            refraction: 0,
            light: 0,
            cardEffects: guard != 'effectsOff',
            cardStyle: guard == 'solid'
                ? SurfaceStyle.solid
                : SurfaceStyle.glass,
          ),
        );
        Widget page(ui.Image image) => MaterialApp(
          home: Stack(
            key: root,
            children: [
              RepaintBoundary(
                key: capture,
                child: SizedBox(
                  width: 120,
                  height: 80,
                  child: RefractiveBackdrop(
                    image: image,
                    viewportKey: root,
                    policy: policy,
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pumpWidget(page(red));
        await tester.runAsync(
          () => ui.FragmentProgram.fromAsset(cardRefractionAsset),
        );
        await tester.pumpAndSettle();
        final redPixels = await pixels(tester, capture);
        await tester.pumpWidget(page(blue));
        await tester.pumpAndSettle();
        final bluePixels = await pixels(tester, capture);
        expect(policy.allowsCardSampling, guard == 'legal');
        if (guard == 'legal') {
          expect(
            bluePixels,
            isNot(redPixels),
          ); // Off interaction still permits original static sampling.
        } else {
          expect(bluePixels, redPixels);
        }
        await tester.pumpWidget(const SizedBox());
        expect(red.width, 100);
        expect(blue.width, 100); // Renderer never owns these handles.
        red.dispose();
        blue.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'stationary pointer outer-only scroll matches fresh same-origin pixels',
    (tester) async {
      final image = (await tester.runAsync(pattern))!;
      final outer = ScrollController();
      final inner = ScrollController();
      final replacement = ScrollController();
      var currentInner = inner;
      final root = GlobalKey();
      final capture = GlobalKey();
      final theme = ThemeData();
      final policy = MaterialPolicy.resolve(
        colorScheme: theme.colorScheme,
        wallpaper: WallpaperLoadState.ready,
        signals: const MaterialSignals(
          highContrast: AccessibilitySignal.disabled,
          reduceTransparency: AccessibilitySignal.disabled,
        ),
        backgroundOpacity: 1,
        appearance: const MaterialAppearance(
          contentOpacity: 0,
          cardBlur: 0,
          refraction: 0,
        ),
      );
      var version = 0;
      var builds = 0;
      late StateSetter rebuild;
      final stableChild = StatefulBuilder(
        builder: (context, setState) {
          builds++;
          rebuild = setState;
          return SingleChildScrollView(
            controller: currentInner,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 800,
              height: 100,
              child: Align(
                alignment: Alignment.centerLeft,
                child: RepaintBoundary(
                  key: capture,
                  child: SizedBox(
                    width: 120,
                    height: 80,
                    child: RefractiveBackdrop(
                      key: ValueKey(version),
                      image: image,
                      viewportKey: root,
                      policy: policy,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: Stack(
                key: root,
                children: [
                  SingleChildScrollView(
                    controller: outer,
                    child: Column(
                      children: [
                        const SizedBox(height: 150),
                        stableChild,
                        const SizedBox(height: 700),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await ui.FragmentProgram.fromAsset(cardRefractionAsset);
      });
      await tester.pumpAndSettle();
      final before = await pixels(tester, capture);
      final initialBuilds = builds;
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(250, 350),
          scrollDelta: Offset(0, 80),
        ),
      );
      await tester.pumpAndSettle();
      expect(inner.offset, 0);
      expect(outer.offset, 80);
      expect(builds, initialBuilds);
      final scrolled = await pixels(tester, capture);
      rebuild(() => version++);
      await tester.pumpAndSettle();
      final fresh = await pixels(tester, capture);
      expect(fresh, isNot(before));
      expect(scrolled, fresh);
      inner.jumpTo(40);
      await tester.pumpAndSettle();
      final horizontal = await pixels(tester, capture);
      rebuild(() => version++);
      await tester.pumpAndSettle();
      expect(await pixels(tester, capture), horizontal);
      expect(horizontal, isNot(fresh));
      expect(outer.offset, 80);
      rebuild(() => currentInner = replacement);
      await tester.pumpAndSettle();
      expect(inner.hasClients, false);
      // Scrollable deliberately transfers its existing position to a new controller.
      expect(replacement.offset, 40);
      replacement.jumpTo(25);
      await tester.pumpAndSettle();
      final replaced = await pixels(tester, capture);
      rebuild(() => version++);
      await tester.pumpAndSettle();
      expect(await pixels(tester, capture), replaced);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      outer.dispose();
      inner.dispose();
      replacement.dispose();
      image.dispose();
    },
  );
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'captured sibling coordinates and resize match ancestor scale$scale',
      (tester) async {
        final image = (await tester.runAsync(pattern))!;
        final root = GlobalKey(), inside = GlobalKey(), overlay = GlobalKey();
        final policy = MaterialPolicy.resolve(
          colorScheme: ThemeData().colorScheme,
          wallpaper: WallpaperLoadState.ready,
          signals: const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.disabled,
          ),
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
        Widget sampler(GlobalKey capture) => MaterialSamplingInput(
          handle: handle,
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 80,
              height: 52,
              child: RefractiveBackdrop(
                image: image,
                viewportKey: root,
                policy: policy,
              ),
            ),
          ),
        );
        Widget page(double width) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Stack(
              children: [
                Positioned(
                  left: 100,
                  top: 100,
                  width: width,
                  height: 300,
                  child: Stack(
                    key: root,
                    children: [
                      Positioned(left: 40, top: 40, child: sampler(inside)),
                    ],
                  ),
                ),
                Positioned(left: 140, top: 140, child: sampler(overlay)),
              ],
            ),
          ),
        );
        await tester.pumpWidget(page(400));
        await tester.runAsync(() async {
          await ui.FragmentProgram.fromAsset(cardRefractionAsset);
        });
        await tester.pumpAndSettle();
        expect(await pixels(tester, overlay), await pixels(tester, inside));
        final renders = find
            .byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_RefractionPaint',
            )
            .evaluate()
            .map((element) => element.renderObject as dynamic)
            .toList();
        expect(renders.length, 2);
        expect(identical(renders[0].shader, renders[1].shader), false);
        await tester.pumpWidget(page(300));
        await tester.pumpAndSettle();
        expect(await pixels(tester, overlay), await pixels(tester, inside));
        handle.close();
        image.dispose();
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
