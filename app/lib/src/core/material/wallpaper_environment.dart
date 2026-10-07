import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'material_policy.dart';
import 'material_surfaces.dart';
import 'material_tokens.dart';
import 'material_appearance.dart';
import 'material_sampling.dart';

/// Root environment for a bounded application viewport.
///
/// The host maps its existing local image selection to FileImage, or supplies
/// another ImageProvider for tests. This widget performs no persistence, file
/// selection, network lookup, carousel scheduling or platform preference I/O.
/// Its provider listener and received ImageInfo handles are owned here;
/// Flutter's shared image cache is not owned here and is not cleared.
class WallpaperEnvironment extends StatefulWidget {
  const WallpaperEnvironment({
    super.key,
    required this.child,
    this.wallpaper,
    this.backgroundColor,
    this.backgroundOpacity = 0.5,
    this.signals = const MaterialSignals(),
    this.breakpoints = const MaterialBreakpoints(),
    this.availableWidth,
    this.appearance = const MaterialAppearance(),
  });

  final Widget child;
  final ImageProvider<Object>? wallpaper;
  final Color? backgroundColor;
  final double backgroundOpacity;
  final MaterialSignals signals;
  final MaterialBreakpoints breakpoints;

  /// Optional logical width for deterministic policy/layout tests. It chooses
  /// tokens only; the host still controls the actual viewport constraints.
  final double? availableWidth;
  final MaterialAppearance appearance;

  @override
  State<WallpaperEnvironment> createState() => _WallpaperEnvironmentState();
}

class _WallpaperEnvironmentState extends State<WallpaperEnvironment> {
  final _viewportKey = GlobalKey();
  ImageConfiguration? _configuration;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _image;
  WallpaperLoadState _loadState = WallpaperLoadState.absent;
  int _generation = 0;
  int _resourceGeneration = 0;
  MaterialSamplingHandle? _handle;
  MaterialPolicy? _publishedPolicy;
  MaterialTokens? _publishedTokens;
  final Set<ScrollPosition> _ancestorPositions = {};
  ColorScheme? _dependencyScheme;
  bool? _dependencyMotion;
  bool? _dependencyContrast;

  void _trackAncestors() {
    final next = <ScrollPosition>{};
    final inheritedBetweenScrollables = <InheritedElement>[];
    context.visitAncestorElements((element) {
      if (element is InheritedElement) {
        inheritedBetweenScrollables.add(element);
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        for (final inherited in inheritedBetweenScrollables) {
          context.dependOnInheritedElement(inherited);
        }
        inheritedBetweenScrollables.clear();
        next.add((element.state as ScrollableState).position);
      }
      return true;
    });
    for (final old in _ancestorPositions.difference(next)) {
      old.removeListener(_ancestorMoved);
    }
    for (final added in next.difference(_ancestorPositions)) {
      added.addListener(_ancestorMoved);
    }
    _ancestorPositions
      ..clear()
      ..addAll(next);
  }

  void _ancestorMoved() => _handle?.invalidatePaint();

  void _invalidate() {
    _handle?.invalidate(generation: ++_resourceGeneration);
  }

