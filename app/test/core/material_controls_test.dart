import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/preferences/local_storage_paths.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';

const _allowed = MaterialSignals(
  highContrast: AccessibilitySignal.disabled,
  reduceTransparency: AccessibilitySignal.disabled,
);
final _synthetic = Provider<int>(
  (ref) => throw StateError('No default access'),
);

MaterialPolicy _policy(Brightness brightness, String mode) =>
    MaterialPolicy.resolve(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff58694f),
        brightness: brightness,
      ),
      wallpaper: WallpaperLoadState.absent,
      signals: switch (mode) {
        'high' => const MaterialSignals(
          highContrast: AccessibilitySignal.enabled,
          reduceTransparency: AccessibilitySignal.disabled,
        ),
        'reduced' => const MaterialSignals(
          highContrast: AccessibilitySignal.disabled,
          reduceTransparency: AccessibilitySignal.enabled,
        ),
        'unknown' => const MaterialSignals(),
        _ => _allowed,
      },
      appearance: MaterialAppearance(
        cardEffects: mode != 'off',
        cardStyle: mode == 'solid' ? SurfaceStyle.solid : SurfaceStyle.glass,
      ),
    );

void main() {
  _acceptanceUsabilityTests();
  testWidgets('optional focus paint gates overlay and rim only, including high contrast', (tester) async {
    for (final mode in ['glass','high']) {
      final policy = _policy(Brightness.light, mode);
      await tester.pumpWidget(MaterialApp(home: MaterialScope(
        policy: policy, tokens: MaterialTokens.forWidth(720),
        child: Scaffold(body: Builder(builder: (context) => Column(children: [
          MaterialActionButton(buttonKey: const Key('focus_default'),
            role: MaterialActionRole.auxiliary, onPressed: () {},
            child: const Text('default')),
          MaterialActionButton(buttonKey: const Key('focus_pointer'),
            role: MaterialActionRole.auxiliary, paintFocus: false,
            onPressed: () {}, child: const Text('pointer')),
        ]))),
      )));
      final normal = tester.widget<FilledButton>(find.byKey(const Key('focus_default'))).style!;
      final pointer = tester.widget<FilledButton>(find.byKey(const Key('focus_pointer'))).style!;
      final focus = {WidgetState.focused};
      expect(normal.overlayColor!.resolve(focus)!.a, greaterThan(0));
      expect(normal.side!.resolve(focus)!.color.a, greaterThan(0));
      expect(pointer.overlayColor!.resolve(focus)!.a, 0);
      expect(pointer.side!.resolve(focus)!.color, Colors.transparent);
      for (final state in [WidgetState.hovered, WidgetState.pressed]) {
        expect(pointer.overlayColor!.resolve({state}), normal.overlayColor!.resolve({state}));
        expect(pointer.overlayColor!.resolve({state})!.a, greaterThan(0));
      }
      expect(pointer.overlayColor!.resolve({WidgetState.disabled,WidgetState.focused})!.a, 0);
      expect(tester.takeException(), isNull);
    }
  });
  for (final brightness in Brightness.values) {
    for (final mode in [
      'glass',
      'off',
      'solid',
      'high',
      'reduced',
      'unknown',
    ]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('simple help glyph $brightness $mode scale$scale', (
          tester,
        ) async {
          final width = scale == 1 ? 720.0 : 280.0;
          tester.view.physicalSize = Size(width, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final policy = _policy(brightness, mode);
          await tester.pumpWidget(
            MaterialApp(
              theme: policy.applyTo(ThemeData(colorScheme: policy.colorScheme)),
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 700),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(width),
                    child: const Align(
                      alignment: Alignment.topLeft,
                      child: ContextHelp(message: '原说明合成正文'),
                    ),
                  ),
                ),
              ),
            ),
          );
          final button = find.byType(IconButton);
          final glyph = find.byIcon(Icons.question_mark_rounded);
          expect(glyph, findsOneWidget);
          expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
          final bounds = tester.getRect(button);
          expect(bounds.size, const Size(48, 48));
          expect(tester.getRect(glyph).size, const Size(18, 18));
          expect(tester.getRect(glyph).center, bounds.center);
          expect(find.byTooltip('说明'), findsOneWidget);
          final native = tester.widget<IconButton>(button);
          expect(
            native.style!.backgroundColor!.resolve({}),
            Colors.transparent,
          );
          expect(native.style!.side!.resolve({})!.color, Colors.transparent);
          expect(native.style!.backgroundBuilder, isNull);
          expect(find.byType(MaterialSheen), findsNothing);
          expect(find.byType(BackdropFilter), findsNothing);
          native.focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('原说明合成正文'), findsOneWidget);
          expect(find.byType(MaterialCard), findsOneWidget);
          expect(find.byType(BackdropFilter), findsNothing);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('原说明合成正文'), findsNothing);
          expect(native.focusNode!.hasFocus, isTrue);
          // Hit near the target edge, not just the 18dp glyph's center.
          await tester.tapAt(bounds.topLeft + const Offset(2, 2));
          await tester.pumpAndSettle();
          expect(find.text('原说明合成正文'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(native.focusNode!.hasFocus, isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  for (final kind in ['icon', 'primary', 'secondary']) {
    for (final layout in ['loose', 'bounded', 'expanded']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('native content center $kind $layout scale$scale', (
          tester,
        ) async {
          final policy = _policy(Brightness.light, 'glass');
          Widget control = kind == 'icon'
              ? MaterialIconAction(
                  buttonKey: const Key('center_surface'),
                  tooltip: 'Synthetic action',
                  icon: const Icon(
                    Icons.refresh,
                    key: Key('center_content'),
                    size: 20,
                  ),
                  onPressed: () {},
                )
              : MaterialActionButton(
                  buttonKey: const Key('center_surface'),
                  role: kind == 'primary'
                      ? MaterialActionRole.primary
                      : MaterialActionRole.secondary,
                  onPressed: () {},
                  child: const Text('Save', key: Key('center_content')),
                );
          // Bound width, not large-text line height. Icons retain exactly48.
          control = switch (layout) {
            'bounded' => SizedBox(
              width: kind == 'icon' ? 48 : 160,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: control,
              ),
            ),
            'expanded' => SizedBox(
              width: 240,
              child: Row(children: [Expanded(child: control)]),
            ),
            _ => control,
          };
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(360),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [control],
                    ),
                  ),
                ),
              ),
            ),
          );
          final native = find.byKey(const Key('center_surface'));
          final surface = tester.getRect(native);
          final contentFinder = find.byKey(const Key('center_content'));
          final content = tester.getRect(contentFinder);
          final sheen = find.descendant(
            of: native,
            matching: find.byType(MaterialSheen),
          );
          expect(surface.width, greaterThanOrEqualTo(48));
          expect(surface.height, greaterThanOrEqualTo(48));
          expect(tester.getRect(sheen), surface);
          expect((content.center.dx - surface.center.dx).abs(), lessThan(.5));
          expect((content.center.dy - surface.center.dy).abs(), lessThan(.5));
          expect(surface.inflate(.5).contains(content.topLeft), isTrue);
          expect(surface.inflate(.5).contains(content.bottomRight), isTrue);
          if (kind == 'icon') {
            expect(content.size, const Size(20, 20));
            expect(surface.height, 48);
          } else {
            final paragraph = tester.renderObject<RenderParagraph>(
              contentFinder,
            );
            final boxes = paragraph.getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 4),
            );
            expect(boxes, isNotEmpty);
            final visual = boxes
                .map((box) => box.toRect().shift(content.topLeft))
                .reduce((a, b) => a.expandToInclude(b));
            expect((visual.center.dx - surface.center.dx).abs(), lessThan(.5));
            expect((visual.center.dy - surface.center.dy).abs(), lessThan(.5));
            expect(surface.inflate(.5).contains(visual.topLeft), isTrue);
            expect(surface.inflate(.5).contains(visual.bottomRight), isTrue);
            if (scale == 2) expect(surface.height, greaterThan(48));
          }
          expect(find.byType(MaterialSheen), findsOneWidget);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  for (final scale in [1.0, 2.0]) {
    testWidgets('help native icon center scale$scale', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Align(
                alignment: Alignment.topLeft,
                child: ContextHelp(message: 'Synthetic help'),
              ),
            ),
          ),
        ),
      );
      final surface = tester.getRect(find.byType(IconButton));
      final glyph = tester.getRect(find.byIcon(Icons.question_mark_rounded));
      expect(surface.size, const Size(48, 48));
      expect(glyph.size, const Size(18, 18));
      expect(glyph.center, surface.center);
      // Auxiliary help has no decorated plane or hidden sampler.
      expect(find.byType(MaterialSheen), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('padded long label keeps full clipped plane and natural text', (
    tester,
  ) async {
    final policy = _policy(Brightness.light, 'glass');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MaterialScope(
            policy: policy,
            tokens: MaterialTokens.forWidth(720),
            child: Align(
              alignment: Alignment.topLeft,
              child: MaterialActionButton(
                buttonKey: const Key('long_action'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                onPressed: () {},
                child: const Text('保存合成的较长操作标签', key: Key('long_label')),
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const Key('long_action'));
    final sheen = find.descendant(
      of: button,
      matching: find.byType(MaterialSheen),
    );
    final surface = tester.getRect(button);
    final label = tester.getRect(find.byKey(const Key('long_label')));
    expect(tester.getRect(sheen), surface);
    expect(surface.height, greaterThanOrEqualTo(48));
    expect(surface.width - label.width, closeTo(48, .01));
    expect(surface.height - label.height, closeTo(32, .01));
    expect(find.byType(MaterialSheen), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.widget<FilledButton>(button).clipBehavior, Clip.antiAlias);
    expect(tester.takeException(), isNull);
  });
  testWidgets('aux help keeps 48dp hit target without a decorated plane', (
    tester,
  ) async {
    final policy = _policy(Brightness.light, 'glass');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MaterialScope(
            policy: policy,
            tokens: MaterialTokens.forWidth(360),
            child: const Align(
              alignment: Alignment.topLeft,
              child: ContextHelp(message: '合成帮助'),
            ),
          ),
        ),
      ),
    );
    final button = find.byType(IconButton);
    final sheen = find.descendant(
      of: button,
      matching: find.byType(MaterialSheen),
    );
    expect(tester.getSize(button), const Size(48, 48));
    expect(sheen, findsNothing);
    expect(
      tester.getSize(find.byIcon(Icons.question_mark_rounded)),
      const Size(18, 18),
    );
    final style = tester.widget<IconButton>(button).style!;
    expect(
      style.shape!.resolve({}),
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
      ),
    );
    expect(style.backgroundColor!.resolve({}), Colors.transparent);
    expect(style.backgroundBuilder, isNull);
    expect(find.byType(MaterialSheen), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final brightness in Brightness.values) {
    for (final mode in [
      'glass',
      'off',
      'solid',
      'high',
      'reduced',
      'unknown',
    ]) {
      testWidgets('material roles respect card policy $brightness $mode', (
        tester,
      ) async {
        final policy = _policy(brightness, mode);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: policy.applyTo(ThemeData(colorScheme: policy.colorScheme)),
            home: Scaffold(
              body: MaterialScope(
                policy: policy,
                tokens: MaterialTokens.forWidth(360),
                child: Wrap(
                  children: [
                    MaterialActionButton(
                      buttonKey: const Key('primary'),
                      focusNode: focus,
                      role: MaterialActionRole.primary,
                      onPressed: () => calls++,
                      child: const Text('主操作'),
                    ),
                    const MaterialIconAction(
                      buttonKey: Key('disabled'),
                      tooltip: '不可操作',
                      icon: Icon(Icons.pause),
                      onPressed: null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('primary')),
        );
        expect(
          button.style!.backgroundColor!.resolve({}),
          Color.alphaBlend(policy.colorScheme.onSurface.withValues(alpha: .12),
            policy.contentSurface),
        );
        expect(
          button.style!.backgroundColor!.resolve({}),
          isNot(policy.colorScheme.primary),
        );
        expect(
          button.style!.backgroundColor!.resolve({WidgetState.disabled}),
          Color.alphaBlend(policy.colorScheme.onSurface.withValues(alpha: .12),
            policy.contentSurface),
        );
        expect(policy.contentSurface.a, mode == 'glass' ? lessThan(1) : 1);
        expect(button.style!.side!.resolve({WidgetState.focused})!.width, 2);
        expect(
          button.style!.overlayColor!.resolve({WidgetState.hovered})!.a,
          greaterThan(0),
        );
        expect(
          button.style!.overlayColor!.resolve({WidgetState.pressed})!.a,
          greaterThan(0),
        );
        expect(
          button.style!.overlayColor!.resolve({WidgetState.disabled})!.a,
          0,
        );
        expect(find.byType(MaterialSheen), findsNWidgets(2));
        for (final key in ['primary', 'disabled']) {
          final native = find.byKey(Key(key));
          final sheen = find.descendant(
            of: native,
            matching: find.byType(MaterialSheen),
          );
          expect(tester.getRect(sheen), tester.getRect(native));
          final clip = tester.widget<ClipRRect>(
            find.ancestor(of: sheen, matching: find.byType(ClipRRect)).first,
          );
          expect(
            clip.borderRadius,
            BorderRadius.circular(MaterialTokens.controlRadius),
          );
        }
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          tester.getSize(find.byKey(const Key('disabled'))),
          const Size(48, 48),
        );
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(calls, 1);
        await tester.tap(find.byKey(const Key('disabled')));
        expect(calls, 1);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('disabled')))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final width in [280.0, 360.0, 720.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('bounded shared controls width$width scale$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(() => tester.view.resetPhysicalSize());
        addTearDown(() => tester.view.resetDevicePixelRatio());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 700),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MaterialActionButton(
                      buttonKey: const Key('action'),
                      onPressed: () {},
                      child: const Text('主操作'),
                    ),
                    MaterialTransientPanel(
                      key: const Key('bounded_panel'),
                      child: Text('合成帮助正文\n' * 100),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final rect = tester.getRect(find.byKey(const Key('bounded_panel')));
        expect(rect.width, lessThanOrEqualTo(480));
        expect(rect.height, lessThanOrEqualTo(560));
        final size = tester.getSize(find.byKey(const Key('action')));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        final card = tester.widget<Card>(find.byType(Card));
        expect(find.byType(MaterialCard), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          card.color,
          isNull,
        ); // Theme-safe fallback when no explicit scope.
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  testWidgets(
    'captured overlay retains exact scope theme and local container',
    (tester) async {
      final policy = _policy(Brightness.dark, 'glass');
      final viewportKey = GlobalKey();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final image = await recorder.endRecording().toImage(1, 1);
      addTearDown(image.dispose);
      final container = ProviderContainer(
        overrides: [_synthetic.overrideWithValue(43)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UncontrolledProviderScope(
              container: container,
              child: Theme(
                data: ThemeData(colorScheme: policy.colorScheme),
                child: MaterialScope(
                  policy: policy,
                  tokens: MaterialTokens.forWidth(360),
                  wallpaper: image,
                  viewportKey: viewportKey,
                  child: Builder(
                    builder: (context) => MaterialActionButton(
                      buttonKey: const Key('open'),
                      onPressed: () {
                        final capture = MaterialOverlayCapture.of(context);
                        showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(
                            backgroundColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            child: MaterialTransientPanel(
                              capture: capture,
                              child: Consumer(
                                builder: (context, ref, _) {
                                  final scope = MaterialScope.of(context);
                                  expect(
                                    identical(scope.policy, policy),
                                    isTrue,
                                  );
                                  expect(
                                    identical(scope.wallpaper, image),
                                    isTrue,
                                  );
                                  expect(
                                    identical(scope.viewportKey, viewportKey),
                                    isTrue,
                                  );
                                  expect(
                                    identical(
                                      ProviderScope.containerOf(context),
                                      container,
                                    ),
                                    isTrue,
                                  );
                                  expect(
                                    Theme.of(context).colorScheme.brightness,
                                    Brightness.dark,
                                  );
                                  return Text(
                                    '合成值${ref.watch(_synthetic)}',
                                    key: const Key('captured_body'),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                      child: const Text('打开'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.text('合成值43'), findsOneWidget);
      expect(find.byType(MaterialCard), findsOneWidget);
      expect(
        tester.widget<Card>(find.byType(Card)).color,
        policy.contentSurface,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('captured_body')), findsNothing);
      expect(
        container.read(_synthetic),
        43,
      ); // Panel never owns/disposes container.
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final mode in ['glass', 'off', 'solid', 'high', 'reduced', 'unknown']) {
      testWidgets('action edges stay visible across states $brightness $mode', (
        tester,
      ) async {
        final policy = _policy(brightness, mode);
        late BuildContext actionContext;
        await tester.pumpWidget(
          MaterialApp(
            theme: policy.applyTo(ThemeData(colorScheme: policy.colorScheme)),
            home: MaterialScope(
              policy: policy,
              tokens: MaterialTokens.forWidth(360),
              child: Builder(
                builder: (context) {
                  actionContext = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        final visibleSurface = Color.alphaBlend(
          policy.contentSurface,
          policy.opaqueSurface,
        );
        double contrast(Color color) {
          final a = Color.alphaBlend(color, visibleSurface).computeLuminance();
          final b = visibleSurface.computeLuminance();
          return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        }

        for (final role in MaterialActionRole.values) {
          final style = materialActionStyle(actionContext, role: role);
          final rest = style.side!.resolve({})!;
          final hover = style.side!.resolve({WidgetState.hovered})!;
          final pressed = style.side!.resolve({WidgetState.pressed})!;
          final focus = style.side!.resolve({WidgetState.focused})!;
          final disabled = style.side!.resolve({WidgetState.disabled})!;
          expect(focus.color, policy.focusColor);
          expect(focus.width, MaterialTokens.focusWidth);
          expect(
            style.side!.resolve({
              WidgetState.disabled,
              WidgetState.focused,
              WidgetState.hovered,
              WidgetState.pressed,
            }),
            disabled,
          );
          expect(
            style.overlayColor!.resolve({
              WidgetState.disabled,
              WidgetState.focused,
              WidgetState.hovered,
              WidgetState.pressed,
            }),
            Colors.transparent,
          );
          expect(
            style.foregroundColor!.resolve({WidgetState.disabled})!.a,
            lessThan(style.foregroundColor!.resolve({})!.a),
          );
          expect(
            style.overlayColor!.resolve({WidgetState.pressed})!.a,
            greaterThan(
              style.overlayColor!.resolve({WidgetState.hovered})!.a,
            ),
          );
          if (role == MaterialActionRole.auxiliary) {
            for (final states in [
              <WidgetState>{},
              {WidgetState.hovered},
              {WidgetState.pressed},
              {WidgetState.disabled},
            ]) {
              expect(style.backgroundColor!.resolve(states), Colors.transparent);
              expect(style.side!.resolve(states)!.color, Colors.transparent);
            }
            expect(style.backgroundBuilder, isNull);
          } else {
            expect(contrast(rest.color), greaterThanOrEqualTo(1.5));
            for (final states in [
              <WidgetState>{},
              {WidgetState.hovered},
              {WidgetState.pressed},
              {WidgetState.focused},
              {WidgetState.disabled},
            ]) {
              expect(style.backgroundColor!.resolve(states), policy.contentSurface);
              expect(
                style.shape!.resolve(states),
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
                ),
              );
            }
            if (policy.highContrast) {
              expect(hover, rest);
              expect(pressed, rest);
              expect(rest.width, MaterialTokens.focusWidth);
            } else {
              expect(contrast(hover.color), greaterThan(contrast(rest.color)));
              expect(contrast(pressed.color), greaterThan(contrast(hover.color)));
              expect(contrast(disabled.color), lessThan(contrast(rest.color)));
              expect(hover.width, rest.width);
              expect(pressed.width, rest.width);
            }
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final width in [280.0, 360.0, 720.0, 1100.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Chinese actions center in full plane width$width scale$scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final policy = _policy(Brightness.light, 'glass');
        for (final (role, label) in [
          (MaterialActionRole.primary, '保存'),
          (MaterialActionRole.secondary, '取消'),
          (MaterialActionRole.primary, '完成'),
          (MaterialActionRole.destructive, '清除合成的较长操作内容'),
        ]) {
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              // Caller themes must not pull a shared action off its center.
              theme: ThemeData(
                colorScheme: policy.colorScheme,
                filledButtonTheme: const FilledButtonThemeData(
                  style: ButtonStyle(alignment: Alignment.topLeft),
                ),
              ),
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 700),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(width),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width < 360 ? width - 32 : 240,
                        child: MaterialActionButton(
                          role: role,
                          buttonKey: const Key('Chinese_surface'),
                          onPressed: () => calls++,
                          child: Text(label, key: const Key('Chinese_label')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final button = find.byKey(const Key('Chinese_surface'));
          final text = find.byKey(const Key('Chinese_label'));
          final plane = tester.getRect(button);
          final content = tester.getRect(text);
          final paragraph = tester.renderObject<RenderParagraph>(text);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: label.length),
          );
          expect(boxes, isNotEmpty);
          expect((content.center.dx - plane.center.dx).abs(), lessThan(.5));
          expect((content.center.dy - plane.center.dy).abs(), lessThan(.5));
          for (final box in boxes) {
            final glyphs = box.toRect().shift(content.topLeft);
            expect((glyphs.center.dx - plane.center.dx).abs(), lessThan(.5));
            expect(plane.inflate(.5).contains(glyphs.topLeft), isTrue);
            expect(plane.inflate(.5).contains(glyphs.bottomRight), isTrue);
          }
          expect(plane.width, greaterThanOrEqualTo(materialControlTarget));
          expect(plane.height, greaterThanOrEqualTo(materialControlTarget));
          expect(
            tester.getRect(find.descendant(
              of: button,
              matching: find.byType(MaterialSheen),
            )),
            plane,
          );
          expect(find.byType(MaterialSheen), findsOneWidget);
          expect(find.byType(BackdropFilter), findsNothing);
          await tester.tapAt(plane.centerLeft + const Offset(2, 0));
          expect(calls, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      });
    }
  }

  test(
    'pure asset path leaf validates drive UNC and never relative fallback',
    () {
      expect(diaryDraftTagsAssetSuffix, 'diary-draft-tags-v1');
      expect(
        timeTraceStorageLocation(r'C:\synthetic\', diaryDraftTagsAssetSuffix),
        r'C:\synthetic\TimeTrace\diary-draft-tags-v1',
      );
      expect(
        timeTraceStorageLocation(r'\\server\share', 'diary_images'),
        r'\\server\share\TimeTrace\diary_images',
      );
      for (final base in [
        null,
        '',
        'relative',
        'C:relative',
        'bad\u0000path',
      ]) {
        expect(
          timeTraceStorageLocation(base, diaryDraftTagsAssetSuffix),
          isNull,
        );
      }
      for (final suffix in [
        '',
        '.',
        '..',
        '../escape',
        r'folder\child',
        'bad\u0000name',
      ]) {
        expect(timeTraceStorageLocation(r'C:\synthetic', suffix), isNull);
      }
    },
  );
}

void _acceptanceUsabilityTests() {
  for (final brightness in Brightness.values) {
    for (final mode in ['glass', 'unknown', 'high']) {
      testWidgets('visible whole button planes $brightness $mode', (tester) async {
        final policy = _policy(brightness, mode);
        late BuildContext target;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(colorScheme: policy.colorScheme),
          home: MaterialScope(
            policy: policy, tokens: MaterialTokens.forWidth(280),
            child: Builder(builder: (context) {
              target = context;
              return const SizedBox();
            }),
          ),
        ));
        final primary = materialActionStyle(target, role: MaterialActionRole.primary);
        final secondary = materialActionStyle(target);
        expect(primary.backgroundColor!.resolve({}),
          isNot(secondary.backgroundColor!.resolve({})));
        expect(secondary.backgroundColor!.resolve({})!.a, greaterThan(0));
        for (final style in [primary, secondary]) {
          final size = style.minimumSize!.resolve({})!;
          for (final states in <Set<WidgetState>>[
            {}, {WidgetState.hovered}, {WidgetState.pressed},
            {WidgetState.focused}, {WidgetState.disabled},
          ]) {
            expect(style.minimumSize!.resolve(states), size);
            expect(size.width, greaterThanOrEqualTo(48));
            expect(size.height, greaterThanOrEqualTo(48));
            expect(style.backgroundColor!.resolve(states),
              style.backgroundColor!.resolve({}));
            expect(style.side!.resolve(states)!.width, greaterThan(0));
          }
        }
        expect(find.byType(BackdropFilter), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
