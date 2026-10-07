import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/material/refractive_backdrop.dart';
import 'package:timetrace_app/src/core/theme/material_appearance_provider.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import 'package:timetrace_app/src/features/settings/presentation/background_color_picker.dart';
import 'package:timetrace_app/src/features/settings/presentation/material_appearance_settings.dart';

const signals = MaterialSignals(
  highContrast: AccessibilitySignal.disabled,
  reduceTransparency: AccessibilitySignal.disabled,
);

class FakeAppearance extends MaterialAppearanceNotifier {
  int saves = 0;
  @override
  MaterialAppearance build() => const MaterialAppearance();
  @override
  void persist() => saves++;
}

Widget host(
  Widget child, {
  MaterialAppearance appearance = const MaterialAppearance(),
}) => MaterialApp(
  home: WallpaperEnvironment(
    signals: signals,
    appearance: appearance,
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    for (final mode in ['glass', 'off', 'reduced']) {
      testWidgets(
        'help single shared surface $brightness $mode closes and restores focus',
        (tester) async {
          final scheme = ColorScheme.fromSeed(
            seedColor: const Color(0xff797252),
            brightness: brightness,
          );
          final policy = MaterialPolicy.resolve(
            colorScheme: scheme,
            wallpaper: WallpaperLoadState.absent,
            signals: mode == 'reduced'
                ? const MaterialSignals(
                    highContrast: AccessibilitySignal.disabled,
                    reduceTransparency: AccessibilitySignal.enabled,
                  )
                : signals,
            appearance: MaterialAppearance(cardEffects: mode != 'off'),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(colorScheme: scheme),
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(
                    size: Size(320, 240),
                    textScaler: TextScaler.linear(2),
                    disableAnimations: true,
                  ),
                  child: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(320),
                    child: ContextHelp(message: '合成说明，仅按需阅读。' * 30),
                  ),
                ),
              ),
            ),
          );
          final trigger = find.byTooltip('说明');
          expect(tester.getSize(trigger), const Size(48, 48));
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final surface = find.byKey(const Key('context_help_surface'));
          expect(surface, findsOneWidget);
          expect(find.byType(MaterialCard), findsOneWidget);
          final card = tester.widget<Card>(
            find.descendant(of: surface, matching: find.byType(Card)),
          );
          expect(card.color, policy.contentSurface);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.getSize(surface).width, lessThanOrEqualTo(280));
          expect(tester.getSize(surface).height, lessThanOrEqualTo(156));
          expect(
            tester
                .widget<MenuAnchor>(find.byType(MenuAnchor))
                .style!
                .backgroundColor!
                .resolve({}),
            Colors.transparent,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(surface, findsNothing);
          expect(
            tester
                .widget<IconButton>(find.byType(IconButton))
                .focusNode!
                .hasFocus,
            isTrue,
          );
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(700, 500));
          await tester.pumpAndSettle();
          expect(surface, findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'compiled refraction bends image edges but leaves center unchanged',
    (tester) async {
      await tester.runAsync(() async {
        final program = await ui.FragmentProgram.fromAsset(cardRefractionAsset);
        final sourceRecorder = ui.PictureRecorder();
        final sourceCanvas = Canvas(sourceRecorder);
        sourceCanvas.drawColor(Colors.blue, BlendMode.src);
        sourceCanvas.drawRect(
          const Rect.fromLTWH(0, 0, 20, 100),
          Paint()..color = Colors.red,
        );
        final sourcePicture = sourceRecorder.endRecording();
        final source = await sourcePicture.toImage(100, 100);
        sourcePicture.dispose();
        Future<List<int>> render(double strength) async {
          final shader = program.fragmentShader();
          final values = [
            100.0,
            100.0,
            0.0,
            0.0,
            100.0,
            100.0,
            100.0,
            100.0,
            16.0,
            strength,
            0.0,
            .6,
            1.0,
            1.0,
            1.0,
            1.0,
            1.0,
            1.0,
            1.0,
            0.0,
            // Appended interaction uniforms: legacy path remains inactive.
            0.0,
            0.0,
            0.0,
          ];
          for (var i = 0; i < values.length; i++) {
            shader.setFloat(i, values[i]);
          }
          shader.setImageSampler(0, source);
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 100, 100),
            Paint()..shader = shader,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(100, 100);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List().toList();
          image.dispose();
          picture.dispose();
          shader.dispose();
          return bytes;
        }

        try {
          final plain = await render(0);
          final refracted = await render(24);
          final edge = (50 * 100 + 5) * 4;
          final center = (50 * 100 + 50) * 4;
          expect(
            refracted.sublist(edge, edge + 3),
            isNot(plain.sublist(edge, edge + 3)),
          );
          expect(
            refracted.sublist(center, center + 4),
            plain.sublist(center, center + 4),
          );
        } finally {
          source.dispose();
        }
      });
    },
  );
  test('card toggle and light intensity normalize and persist', () {
    final settings = MaterialAppearance.fromPreferences({
      'cardEffects': false,
      'surfaceLight': 4,
    });
    expect(settings.cardEffects, false);
    expect(settings.light, 1);
    expect(
      MaterialAppearance.fromPreferences(settings.toPreferences()).cardEffects,
      false,
    );
    final policy = MaterialPolicy.resolve(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      wallpaper: WallpaperLoadState.ready,
      signals: signals,
      appearance: settings,
    );
    expect(policy.contentSurface.a, 1);
    expect(policy.allowsBlur, true);
  });
  testWidgets(
    'material cards share one blur and opacity toggle without remounting editor',
    (tester) async {
      Widget page(MaterialAppearance value) => host(
        const MaterialCard(child: TextField(key: Key('card_draft'))),
        appearance: value,
      );
      await tester.pumpWidget(page(const MaterialAppearance()));
      await tester.enterText(find.byKey(const Key('card_draft')), 'retained');
      final before = tester.widget<Card>(find.byType(Card)).color!;
      expect(before.a, lessThan(1));
      await tester.pumpWidget(
        page(const MaterialAppearance(cardEffects: false, light: 0)),
      );
      expect(tester.widget<Card>(find.byType(Card)).color!.a, 1);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'retained',
      );
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .where((item) => item.enabled)
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('hex accepts RGB only and preserves independent opacity', () {
    expect(parseBackgroundHex(' #aBc123 '), const Color(0xffabc123));
    for (final input in ['abc', 'gggggg', '#ff112233', '']) {
      expect(parseBackgroundHex(input), isNull);
    }
    expect(backgroundHex(const Color(0x12123456)), '#123456');
  });
  test('material preferences roundtrip and clamp invalid values', () {
    const value = MaterialAppearance(
      style: SurfaceStyle.blend,
      workOpacity: .4,
      contentOpacity: .7,
      blur: 32,
      tint: .6,
    );
    expect(
      MaterialAppearance.fromPreferences(value.toPreferences()).toPreferences(),
      value.toPreferences(),
    );
    final invalid = MaterialAppearance.fromPreferences({
      'surfaceStyle': 'missing',
      'surfaceOpacity': -3,
      'contentOpacity': 8,
      'surfaceBlur': double.nan,
      'surfaceTint': 'bad',
    });
    expect(invalid.style, SurfaceStyle.glass);
    expect(invalid.workOpacity, .2);
    expect(invalid.contentOpacity, 1);
    expect(invalid.blur, 24);
    expect(invalid.tint, .15);
  });
  test('glass blend solid have distinct blur and alpha policies', () {
    for (final style in SurfaceStyle.values) {
      final policy = MaterialPolicy.resolve(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        wallpaper: WallpaperLoadState.ready,
        signals: signals,
        appearance: MaterialAppearance(
          style: style,
          cardStyle: style,
          workOpacity: .4,
          contentOpacity: .7,
        ),
      );
      expect(policy.allowsBlur, style == SurfaceStyle.glass);
      expect(
        policy.workSurface.a,
        closeTo(style == SurfaceStyle.solid ? 1 : .4, .005),
      );
      expect(
        policy.contentSurface.a,
        closeTo(style == SurfaceStyle.solid ? 1 : .7, .005),
      );
    }
  });
  test('accessibility always overrides all user materials', () {
    for (final style in SurfaceStyle.values) {
      for (final high in AccessibilitySignal.values) {
        for (final reduce in AccessibilitySignal.values) {
          final policy = MaterialPolicy.resolve(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
            wallpaper: WallpaperLoadState.ready,
            signals: MaterialSignals(
              highContrast: high,
              reduceTransparency: reduce,
            ),
            appearance: MaterialAppearance(style: style),
          );
          final allowed =
              high == AccessibilitySignal.disabled &&
              reduce == AccessibilitySignal.disabled &&
              style != SurfaceStyle.solid;
          expect(policy.allowsGlass, allowed);
          expect(
            policy.allowsCardGlass,
            high == AccessibilitySignal.disabled &&
                reduce == AccessibilitySignal.disabled,
          );
          if (!allowed) {
            expect(policy.workSurface.a, 1);
            if (high != AccessibilitySignal.disabled ||
                reduce != AccessibilitySignal.disabled) {
              expect(policy.contentSurface.a, 1);
            }
            expect(policy.allowsBlur, false);
          }
        }
      }
    }
  });
  for (final width in [320.0, 900.0]) {
    testWidgets('picker drafts then applies at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Color? applied;
      await tester.pumpWidget(
        host(
          BackgroundColorPicker(
            initialColor: Colors.blue,
            onApply: (value) => applied = value,
          ),
        ),
      );
      await tester.drag(
        find.byKey(const Key('background_color_plane')),
        const Offset(30, 30),
      );
      await tester.pump();
      expect(applied, isNull);
      await tester.enterText(
        find.byKey(const Key('background_hex')),
        '#ZZZZZZ',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('background_apply_color')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('background_hex')),
        '#C87B91',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('background_apply_color')));
      expect(applied, const Color(0xffc87b91));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'material controls preview before save and disable blur in blend',
    (tester) async {
      final fake = FakeAppearance();
      var forbiddenBackendReads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            materialAppearanceProvider.overrideWith(() => fake),
            uiPreferencesBackendProvider.overrideWith((ref) {
              forbiddenBackendReads++;
              throw StateError('private preferences backend forbidden');
            }),
          ],
          child: host(const MaterialAppearanceSettings()),
        ),
      );
      final slider = tester.widget<Slider>(
        find.byKey(const Key('surface_opacity')),
      );
      slider.onChanged!(.35);
      await tester.pump();
      expect(fake.saves, 0);
      expect(
        tester.widget<Slider>(find.byKey(const Key('surface_opacity'))).value,
        .35,
      );
      slider.onChangeEnd!(.35);
      expect(fake.saves, 1);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('surface_help')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('背景不透明度控制图片或底色'), findsOneWidget);
      await tester.tapAt(const Offset(750, 550));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('surface_style_blend')));
      await tester.tap(find.byKey(const Key('surface_style_blend')));
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('surface_blur'))).onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const Key('surface_style_solid')));
      await tester.pump();
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('surface_opacity')))
            .onChanged,
        isNull,
      );
      expect(tester.takeException(), isNull);
      expect(forbiddenBackendReads, 0);
    },
  );
  test('background and card material are independent and bounded', () {
    final appearance = MaterialAppearance.fromPreferences({
      'surfaceStyle': 'solid',
      'cardStyle': 'glass',
      'cardBlur': 99,
      'cardRefraction': -1,
      'cardTint': double.nan,
    });
    expect(appearance.cardBlur, 12);
    expect(appearance.refraction, 0);
    expect(appearance.cardTint, .12);
    expect(
      MaterialAppearance.fromPreferences(
        appearance.toPreferences(),
      ).toPreferences(),
      appearance.toPreferences(),
    );
    final policy = MaterialPolicy.resolve(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      wallpaper: WallpaperLoadState.ready,
      signals: signals,
      appearance: appearance,
    );
    expect(policy.allowsGlass, false);
    expect(policy.allowsCardGlass, true);
    expect(policy.contentSurface.a, lessThan(1));
    final restricted = MaterialPolicy.resolve(
      colorScheme: policy.colorScheme,
      wallpaper: WallpaperLoadState.ready,
      appearance: appearance,
    );
    expect(restricted.allowsCardGlass, false);
    expect(restricted.contentSurface.a, 1);
  });
  testWidgets(
    'root has no duplicate rounded edge and only one active blur; state survives',
    (tester) async {
      Widget page(MaterialAppearance appearance) => host(
        const StableContentSurface(
          child: GlassWorkSurface(child: TextField(key: Key('draft'))),
        ),
        appearance: appearance,
      );
      await tester.pumpWidget(page(const MaterialAppearance()));
      await tester.enterText(find.byKey(const Key('draft')), 'keep my draft');
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .where((item) => item.enabled)
            .length,
        1,
      );
      final root = tester
          .widgetList<GlassWorkSurface>(find.byType(GlassWorkSurface))
          .first;
      expect(root.edgeToEdge, true);
      expect(
        tester.widgetList<ClipRRect>(find.byType(ClipRRect)).first.borderRadius,
        BorderRadius.zero,
      );
      await tester.pumpWidget(
        page(const MaterialAppearance(style: SurfaceStyle.blend)),
      );
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .where((item) => item.enabled),
        isEmpty,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'keep my draft',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
