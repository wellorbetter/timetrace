# Material foundation handoff

Receiver: host and independent architect +2 reviewer. Status: ready for application and review. Receiver: acceptance-verification. Status: ready for test implementation and execution after integration. Acceptance remains pending; the implementation author grants no review approval.

This execution returns candidate edits only. No tools, file writes, analyzer, tests or Windows checks were executed. Test source below is a handoff artifact, not a registered or executed test.

- Specification: 91582d27e8d58e775c9d95ffb678cd095643a7ebd3f324f3f0a3b4eed7538ee9.
- Plan: 510e1b400d0755d1c8dc5b057e61622daf7c179581c98eaba2e985b28ad76cc5.
- Supplied context manifest: d62235a3d6c70a7eb645084fb925ad989e1bf2782705302c6183874236c55d99.

## Supplied sources and current repair

Observations are from the supplied source snapshots, not runtime results. Paths below are relative to app/lib/src.

- app.dart, SHA-256 c583e48b6690551244c69e4d5a15ea8e4f3c03c7eed421c66f5b828bc47958cf: watches theme, font and background providers. Its builder paints Image.file, optional color, a surface mask with alpha 1 - background.opacity, then routed content. This snapshot does not install WallpaperEnvironment.
- features/settings/presentation/settings_screen.dart, SHA-256 cdf964dcd7ab687e4d72f550df24e07f774b93e18e1e814e417f98e2236422a8: paints the clear-data label and icon using colorScheme.error; section icons use primary; font previews use onSurfaceVariant. Presets are null, FFF7F3FF, FFE8F4FD, FFFDF2E9, FFF0F7EC and FF1A1A2E; opacity spans 0.15–1. Some Cards explicitly use transparent colors. Additional helper text uses outline and requires its own consumer accessibility audit.
- core/theme/timetrace_theme.dart, SHA-256 db045bf5312640e435fc857b654a6339da65be7a425b785b02bf2c2b5a250ae6: generates ColorScheme.fromSeed with a seasonal accent chosen by DateTime.now().month. Scaffold is transparent; AppBar explicitly uses surface alpha 0.78; CardThemeData uses elevation 1 and radius 12.
- core/theme/background_provider.dart, SHA-256 cdd0ce84823e6d8ecdc65e1bc3281fa14cf3d3a5acaf7948eafc7d47cac75bae: restores preferences through UiPreferencesStore; default opacity is 0.82. setColor clears the image; successful pickImage clears the color; setOpacity preserves selection. clear resets in-memory defaults and writes null color/image fields. Store merge semantics are not supplied. pickImage has no request-generation guard; no carousel scheduler appears here.
- core/responsive.dart, SHA-256 68329a7daefd1a23344144b022c7162b095c14680325a140fb3fcf6c246a84a8: widths below 720 are compact, below 1100 are medium, otherwise wide.
- core/theme/theme_provider.dart, SHA-256 f8ee318333d653af77bc8596773f3c02b37250c8a33378af5af56d0011d072e0: handles dark mode, without an accessibility-signal adapter.

The supplied review identifies a missing semantic-text constraint: checking only onSurface and onSurfaceVariant can allow a dark tint that makes settings' unchanged error text unreadable. This repair adds primary and error to the same predicate used for the composed color, theme baseline and every accepted search candidate. All four roles must reach 4.5:1. Tint is constrained while the original semantic colors, including error and its paired container roles, remain unchanged in ordinary mode. No new public arguments or consumer migration are needed.

The existing AppBarTheme and CardThemeData adaptation is retained, so the constrained opaque surface reaches Scaffold, AppBar, default Card and StableContentSurface without elevation tint. This change does not modify the shared-browsing findings, which belong to another work order.

Ownership and integration points are supported by fact-current-ui-paths. The visual preference is supported by pref-glass-material; it is not evidence of measured contrast or Windows accessibility support.

## Public interfaces and integration

Import package:timetrace_app/src/core/material/material.dart.

App environment owner: install one WallpaperEnvironment in the bounded MaterialApp builder and forward the routed child without wallpaper-dependent keys. Map the selected local image to FileImage, or pass null. Forward background.color and background.opacity unchanged, including the provider's 0.82 default. The environment's independent opacity default is 0.5. Preserve the existing provider and persistence behavior. app.dart is outside this work order's ownership.