  void _publish(MaterialPolicy policy, MaterialTokens tokens) {
    final old = _publishedPolicy;
    final unchanged =
        old != null &&
        old.colorScheme == policy.colorScheme &&
        old.wallpaper == policy.wallpaper &&
        old.backgroundColor == policy.backgroundColor &&
        old.backgroundOpacity == policy.backgroundOpacity &&
        old.signals.highContrast == policy.signals.highContrast &&
        old.signals.reduceTransparency == policy.signals.reduceTransparency &&
        mapEquals(
          old.appearance.toPreferences(),
          policy.appearance.toPreferences(),
        );
    if (unchanged) policy = old;
    if (_publishedTokens?.widthClass == tokens.widthClass) {
      tokens = _publishedTokens!;
    }
    _publishedPolicy = policy;
    _publishedTokens = tokens;
    final active = policy.allowsCardSampling && _image != null;
    final interaction =
        active &&
        widget.appearance.interactiveRefraction &&
        MediaQuery.maybeOf(context)?.disableAnimations != true;
    final previous = _handle?.current;
    if (previous != null &&
        identical(previous.policy, policy) &&
        identical(previous.tokens, tokens) &&
        identical(previous.image, active ? _image?.image : null) &&
        previous.active == active &&
        previous.interactionEnabled == interaction) {
      return;
    }
    final snapshot = MaterialSamplingSnapshot(
      generation: ++_resourceGeneration,
      policy: policy,
      tokens: tokens,
      viewportKey: _viewportKey,
      active: active,
      image: active ? _image?.image : null,
      interactionEnabled: interaction,
    );
    if (_handle == null) {
      _handle = MaterialSamplingHandle(snapshot);
    } else {
      _handle!.publish(snapshot);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Position-scope dependency changes only rebind paint listeners. Resource
    // invalidation is reserved for real theme/accessibility/config changes.
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.maybeOf(context);
    if (_dependencyScheme != null &&
        (_dependencyScheme != scheme ||
            _dependencyMotion != media?.disableAnimations ||
            _dependencyContrast != media?.highContrast)) {
      _invalidate();
    }
    _dependencyScheme = scheme;
    _dependencyMotion = media?.disableAnimations;
    _dependencyContrast = media?.highContrast;
    _trackAncestors();
    final next = createLocalImageConfiguration(context);
    if (!_sameConfiguration(_configuration, next)) {
      _configuration = next;
      _subscribe(next);
    }
  }

  @override
  void didUpdateWidget(WallpaperEnvironment oldWidget) {
    super.didUpdateWidget(oldWidget);
    _trackAncestors();
    _handle?.invalidatePaint();
    if (oldWidget.wallpaper != widget.wallpaper) {
      _subscribe(_configuration ?? createLocalImageConfiguration(context));
    } else if (oldWidget.signals.highContrast != widget.signals.highContrast ||
        oldWidget.signals.reduceTransparency !=
            widget.signals.reduceTransparency ||
        oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.backgroundOpacity != widget.backgroundOpacity ||
        !mapEquals(
          oldWidget.appearance.toPreferences(),
          widget.appearance.toPreferences(),
        )) {
      _invalidate();
    }
  }

  static bool _sameConfiguration(
    ImageConfiguration? previous,
    ImageConfiguration next,
  ) =>
      previous != null &&
      previous.bundle == next.bundle &&
      previous.devicePixelRatio == next.devicePixelRatio &&
      previous.locale == next.locale &&
      previous.textDirection == next.textDirection &&
      previous.size == next.size &&
      previous.platform == next.platform;

  // Called only from lifecycle methods which already schedule a build.
  void _subscribe(ImageConfiguration configuration) {
    final generation = ++_generation;
    _invalidate();
    _detach();
    final previous = _image;
    _image = null;
    final provider = widget.wallpaper;
    _loadState = provider == null
        ? WallpaperLoadState.absent
        : WallpaperLoadState.loading;
    _releaseAfterFrame(previous);
    if (provider == null) return;

    try {
      final stream = provider.resolve(configuration);
      final listener = ImageStreamListener(
        (image, synchronousCall) => _receive(generation, image),
        onError: (Object error, StackTrace? stack) => _fail(generation),
      );
      // Store both before adding: a cached first frame can arrive synchronously.
      _stream = stream;
      _listener = listener;
      stream.addListener(listener);
    } catch (_) {
      if (mounted && generation == _generation) {
        ++_generation;
        _invalidate();
        _detach();
        final failedImage = _image;
        _image = null;
        _loadState = WallpaperLoadState.failed;
        _releaseAfterFrame(failedImage);
      }
    }
  }

  void _receive(int generation, ImageInfo image) {
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    final previous = _image;
    _invalidate();
    setState(() {
      _image = image;
      _loadState = WallpaperLoadState.ready;
    });
    _releaseAfterFrame(previous);
  }

  void _fail(int generation) {
    if (!mounted || generation != _generation) return;
    ++_generation;
    _invalidate();
    _detach();
    final previous = _image;
    setState(() {
      _image = null;
      _loadState = WallpaperLoadState.failed;
    });
    _releaseAfterFrame(previous);
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    _stream = null;
    _listener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  static void _releaseAfterFrame(ImageInfo? image) {
    if (image == null) return;
    final binding = WidgetsBinding.instance;
    // Let the RawImage render object receive its replacement before releasing
    // the previously displayed handle. This callback never touches State.
    binding.addPostFrameCallback((_) => image.dispose());
    binding.ensureVisualUpdate();
  }

  @override
  void dispose() {
    ++_generation;
    _handle?.close();
    for (final position in _ancestorPositions) {
      position.removeListener(_ancestorMoved);
    }
    _ancestorPositions.clear();
    _detach();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.maybeOf(context);
    final signals = widget.signals.includingFrameworkHighContrast(
      media?.highContrast == true,
    );
    final policy = MaterialPolicy.resolve(
      colorScheme: theme.colorScheme,
      wallpaper: _loadState,
      signals: signals,
      backgroundColor: widget.backgroundColor,
      backgroundOpacity: widget.backgroundOpacity,
      appearance: widget.appearance,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            widget.availableWidth ??
            (constraints.hasBoundedWidth
                ? constraints.maxWidth
                : media?.size.width ?? 0);
        final tokens = MaterialTokens.forWidth(
          width,
          breakpoints: widget.breakpoints,
        );
        _publish(policy, tokens);
        // Keep this tree and the child's position unchanged across every
        // load state, signal change and width class. Never key by wallpaper.
        return MaterialScope(
          policy: policy,
          tokens: tokens,
          wallpaper: policy.allowsAmbient ? _image?.image : null,
          viewportKey: _viewportKey,
          samplingHandle: _handle,
          child: Theme(
            data: policy.applyTo(theme),
            child: _ViewportGeometry(
              handle: _handle!,
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  _handle?.invalidatePaint();
                  return false;
                },
                child: Stack(
                  key: _viewportKey,
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: policy.opaqueSurface),
                              RawImage(
                                image: policy.allowsAmbient
                                    ? _image?.image
                                    : null,
                                scale: _image?.scale ?? 1,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      policy.colorScheme.primary.withValues(
                                        alpha: policy.allowsAmbient
                                            ? 0.13
                                            : 0.04,
                                      ),
                                      policy.colorScheme.tertiary.withValues(
                                        alpha: policy.allowsAmbient
                                            ? 0.09
                                            : 0.03,
                                      ),
                                      policy.colorScheme.surface.withValues(
                                        alpha: 0.02,
                                      ),
                                    ],
                                    stops: const [0, 0.58, 1],
                                  ),
                                ),
                              ),
                              ColoredBox(
                                color:
                                    widget.backgroundColor ??
                                    Colors.transparent,
                              ),
                              ColoredBox(color: policy.environmentOverlay),
                            ],
                          ),
                        ),
                      ),
                    ),
                    GlassWorkSurface(edgeToEdge: true, child: widget.child),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Geometry notifications are value-driven and coalesced, never a ticker.
class _ViewportGeometry extends SingleChildRenderObjectWidget {
  const _ViewportGeometry({required this.handle, required super.child});
  final MaterialSamplingHandle handle;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ViewportGeometryRender(handle);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ViewportGeometryRender renderObject,
  ) {
    renderObject.handle = handle;
  }
}

class _ViewportGeometryRender extends RenderProxyBox {
  _ViewportGeometryRender(this.handle);
  MaterialSamplingHandle handle;
  List<double>? _last;
  bool _queued = false;
  @override
  void paint(PaintingContext context, Offset offset) {
    final values = <double>[
      size.width,
      size.height,
      ...getTransformTo(null).storage,
    ];
    if (!listEquals(_last, values)) {
      _last = values;
      if (!_queued) {
        _queued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _queued = false;
          if (attached && !handle.closed) handle.invalidatePaint();
        });
      }
    }
    super.paint(context, offset);
  }
}
