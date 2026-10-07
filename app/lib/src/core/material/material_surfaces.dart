import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'material_policy.dart';
import 'material_tokens.dart';
import 'material_sampling.dart';
import 'refractive_backdrop.dart';

class MaterialScope extends InheritedWidget {
  const MaterialScope({
    super.key,
    required MaterialPolicy policy,
    required MaterialTokens tokens,
    ui.Image? wallpaper,
    GlobalKey? viewportKey,
    this.samplingHandle,
    required super.child,
  }) : _policy = policy,
       _tokens = tokens,
       _wallpaper = samplingHandle == null ? wallpaper : null,
       _viewportKey = samplingHandle == null ? viewportKey : null;

  final MaterialPolicy _policy;
  final MaterialTokens _tokens;
  final ui.Image? _wallpaper;
  final GlobalKey? _viewportKey;
  final MaterialSamplingHandle? samplingHandle;
  MaterialPolicy get policy => samplingHandle?.current.policy ?? _policy;
  MaterialTokens get tokens => samplingHandle?.current.tokens ?? _tokens;
  ui.Image? get wallpaper =>
      samplingHandle == null ? _wallpaper : samplingHandle!.current.image;
  GlobalKey? get viewportKey => samplingHandle == null
      ? _viewportKey
      : samplingHandle!.current.viewportKey;

  static MaterialScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MaterialScope>();
    if (scope == null) {
      throw FlutterError(
        'Material surfaces require WallpaperEnvironment '
        'or an explicitly injected MaterialScope ancestor.',
      );
    }
    return scope;
  }

  static MaterialScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MaterialScope>();

  @override
  bool updateShouldNotify(MaterialScope oldWidget) =>
      _policy != oldWidget._policy ||
      _tokens != oldWidget._tokens ||
      _wallpaper != oldWidget._wallpaper ||
      _viewportKey != oldWidget._viewportKey ||
      samplingHandle != oldWidget.samplingHandle;
}

/// Presence means that descendants must not add another active backdrop blur.
/// Stable content also establishes this boundary, even outside a work surface.
class _SurfaceBoundary extends InheritedWidget {
  const _SurfaceBoundary({required super.child});

  static bool exists(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SurfaceBoundary>() != null;

  @override
  bool updateShouldNotify(_SurfaceBoundary oldWidget) => false;
}

/// WallpaperEnvironment installs the single outer work surface. A nested use
/// remains in the same widget structure but becomes a stable, unblurred surface.
class GlassWorkSurface extends StatelessWidget {
  const GlassWorkSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.edgeToEdge = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool edgeToEdge;

