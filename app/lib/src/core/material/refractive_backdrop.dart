import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'material_policy.dart';
import 'material_sampling.dart';

const cardRefractionAsset = 'shaders/card_refraction.frag';
Future<ui.FragmentProgram>? _program;
ui.FragmentProgram? _compiledProgram;

/// Shares a compiled program, never a mutable shader or image ownership.
class RefractiveBackdrop extends StatefulWidget {
  const RefractiveBackdrop({
    required this.image,
    required this.viewportKey,
    required this.policy,
    this.loadProgram,
    super.key,
  });
  final ui.Image image;
  final GlobalKey viewportKey;
  final MaterialPolicy policy;

  /// Synthetic resource-lifetime seam; production uses the shared asset program.
  @visibleForTesting
  final Future<ui.FragmentProgram> Function()? loadProgram;
  @override
  State<RefractiveBackdrop> createState() => _RefractiveBackdropState();
}

class _RefractiveBackdropState extends State<RefractiveBackdrop> {
  ui.FragmentProgram? _loaded;
  MaterialSamplingHandle? _requestedHandle;
  int? _requestedGeneration;
  @override
  void initState() {
    super.initState();
    _loaded = widget.loadProgram == null ? _compiledProgram : null;
    if (_loaded != null) return;
    (widget.loadProgram?.call() ??
            (_program ??= ui.FragmentProgram.fromAsset(cardRefractionAsset)))
        .then(
          (value) {
            if (widget.loadProgram == null) _compiledProgram = value;
            // The render object reads current resources, not this callback's image.
            if (!mounted) return;
            _loaded = value;
            final handle = _requestedHandle;
            if (handle == null ||
                (!handle.closed &&
                    handle.current.active &&
                    handle.current.generation == _requestedGeneration)) {
              setState(() {});
            }
          },
          onError: (Object error) {
            debugPrint('Card refraction unavailable: $error');
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final input = MaterialSamplingInput.maybeOf(context);
    _requestedHandle = input?.handle;
    _requestedGeneration = input?.handle?.current.generation;
    final positions = <ScrollPosition>{};
    final inheritedBetweenScrollables = <InheritedElement>[];
    context.visitAncestorElements((element) {
      if (element is InheritedElement) {
        inheritedBetweenScrollables.add(element);
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        // Public dependency registration, bounded by actual ancestor scroll
        // boundaries. A position replacement notifies its inherited scope even
        // when this exact widget/renderer remains stable. No private scope type,
        // frame polling, or business-child rebuild is needed.
        for (final inherited in inheritedBetweenScrollables) {
          context.dependOnInheritedElement(inherited);
        }
        inheritedBetweenScrollables.clear();
        positions.add((element.state as ScrollableState).position);
      }
      return true;
    });
    if (_loaded == null ||
        input?.handle?.closed == true ||
        (input?.handle != null && !input!.handle!.current.active)) {
      return const SizedBox.expand();
    }
    return _RefractionPaint(
      program: _loaded!,
      image: widget.image,
      viewportKey: widget.viewportKey,
      policy: widget.policy,
      scrolls: positions.toList(),
      handle: input?.handle,
      pointer: input?.pointer,
    );
  }
}

class _RefractionPaint extends LeafRenderObjectWidget {
  const _RefractionPaint({
    required this.program,
    required this.image,
    required this.viewportKey,
    required this.policy,
    required this.scrolls,
    this.handle,
    this.pointer,
  });
  final ui.FragmentProgram program;
  final ui.Image image;
  final GlobalKey viewportKey;
  final MaterialPolicy policy;
  final List<ScrollPosition> scrolls;
  final MaterialSamplingHandle? handle;
  final ValueListenable<MaterialPointerSample>? pointer;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRefraction(
    program,
    image,
    viewportKey,
    policy,
    scrolls,
    handle,
    pointer,
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRefraction object,
  ) => object.update(image, viewportKey, policy, scrolls, handle, pointer);
}

class _RenderRefraction extends RenderBox {
  _RenderRefraction(
    ui.FragmentProgram program,
    ui.Image legacyImage,
    this.viewportKey,
    this.policy,
    this.scrolls,
    this.handle,
    this.pointer,
  ) : image = handle == null ? legacyImage : null,
      shader = program.fragmentShader();
  final ui.FragmentShader shader;
  ui.Image?
  image; // Only retain raw resources for the legacy, handle-free mode.
  GlobalKey viewportKey;
  MaterialPolicy policy;
  List<ScrollPosition> scrolls;
  MaterialSamplingHandle? handle;
  ValueListenable<MaterialPointerSample>? pointer;

  void _bind(bool add) {
    void bind(Listenable? signal) {
      if (add) {
        signal?.addListener(markNeedsPaint);
      } else {
        signal?.removeListener(markNeedsPaint);
      }
    }

    for (final position in scrolls) {
      bind(position);
    }
    bind(handle?.paintInvalidation);
    bind(handle?.resourceChanges);
    bind(pointer);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _bind(true);
  }

  @override
  void detach() {
    _bind(false);
    super.detach();
  }

  void update(
    ui.Image next,
    GlobalKey key,
    MaterialPolicy value,
    List<ScrollPosition> nextScrolls,
    MaterialSamplingHandle? nextHandle,
    ValueListenable<MaterialPointerSample>? nextPointer,
  ) {
    if (attached) _bind(false);
    image = nextHandle == null ? next : null;
    viewportKey = key;
    policy = value;
    scrolls = nextScrolls;
    handle = nextHandle;
    pointer = nextPointer;
    if (attached) _bind(true);
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    final currentHandle = handle;
    final current = currentHandle?.current;
    // Synchronous invalidation wins even before the captured wrapper rebuilds.
    if (currentHandle != null &&
        (currentHandle.closed ||
            current == null ||
            !current.active ||
            !current.policy.allowsCardSampling ||
            current.image == null)) {
      return;
    }
    final sampledPolicy = current?.policy ?? policy;
    // Legacy constructors have the same accessibility/effects policy as the
    // live-handle path. Return before even reading borrowed image dimensions.
    if (!sampledPolicy.allowsCardSampling) return;
    final sampledImage = currentHandle == null ? image : current!.image;
    if (sampledImage == null) return;
    final key = current?.viewportKey ?? viewportKey;
    final root = key.currentContext?.findRenderObject();
    if (!attached ||
        root is! RenderBox ||
        !root.attached ||
        !root.hasSize ||
        root.size.isEmpty ||
        size.isEmpty) {
      return;
    }
    final transform = root.getTransformTo(null);
    if (transform.storage.any((v) => !v.isFinite) ||
        transform.determinant() == 0) {
      return;
    }
    // Captured overlays are siblings, not descendants of the wallpaper root.
    final origin = root.globalToLocal(localToGlobal(Offset.zero));
    if (!origin.dx.isFinite || !origin.dy.isFinite) return;
    final appearance = sampledPolicy.appearance;
    final tint = sampledPolicy.cardTintedSurface;
    final base = sampledPolicy.opaqueSurface;
    final sample = pointer?.value;
    final local = sample?.position;
    final interactive =
        current?.allowsInteraction == true &&
        sample?.active == true &&
        local != null &&
        local.dx.isFinite &&
        local.dy.isFinite;
    final values = <double>[
      size.width,
      size.height,
      origin.dx,
      origin.dy,
      root.size.width,
      root.size.height,
      sampledImage.width.toDouble(),
      sampledImage.height.toDouble(),
      16,
      appearance.refraction * 24,
      appearance.cardBlur,
      appearance.contentOpacity,
      sampledPolicy.backgroundOpacity,
      tint.r,
      tint.g,
      tint.b,
      base.r,
      base.g,
      base.b,
      appearance.light,
      interactive ? local.dx : 0,
      interactive ? local.dy : 0,
      interactive ? 1 : 0,
    ];
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    shader.setImageSampler(0, sampledImage);
    context.canvas.save();
    context.canvas.translate(offset.dx, offset.dy);
    context.canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    context.canvas.restore();
  }

  @override
  void dispose() {
    shader.dispose();
    super.dispose();
  }
}
