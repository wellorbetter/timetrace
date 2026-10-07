import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/material/refractive_backdrop.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';

final _local = Provider<int>(
  (ref) => throw StateError('default access forbidden'),
);
MaterialPolicy _policy({bool solid = false}) => MaterialPolicy.resolve(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
  wallpaper: WallpaperLoadState.ready,
  signals: const MaterialSignals(
    highContrast: AccessibilitySignal.disabled,
    reduceTransparency: AccessibilitySignal.disabled,
  ),
  appearance: MaterialAppearance(
    cardStyle: solid ? SurfaceStyle.solid : SurfaceStyle.glass,
  ),
);
Future<ui.Image> _image(Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, BlendMode.src);
  return recorder.endRecording().toImage(2, 2);
}

MaterialSamplingSnapshot _snapshot(
  int generation, {
  ui.Image? image,
  GlobalKey? viewport,
  bool active = true,
  bool interactive = false,
  MaterialPolicy? policy,
}) => MaterialSamplingSnapshot(
  generation: generation,
  policy: policy ?? _policy(),
  tokens: MaterialTokens.forWidth(360),
  image: image,
  viewportKey: viewport,
  active: active,
  interactionEnabled: interactive,
);
Widget _app(MaterialSamplingHandle? handle, Widget child, {ui.Image? legacy}) =>
    MaterialApp(
      home: Scaffold(
        body: MaterialScope(
          policy: _policy(),
          tokens: MaterialTokens.forWidth(360),
          wallpaper: legacy,
          samplingHandle: handle,
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );

class _StableBusiness extends ConsumerStatefulWidget {
  const _StableBusiness({
    required this.onMount,
    required this.onDispose,
    super.key,
  });
  final VoidCallback onMount, onDispose;
  @override
  ConsumerState<_StableBusiness> createState() => _StableBusinessState();
}

class _StableBusinessState extends ConsumerState<_StableBusiness> {
  final text = TextEditingController(text: '未提交内容');
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    height: 60,
    child: TextField(
      controller: text,
      decoration: InputDecoration(labelText: '合成值${ref.watch(_local)}'),
    ),
  );
}

void main() {
  test(
    'resources and paint are separate; invalid/close visible before callback',
    () async {
      final image = await _image(Colors.blue);
      final handle = MaterialSamplingHandle(_snapshot(1, image: image));
      var resources = 0, paints = 0;
      void resource() {
        resources++;
        if (!handle.current.active) expect(handle.current.image, isNull);
      }

      handle.resourceChanges.addListener(resource);
      handle.paintInvalidation.addListener(() => paints++);
      handle.invalidatePaint();
      expect(paints, 1);
      expect(resources, 0);
      handle.invalidate(generation: 2);
      expect(resources, 1);
      expect(handle.current.image, isNull);
      handle.publish(_snapshot(1, image: image)); // late generation rejected
      expect(handle.current.generation, 2);
      handle.publish(_snapshot(3, image: image, interactive: true));
      expect(handle.current.allowsInteraction, isTrue);
      expect(resources, 2);
      handle.close();
      expect(handle.closed, isTrue);
      expect(handle.current.image, isNull);
      expect(handle.current.allowsInteraction, isFalse);
      expect(resources, 3);
      expect(paints, 2);
      var late = 0;
      handle.resourceChanges.addListener(() => late++);
      handle.paintInvalidation.addListener(() => late++);
      handle.resourceChanges.removeListener(resource);
      handle.publish(_snapshot(4, image: image));
      handle.invalidatePaint();
      handle.close();
      expect(late, 0);
      expect(resources, 3);
      // Handle only borrows: owner still has a live image.
      expect(image.width, 2);
      image.dispose();
    },
  );

  test(
    'inactive snapshot strips supplied image and defaults interaction off',
    () async {
      final image = await _image(Colors.red);
      final handle = MaterialSamplingHandle(
        _snapshot(0, image: image, active: false),
      );
      expect(handle.current.image, isNull);
      expect(handle.current.interactionEnabled, isFalse);
      handle.close();
      image.dispose();
    },
  );

  testWidgets(
    'legacy renderer constructor compiles with nullable public leaf',
    (tester) async {
      MaterialSamplingInput? leaf;
      await tester.pumpWidget(
        _app(
          null,
          MaterialSheen(
            child: Builder(
              builder: (context) {
                leaf = MaterialSamplingInput.maybeOf(context);
                return const SizedBox(width: 80, height: 52);
              },
            ),
          ),
        ),
      );
      expect(leaf, isNotNull);
      expect(leaf!.handle, isNull);
      expect(leaf!.pointer!.value.active, isFalse);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('live overlay capture keeps exact business state and container', (
    tester,
  ) async {
    final a = await _image(Colors.blue), b = await _image(Colors.red);
    final handle = MaterialSamplingHandle(
      _snapshot(1, image: a, policy: _policy(solid: true)),
    );
    final container = ProviderContainer(
      overrides: [_local.overrideWithValue(43)],
    );
    MaterialOverlayCapture? capture;
    var mounts = 0, disposals = 0;
    await tester.pumpWidget(
      _app(
        handle,
        UncontrolledProviderScope(
          container: container,
          child: Builder(
            builder: (context) {
              capture = MaterialOverlayCapture.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final business = _StableBusiness(
      key: const ValueKey('stable_business'),
      onMount: () => mounts++,
      onDispose: () => disposals++,
    );
    await tester.pumpWidget(
      _app(null, capture!.wrap(MaterialCard(child: business))),
    );
    await tester.enterText(find.byType(TextField), '仍在编辑');
    expect(find.text('合成值43'), findsOneWidget);
    final state = tester.state(find.byType(_StableBusiness));
    final context = tester.element(find.byType(_StableBusiness));
    expect(ProviderScope.containerOf(context), same(container));
    expect(MaterialScope.of(context).wallpaper, same(a));
    handle.publish(_snapshot(2, image: b, policy: _policy(solid: true)));
    // Dynamic public getters are current even before the wrapper notification.
    expect(MaterialScope.of(context).wallpaper, same(b));
    await tester.pump();
    await tester.pump();
    expect(tester.state(find.byType(_StableBusiness)), same(state));
    expect(find.text('仍在编辑'), findsOneWidget);
    expect(
      ProviderScope.containerOf(tester.element(find.byType(_StableBusiness))),
      same(container),
    );
    expect(mounts, 1);
    expect(disposals, 0);
    handle.close();
    expect(MaterialScope.of(context).wallpaper, isNull);
    await tester.pump();
    await tester.pump();
    expect(tester.state(find.byType(_StableBusiness)), same(state));
    expect(find.text('仍在编辑'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(disposals, 1);
    expect(container.read(_local), 43);
    container.dispose();
    a.dispose();
    b.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'handle image-free current never falls back to legacy wallpaper',
    (tester) async {
      final legacy = await _image(Colors.red);
      final handle = MaterialSamplingHandle(_snapshot(1, active: false));
      await tester.pumpWidget(
        _app(
          handle,
          const MaterialSheen(child: SizedBox(width: 80, height: 52)),
          legacy: legacy,
        ),
      );
      expect(find.byType(RefractiveBackdrop), findsNothing);
      handle.close();
      await tester.pump();
      expect(find.byType(RefractiveBackdrop), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      legacy.dispose();
    },
  );

  testWidgets(
    'per-card local pointer is passive, off by default, clears on leave/close',
    (tester) async {
      final image = await _image(Colors.blue);
      final handle = MaterialSamplingHandle(_snapshot(1, image: image));
      MaterialSamplingInput? left, right;
      var taps = 0;
      Widget card(String name, void Function(MaterialSamplingInput?) read) =>
          MaterialSheen(
            child: Builder(
              builder: (context) {
                read(MaterialSamplingInput.maybeOf(context));
                return SizedBox(
                  width: 80,
                  height: 52,
                  child: TextButton(
                    key: Key(name),
                    onPressed: () => taps++,
                    child: Text(name),
                  ),
                );
              },
            ),
          );
      await tester.pumpWidget(
        _app(
          handle,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              card('left', (input) => left = input),
              card('right', (input) => right = input),
            ],
          ),
        ),
      );
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(400, 300));
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('left'))));
      await tester.pump();
      expect(left!.pointer!.value.active, isFalse);
      handle.publish(_snapshot(2, image: image, interactive: true));
      await tester.pump();
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('left'))) + const Offset(1, 0),
      );
      await tester.pump();
      expect(left!.pointer!.value.active, isTrue);
      expect(left!.pointer!.value.position!.dx, closeTo(41, .01));
      expect(right!.pointer!.value.active, isFalse);
      expect(identical(left!.pointer, right!.pointer), isFalse);
      await tester.tap(find.byKey(const Key('left')));
      expect(taps, 1); // passive Listener did not consume button gesture
      await mouse.moveTo(const Offset(400, 300));
      await tester.pump();
      expect(left!.pointer!.value.active, isFalse);
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('left'))));
      await tester.pump();
      expect(left!.pointer!.value.active, isTrue);
      handle.close();
      expect(left!.pointer!.value.active, isFalse);
      await tester.pump();
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      handle.invalidatePaint(); // late callbacks remain harmless
      image.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resource queued notification after root disposal is harmless', (
    tester,
  ) async {
    final handle = MaterialSamplingHandle(_snapshot(1));
    MaterialOverlayCapture? capture;
    await tester.pumpWidget(
      _app(
        handle,
        Builder(
          builder: (context) {
            capture = MaterialOverlayCapture.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        null,
        capture!.wrap(
          const MaterialSheen(child: SizedBox(width: 80, height: 52)),
        ),
      ),
    );
    handle.invalidate(generation: 2);
    await tester.pumpWidget(const SizedBox());
    handle.close();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final role in MaterialActionRole.values) {
    testWidgets(
      'role $role full target center and auxiliary has zero sampler',
      (tester) async {
        final policy = _policy();
        final image = await _image(Colors.blue);
        var taps = 0;
        final focus = FocusNode();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MaterialScope(
                policy: policy,
                tokens: MaterialTokens.forWidth(280),
                wallpaper: image,
                viewportKey: GlobalKey(),
                child: MaterialIconAction(
                  role: role,
                  tooltip: '动作',
                  focusNode: focus,
                  buttonKey: const Key('role'),
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => taps++,
                ),
              ),
            ),
          ),
        );
        final target = find.byKey(const Key('role'));
        final bounds = tester.getRect(target);
        expect(bounds.size, const Size(48, 48));
        expect(
          tester.getRect(find.byIcon(Icons.refresh)).center,
          bounds.center,
        );
        final button = tester.widget<FilledButton>(target);
        if (role == MaterialActionRole.auxiliary) {
          expect(
            button.style!.backgroundColor!.resolve({}),
            Colors.transparent,
          );
          expect(button.style!.side!.resolve({})!.color, Colors.transparent);
          expect(find.byType(MaterialSheen), findsNothing);
          expect(find.byType(RefractiveBackdrop), findsNothing);
        } else {
          expect(tester.getRect(find.byType(MaterialSheen)), bounds);
          expect(
            button.style!.backgroundColor!.resolve({}),
            isNot(policy.colorScheme.primary),
          );
        }
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(taps, 1);
        expect(button.style!.side!.resolve({WidgetState.focused})!.width, 2);
        expect(find.byType(BackdropFilter), findsNothing);
        await tester.pumpWidget(const SizedBox());
        focus.dispose();
        image.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('touch cancel and rebind release the old per-card signal', (
    tester,
  ) async {
    final image = await _image(Colors.blue);
    final first = MaterialSamplingHandle(
      _snapshot(1, image: image, interactive: true),
    );
    final second = MaterialSamplingHandle(_snapshot(1, image: image));
    MaterialSamplingInput? input;
    final child = MaterialSheen(
      child: Builder(
        builder: (context) {
          input = MaterialSamplingInput.maybeOf(context);
          return const SizedBox(
            width: 80,
            height: 52,
            child: ColoredBox(color: Colors.transparent),
          );
        },
      ),
    );
    await tester.pumpWidget(_app(first, child));
    final touch = await tester.startGesture(
      tester.getCenter(find.byType(MaterialSheen)),
    );
    expect(input!.pointer!.value.active, isTrue);
    await touch.moveBy(const Offset(2, 1));
    expect(input!.pointer!.value.position, const Offset(42, 27));
    await touch.cancel();
    expect(input!.pointer!.value.active, isFalse);
    final samePointer = input!.pointer;
    await tester.pumpWidget(_app(second, child));
    expect(input!.handle, same(second));
    expect(input!.pointer, same(samePointer));
    first.close(); // must not be subscribed after replacing the handle
    await tester.pump();
    expect(input!.pointer!.value.active, isFalse);
    second.publish(_snapshot(2, image: image, interactive: true));
    await tester.pump();
    final next = await tester.startGesture(
      tester.getCenter(find.byType(MaterialSheen)),
    );
    expect(input!.pointer!.value.active, isTrue);
    second.invalidate(generation: 3);
    expect(input!.pointer!.value.active, isFalse);
    await next.up();
    await tester.pumpWidget(const SizedBox());
    second.close();
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled motion and opaque policy never activate the pointer', (
    tester,
  ) async {
    final image = await _image(Colors.blue);
    final handle = MaterialSamplingHandle(
      _snapshot(1, image: image, interactive: true),
    );
    MaterialSamplingInput? input;
    final child = MaterialSheen(
      child: Builder(
        builder: (context) {
          input = MaterialSamplingInput.maybeOf(context);
          return const SizedBox(
            width: 80,
            height: 52,
            child: ColoredBox(color: Colors.transparent),
          );
        },
      ),
    );
    await tester.pumpWidget(
      _app(
        handle,
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: child,
        ),
      ),
    );
    var touch = await tester.startGesture(
      tester.getCenter(find.byType(MaterialSheen)),
    );
    expect(input!.pointer!.value.active, isFalse);
    await touch.cancel();
    handle.publish(
      _snapshot(
        2,
        image: image,
        interactive: true,
        policy: _policy(solid: true),
      ),
    );
    await tester.pumpWidget(_app(handle, child));
    touch = await tester.startGesture(
      tester.getCenter(find.byType(MaterialSheen)),
    );
    expect(input!.pointer!.value.active, isFalse);
    await touch.up();
    await tester.pumpWidget(const SizedBox());
    handle.close();
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auxiliary help Escape restores focus, opens only requested material panel',
    (tester) async {
      await tester.pumpWidget(_app(null, const ContextHelp(message: '受控帮助')));
      expect(find.byType(MaterialSheen), findsNothing);
      expect(find.byType(RefractiveBackdrop), findsNothing);
      final icon = find.byType(IconButton);
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(find.text('受控帮助'), findsOneWidget);
      expect(find.byType(MaterialCard), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('受控帮助'), findsNothing);
      expect(tester.widget<IconButton>(icon).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