  @override
  Widget build(BuildContext context) {
    final policy = MaterialScope.of(context).policy;
    final nested = _SurfaceBoundary.exists(context);
    final blur = policy.allowsBlur && !nested;
    final radius = edgeToEdge
        ? BorderRadius.zero
        : BorderRadius.circular(MaterialTokens.workRadius);
    final fill = nested ? policy.contentSurface : policy.workSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: blur && !edgeToEdge
            ? MaterialTokens.workShadow(
                dark: policy.colorScheme.brightness == Brightness.dark,
              )
            : const <BoxShadow>[],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: blur,
          filter: ui.ImageFilter.blur(
            sigmaX: policy.appearance.blur,
            sigmaY: policy.appearance.blur,
          ),
          child: Material(
            color: fill,
            elevation: 0,
            animationDuration: Duration.zero,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: edgeToEdge
                  ? BorderSide.none
                  : BorderSide(
                      color: blur ? policy.glassHighlight : policy.boundary,
                      width: policy.highContrast
                          ? MaterialTokens.focusWidth
                          : MaterialTokens.borderWidth,
                    ),
            ),
            child: Stack(
              children: [
                if (blur)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              policy.glassHighlight.withValues(alpha: .1),
                              policy.glassHighlight.withValues(alpha: .02),
                              Colors.transparent,
                            ],
                            stops: const [0, .35, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                _SurfaceBoundary(
                  child: Padding(padding: padding, child: child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// For Feed text, charts, tables, diary and settings. Never adds a blur or a
/// scrollable. Parent constraints and the caller's content state are retained.
class StableContentSurface extends StatelessWidget {
  const StableContentSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final policy = MaterialScope.of(context).policy;
    return Material(
      color: policy.contentSurface,
      elevation: 0,
      animationDuration: Duration.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
        side: BorderSide(
          color: policy.boundary,
          width: policy.highContrast
              ? MaterialTokens.focusWidth
              : MaterialTokens.borderWidth,
        ),
      ),
      child: _SurfaceBoundary(
        child: MaterialSheen(
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Cards independently sample the selected wallpaper where available, without
/// capturing the UI or adding backdrop filters. Text never enters the shader.
/// Light and image decoration are pointer-transparent and retain content state.
class MaterialSheen extends StatefulWidget {
  const MaterialSheen({required this.child, super.key});
  final Widget child;
  @override
  State<MaterialSheen> createState() => _MaterialSheenState();
}

class _MaterialSheenState extends State<MaterialSheen> {
  final _pointer = ValueNotifier(const MaterialPointerSample());
  MaterialSamplingHandle? _handle;
  bool _queued = false;
  bool _interactive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MaterialScope.maybeOf(context)?.samplingHandle;
    if (_handle != next) {
      _handle?.resourceChanges.removeListener(_resourcesChanged);
      _pointer.value = const MaterialPointerSample();
      _handle = next;
      _handle?.resourceChanges.addListener(_resourcesChanged);
    }
  }

  void _resourcesChanged() {
    if (!mounted) return;
    if (_handle?.current.allowsInteraction != true) {
      _pointer.value = const MaterialPointerSample();
    }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle ||
        SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else if (!_queued) {
      _queued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _queued = false;
        if (mounted) setState(() {});
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _move(Offset point) {
    if (_interactive &&
        _handle?.current.allowsInteraction == true &&
        point.dx.isFinite &&
        point.dy.isFinite) {
      _pointer.value = MaterialPointerSample(position: point, active: true);
    }
  }

  void _clear() => _pointer.value = const MaterialPointerSample();

  @override
  void dispose() {
    _handle?.resourceChanges.removeListener(_resourcesChanged);
    _pointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = MaterialScope.maybeOf(context);
    final policy = scope?.policy;
    final enabled = policy != null && policy.allowsCardGlass;
    final strength = enabled ? policy.appearance.light : 0.0;
    _interactive =
        _handle?.current.allowsInteraction == true &&
        MediaQuery.maybeOf(context)?.disableAnimations != true;
    if (!_interactive && _pointer.value.active) _clear();
    return MouseRegion(
      onHover: (event) => _move(event.localPosition),
      onExit: (_) => _clear(),
      child: Listener(
        onPointerDown: (event) => _move(event.localPosition),
        onPointerMove: (event) => _move(event.localPosition),
        onPointerUp: (_) => _clear(),
        onPointerCancel: (_) => _clear(),
        child: MaterialSamplingInput(
          handle: _handle,
          pointer: _pointer,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child:
                      policy != null &&
                          policy.allowsCardSampling &&
                          scope?.wallpaper != null &&
                          scope?.viewportKey != null
                      ? RefractiveBackdrop(
                          image: scope!.wallpaper!,
                          viewportKey: scope.viewportKey!,
                          policy: policy,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          (policy?.glassHighlight ?? Colors.transparent)
                              .withValues(alpha: strength * .42),
                          Colors.transparent,
                          (policy?.colorScheme.primary ?? Colors.transparent)
                              .withValues(alpha: strength * .035),
                        ],
                        stops: const [0, .48, 1],
                      ),
                    ),
                  ),
                ),
              ),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

class MaterialCard extends StatelessWidget {
  const MaterialCard({
    required this.child,
    this.margin,
    this.elevation,
    this.color,
    this.shape,
    this.clipBehavior = Clip.antiAlias,
    super.key,
  });
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final double? elevation;
  final Color? color;
  final ShapeBorder? shape;
  final Clip clipBehavior;
  @override
  Widget build(BuildContext context) {
    final policy = MaterialScope.maybeOf(context)?.policy;
    final fill = policy == null
        ? color
        : !policy.allowsCardGlass
        ? policy.contentSurface
        : color == null
        ? policy.contentSurface
        : Color.lerp(
            policy.tintedSurface,
            color,
            .25,
          )!.withValues(alpha: policy.appearance.contentOpacity);
    return Card(
      margin: margin,
      elevation: elevation,
      shape: shape,
      color: fill,
      clipBehavior: clipBehavior,
      child: MaterialSheen(child: child),
    );
  }
}

/// Tooltip supplies the accessible label; the decorative icon is excluded.
/// Keep this button outside pointer-absorbing decorative environment layers.
class MaterialIconButton extends StatelessWidget {
  const MaterialIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
  }) : assert(tooltip != '');

  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final policy = MaterialScope.of(context).policy;
    return IconButton(
      tooltip: tooltip,
      icon: ExcludeSemantics(child: icon),
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      visualDensity: VisualDensity.standard,
      constraints: const BoxConstraints(
        minWidth: MaterialTokens.minimumTarget,
        minHeight: MaterialTokens.minimumTarget,
      ),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(
          Size(MaterialTokens.minimumTarget, MaterialTokens.minimumTarget),
        ),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
          ),
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.focused)
                ? policy.focusColor
                : Colors.transparent,
            width: MaterialTokens.focusWidth,
          ),
        ),
      ),
    );
  }
}