Feed, data, diary and settings owners: use StableContentSurface for reading regions and MaterialScope.of(context).tokens for widthClass, pageInset and sectionGap. Retain controllers, stable keys and one main vertical scrollable. WallpaperEnvironment installs the outer GlassWorkSurface. Nested work surfaces and descendants of stable content do not add active backdrop blur.

MaterialIconButton supplies a tooltip label, focused outline and minimum 44 logical-pixel target. Host constraints and keyboard/semantic behavior still need verification. Explicit widget background colors can bypass component themes. Read semantic text colors from the adapted Theme below WallpaperEnvironment. Transparent Cards over the opaque Scaffold inherit its backdrop, but arbitrary explicit fills require separate checks.

## Policy and accessibility contract

MaterialPolicy.resolve is pure. Inputs are ColorScheme, WallpaperLoadState, tri-state MaterialSignals, optional backgroundColor and backgroundOpacity. Missing platform signals remain unknown. Framework highContrast true overrides even injected disabled; false does not establish disabled. Do not infer reduced transparency from brightness, accessibleNavigation or disableAnimations.

Only ready wallpaper plus explicitly disabled high contrast and reduced transparency permits glass. Opaque-reason priority is enabled high contrast, enabled reduced transparency, unknown high contrast, unknown reduced transparency, then absent/loading/failed wallpaper. Wallpaper state remains separately observable.

With absent wallpaper and no enabled high contrast, the selected color is composited over the opaque theme base, followed by the theme mask with alpha 1 - configured opacity. This preserves solid-color preferences with unknown signals or enabled reduced transparency. Opacity is clamped to 0–1; non-finite input uses 0.5.

The solid-color guard checks onSurface, onSurfaceVariant, primary and error at 4.5:1 against the final opaque surface, compositing any foreground alpha before measuring luminance. It accepts a readable composed color directly; otherwise, with a readable baseline, it searches toward the selected tint while retaining only candidates that pass all four constraints. This is a safe-candidate search, not a claim of a globally maximal tint. Tint limiting can saturate slider effects.

If both the proposed color and theme baseline fail the four-role predicate, the existing baseline is retained and must be reported as a theme defect. This repair does not claim to fix arbitrary invalid ColorSchemes. The baseline exception must not suppress failures in the actual TimetraceTheme regression matrix. Additional colors such as outline, secondary, tertiary, custom TextStyles and disabled-state opacity need separate checks; primary and error are explicitly covered by this repair.

In opaque mode fallbackSurface, workSurface, contentSurface and themed Scaffold/AppBar/Card backgrounds are fully opaque. Do not apply user opacity again. ColorScheme.surface and canvasColor remain the original theme base. The four-role tint guard applies to fallbackSurface; it does not certify arbitrary wallpaper composites in glass mode.

High contrast ignores tint, uses black/white surface and ordinary foreground, and preserves an explicit red error role. Enabled glass uses work alpha 0.72 and stable-content alpha 0.97. AppBar/Card adaptation adds no blur, elevation tint or shadow.

No verified Windows accessibility adapter is supplied. Default construction remains opaque and unblurred, including with an image selected. Injected disabled signals are test inputs, not evidence of platform support. This module adds no platform bridge or persistence protocol.

## Widths, layers and lifecycle

MaterialBreakpoints delegates production classification to screenSizeOf: compact [0, 720), medium [720, 1100), wide [1100, infinity). Exactly 720 is medium and exactly 1100 is wide. Optional paired test thresholds do not introduce another production default. Invalid widths or incomplete, non-finite, non-positive or unordered threshold pairs are rejected. availableWidth injects classification; real constraints still determine the viewport.

Paint order is opaque theme base, permitted current wallpaper, selected color, theme mask, then one work surface. Stable content adds no blur. Tokens centralize spacing, radii, border/focus widths, blur, shadow and minimum target size. Components introduce no scrollables, carousel timers, transition switchers or wallpaper/width-derived keys. Consumers retain responsibility for their controllers and keys.

WallpaperEnvironment accepts an injectable ImageProvider. Provider or ImageConfiguration changes increment generation, detach the old listener, clear the image and enter loading or absent. Current frames enter ready. Stale callbacks cannot replace the current image; stale ImageInfo handles are disposed. Current errors invalidate generation, detach the listener, clear the image and enter failed. Replaced handles are released after the frame without touching State. Disposal invalidates callbacks, detaches the listener and releases the current handle. Flutter owns its shared image cache.

Same-path replacement may require owner-managed cache eviction. Decoder-result isolation does not resolve upstream late FilePicker completions in BackgroundNotifier. Failure retries require a changed provider/configuration or clearing and selecting again. These existing limitations remain outside this repair.

## Regression source for acceptance-verification

The following source is supplied for the acceptance owner to place in its owned app/test/p1_p2 directory and run through fact-flutter-validator-scope. It is not installed by this work order because that directory has separate ownership. The deterministic tests independently exercise primary and error as the limiting semantic role; both should expose the previous two-role predicate. The widget test uses actual TimetraceTheme light/dark factories and the complete supplied settings preset list. It mounts representative settings text using the four theme roles and checks the resolved opaque component backgrounds. It is not a mount of the complete SettingsScreen or a screenshot/pixel test.

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';

double contrast(Color ink, Color surface) {
  final foreground = Color.alphaBlend(ink, surface).computeLuminance();
  final background = surface.computeLuminance();
  return (math.max(foreground, background) + 0.05) /
      (math.min(foreground, background) + 0.05);
}

Map<String, Color> textRoles(ColorScheme scheme) => {
      'onSurface': scheme.onSurface,
      'onSurfaceVariant': scheme.onSurfaceVariant,
      'primary': scheme.primary,
      'error': scheme.error,
    };

void expectReadable(ColorScheme scheme, Color surface, String context) {
  expect(surface.a, 1.0, reason: context);
  for (final role in textRoles(scheme).entries) {
    expect(
      contrast(role.value, surface),
      greaterThanOrEqualTo(4.5),
      reason: '$context: ${role.key}',
    );
  }
}

void main() {
  for (final limitingRole in ['primary', 'error']) {
    test('dark tint protects unchanged $limitingRole text', () {
      const semanticInk = Color(0xFF8B0000);
      final source = ColorScheme.fromSeed(seedColor: Colors.blue).copyWith(
        surface: Colors.white,
        onSurface: Colors.black,
        onSurfaceVariant: Colors.black,
        primary: limitingRole == 'primary' ? semanticInk : Colors.black,
        error: limitingRole == 'error' ? semanticInk : Colors.black,
      );
      expectReadable(source, Colors.white, 'fixture baseline');
      final policy = MaterialPolicy.resolve(
        colorScheme: source,
        wallpaper: WallpaperLoadState.absent,
        backgroundColor: Colors.black,
        backgroundOpacity: 1,
      );
      final adapted = policy.applyTo(ThemeData(colorScheme: source));
      expect(policy.allowsGlass, isFalse);
      expect(policy.fallbackSurface, isNot(Colors.black));
      expect(textRoles(adapted.colorScheme), textRoles(source));
      expect(adapted.colorScheme.onError, source.onError);
      expect(adapted.colorScheme.errorContainer, source.errorContainer);
      expect(adapted.colorScheme.onErrorContainer, source.onErrorContainer);
      for (final surface in [
        policy.fallbackSurface,
        policy.workSurface,
        policy.contentSurface,
        adapted.scaffoldBackgroundColor,
        adapted.appBarTheme.backgroundColor!,
        adapted.cardTheme.color!,
      ]) {
        expectReadable(adapted.colorScheme, surface, limitingRole);
      }
    });
  }

  testWidgets('settings text roles remain readable across solid presets',
      (tester) async {
    const presets = <Color?>[
      null,
      Color(0xFFF7F3FF),
      Color(0xFFE8F4FD),
      Color(0xFFFDF2E9),
      Color(0xFFF0F7EC),
      Color(0xFF1A1A2E),
    ];
    final themes = [TimetraceTheme.light(), TimetraceTheme.dark()];
    for (final source in themes) {
      for (final preset in presets) {
        for (final opacity in [0.15, 0.5, 0.82, 1.0]) {
          late MaterialPolicy policy;
          late ThemeData adapted;
          await tester.pumpWidget(MaterialApp(
            theme: source,
            home: WallpaperEnvironment(
              backgroundColor: preset,
              backgroundOpacity: opacity,
              child: Builder(builder: (context) {
                policy = MaterialScope.of(context).policy;
                adapted = Theme.of(context);
                final scheme = adapted.colorScheme;
                return Scaffold(
                  appBar: AppBar(title: const Text('设置')),
                  body: StableContentSurface(
                    child: Card(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('设置正文', key: const ValueKey('onSurface'),
                              style: TextStyle(color: scheme.onSurface)),
                          Text('字体预览', key: const ValueKey('onSurfaceVariant'),
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                          Text('主题', key: const ValueKey('primary'),
                              style: TextStyle(color: scheme.primary)),
                          Text('清除数据', key: const ValueKey('error'),
                              style: TextStyle(color: scheme.error)),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ));
          await tester.pump();
          final label = '${source.brightness}, $preset, $opacity';
          expect(tester.takeException(), isNull, reason: label);
          expect(policy.wallpaper, WallpaperLoadState.absent);
          expect(policy.signals.highContrast, AccessibilitySignal.unknown);
          expect(policy.signals.reduceTransparency, AccessibilitySignal.unknown);
          expect(policy.allowsGlass, isFalse);
          expect(textRoles(adapted.colorScheme), textRoles(source.colorScheme));
          for (final surface in [
            adapted.scaffoldBackgroundColor,
            adapted.appBarTheme.backgroundColor!,
            adapted.cardTheme.color!,
            policy.workSurface,
            policy.contentSurface,
          ]) {
            expect(surface, policy.fallbackSurface, reason: label);
            expectReadable(adapted.colorScheme, surface, label);
          }
          for (final role in textRoles(adapted.colorScheme).entries) {
            final text = tester.widget<Text>(find.byKey(ValueKey(role.key)));
            expect(text.style!.color, role.value, reason: label);
            expect(contrast(text.style!.color!, policy.fallbackSurface),
                greaterThanOrEqualTo(4.5), reason: '$label: ${role.key}');
          }
          expect(adapted.appBarTheme.surfaceTintColor, Colors.transparent);
          expect(adapted.appBarTheme.scrolledUnderElevation, 0);
          expect(adapted.cardTheme.surfaceTintColor, Colors.transparent);
          expect(adapted.cardTheme.elevation, 0);
        }
      }
    }
  });
}
```

## Required verification and remaining handoff

Receiver: acceptance-verification. Status: pending execution. Record actual results, including failures; none of the following are execution evidence.

1. Install and execute the supplied regression tests. Mount the actual integrated SettingsScreen with its existing provider fixtures as well, including the clear-data row, font preview and primary controls. Cover both TimetraceTheme modes, every listed preset, opacity 0.15/0.5/0.82/1, and default unknown signals. Check the actual text colors and final painted backgrounds at 4.5:1. Record the date and generated seasonal scheme; the theme factory reads the clock. Additional seasonal seed fixtures should cover the four supplied seed values 00897B, 1976D2, EF6C00 and 3949AB without changing production clock behavior.
2. Test readable tint passthrough, null and alpha-bearing colors, invalid opacity, and the explicitly unsupported unreadable baseline. Add a fixture with a translucent semantic foreground to verify alpha compositing. Do not treat a failing actual TimetraceTheme baseline as an allowed test exception.
3. Cover absent/loading/ready/failed wallpaper and all nine accessibility-signal pairs in both themes. Only ready plus disabled/disabled enables glass. Check framework true override and false preserving unknown. High contrast must retain readable red error text and visible boundaries/focus.
4. Inspect rendered Scaffold/AppBar/Card/stable-content backgrounds and elevation behavior before and after scrolling. Check explicit consumer overrides and helper text using outline separately. For glass mode, measure the actual wallpaper composites; the solid-tint guard alone does not certify them.
5. Compare classification with screenSizeOf at 719/720/721 and 1099/1100/1101, fractional boundaries, invalid widths and injected thresholds. Verify State identity, controllers, route selection and scroll offsets through width, background and signal changes. Components must add no vertical scrollables and at most one enabled BackdropFilter.
6. Use controlled ImageProviders for A loading → B ready → A late success/error, A → B → A, clearing during loading, synchronous cache hits, animated frames, configuration changes, failures and disposal before completion. Verify listener and ImageInfo cleanup. Upstream picker races require their separately assigned owner.
7. Run the pinned Flutter analyze and full flutter test entry point identified by fact-flutter-validator-scope. Record independent +2 review and Windows three-width screenshots, keyboard/mouse behavior, missing/invalid/large images, rapid selections, long scrolling and continuous resizing. Full integration, platform support, measured performance and acceptance remain unverified until those records exist.
