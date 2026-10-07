import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'material_surfaces.dart';
import 'material_sampling.dart';
import 'material_tokens.dart';

/// Roles change ink/rim, never replace the card material with a solid accent.
enum MaterialActionRole { primary, secondary, destructive, auxiliary }

const materialControlTarget = 48.0;

/// MenuAnchor must not paint an opaque second surface behind its panel.
const materialMenuStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
  shadowColor: WidgetStatePropertyAll(Colors.transparent),
  elevation: WidgetStatePropertyAll(0),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
);

ButtonStyle materialActionStyle(
  BuildContext context, {
  MaterialActionRole role = MaterialActionRole.secondary,
  bool paintFocus = true,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
    horizontal: MaterialTokens.spaceMd,
    vertical: MaterialTokens.spaceSm,
  ),
}) {
  final theme = Theme.of(context);
  final policy = MaterialScope.maybeOf(context)?.policy;
  final scheme = policy?.colorScheme ?? theme.colorScheme;
  final ink = policy?.highContrast == true
      ? scheme.onSurface
      : switch (role) {
          MaterialActionRole.primary => scheme.primary,
          MaterialActionRole.secondary => scheme.onSurface,
          MaterialActionRole.auxiliary => scheme.onSurfaceVariant,
          MaterialActionRole.destructive => scheme.error,
        };
  // A missing scope is opaque rather than assuming OS transparency permission.
  final surface = policy?.contentSurface ?? scheme.surface.withValues(alpha: 1);
  // Whole-plane tonal backing, still blended over the selected glass surface.
  // State affects ink/rim only; the button's size and backdrop stay stable.
  final backing = Color.alphaBlend(
    scheme.onSurface.withValues(alpha:
      role == MaterialActionRole.primary ? .12 : .065), surface);
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: WidgetStatePropertyAll(padding),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    alignment: Alignment.center,
    elevation: const WidgetStatePropertyAll(0),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    backgroundColor: WidgetStatePropertyAll(
      role == MaterialActionRole.auxiliary ? Colors.transparent : backing,
    ),
    // ButtonStyleButton invokes this around its padded/aligned content, under
    // the native minimum constraints. Sample the whole plane, not the glyph.
    backgroundBuilder: role == MaterialActionRole.auxiliary
        ? null
        : (context, states, child) => ClipRRect(
            borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
            // Keep the native padded Align under its effective constraints. The
            // sheen's internal loose Stack is decoration, not content layout.
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: const MaterialSheen(child: SizedBox.expand()),
                  ),
                ),
                child ?? const SizedBox.shrink(),
              ],
            ),
          ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? scheme.onSurface.withValues(alpha: .38)
          : ink,
    ),
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      return ink.withValues(
        alpha: states.contains(WidgetState.pressed)
            ? .12
            : paintFocus && states.contains(WidgetState.focused)
            ? .10
            : states.contains(WidgetState.hovered)
            ? .07
            : 0,
      );
    }),
    side: WidgetStateProperty.resolveWith((states) {
      final disabled = states.contains(WidgetState.disabled);
      final focused = paintFocus && !disabled && states.contains(WidgetState.focused);
      final highContrast = policy?.highContrast == true;
      final boundary = policy?.boundary ?? scheme.outlineVariant;
      final Color rim;
      if (focused) {
        rim = policy?.focusColor ?? ink;
      } else if (role == MaterialActionRole.auxiliary) {
        rim = Colors.transparent;
      } else if (highContrast) {
        rim = boundary;
      } else {
        // A complete themed edge distinguishes actions from auxiliary glyphs.
        // State changes adjust its tone, never the surface, radius or layout.
        final secondary = role == MaterialActionRole.secondary;
        final strength = disabled
            ? .10
            : states.contains(WidgetState.pressed)
            ? (secondary ? .56 : .92)
            : states.contains(WidgetState.hovered)
            ? (secondary ? .48 : .84)
            : (secondary ? .40 : .78);
        rim = Color.alphaBlend(
          (disabled ? scheme.onSurface : ink).withValues(alpha: strength),
          boundary,
        );
      }
      return BorderSide(
        color: rim,
        width: focused || highContrast
            ? MaterialTokens.focusWidth
            : MaterialTokens.borderWidth,
      );
    }),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
      ),
    ),
    textStyle: WidgetStatePropertyAll(
      theme.textTheme.labelLarge?.copyWith(
        fontWeight: role == MaterialActionRole.primary
            ? FontWeight.w600
            : FontWeight.w500,
      ),
    ),
  );
}

/// Native button semantics/keyboard remain intact; sheen adds no blur or IO.
class MaterialActionButton extends StatelessWidget {
  const MaterialActionButton({
    required this.child,
    required this.onPressed,
    this.role = MaterialActionRole.secondary,
    this.buttonKey,
    this.focusNode,
    this.autofocus = false,
    this.padding,
    this.paintFocus = true,
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final MaterialActionRole role;
  final Key? buttonKey;
  final FocusNode? focusNode;
  final bool autofocus;
  final EdgeInsetsGeometry? padding;
  final bool paintFocus;

  @override
  Widget build(BuildContext context) => FilledButton(
    key: buttonKey,
    onPressed: onPressed,
    focusNode: focusNode,
    autofocus: autofocus,
    style: materialActionStyle(
      context,
      role: role,
      paintFocus: paintFocus,
      padding:
          padding ??
          const EdgeInsets.symmetric(
            horizontal: MaterialTokens.spaceMd,
            vertical: MaterialTokens.spaceSm,
          ),
    ),
    clipBehavior: Clip.antiAlias,
    child: DefaultTextStyle.merge(
      textAlign: TextAlign.center,
      child: child,
    ),
  );
}

class MaterialIconAction extends StatelessWidget {
  const MaterialIconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.role = MaterialActionRole.secondary,
    this.buttonKey,
    this.focusNode,
    this.autofocus = false,
    super.key,
  }) : assert(tooltip != '');
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final MaterialActionRole role;
  final Key? buttonKey;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    excludeFromSemantics: true,
    child: SizedBox(
      width: materialControlTarget,
      height: materialControlTarget,
      child: MaterialActionButton(
        buttonKey: buttonKey,
        role: role,
        focusNode: focusNode,
        autofocus: autofocus,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: Semantics(
          label: tooltip,
          child: ExcludeSemantics(child: icon),
        ),
      ),
    ),
  );
}

/// A snapshot of overlay dependencies, with no ownership of their lifetime.
/// Capture before opening an overlay; do not construct a second container.
class MaterialOverlayCapture {
  MaterialOverlayCapture._(this.scope, this.container, this.themes);
  factory MaterialOverlayCapture.of(BuildContext context) {
    ProviderContainer? container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } on StateError {
      // Independent help/material callers need not have a ProviderScope.
    }
    final scope = MaterialScope.maybeOf(context);
    // Live captures retain a handle, not an image snapshot. Legacy scopes stay
    // source compatible and borrow resources for the injector's lifetime.
    final captured = scope?.samplingHandle == null
        ? scope
        : MaterialScope(
            policy: scope!.policy,
            tokens: scope.tokens,
            samplingHandle: scope.samplingHandle,
            child: const SizedBox.shrink(),
          );
    return MaterialOverlayCapture._(
      captured,
      container,
      InheritedTheme.capture(from: context, to: null),
    );
  }
  final MaterialScope? scope;
  final ProviderContainer? container;
  final CapturedThemes themes;

  Widget wrap(Widget child) {
    final capturedScope = scope;
    if (capturedScope != null) {
      child = _CapturedMaterialScope(scope: capturedScope, child: child);
    }
    final capturedContainer = container;
    if (capturedContainer != null) {
      child = UncontrolledProviderScope(
        container: capturedContainer,
        child: child,
      );
    }
    return themes.wrap(child);
  }
}

/// Rebuild only the inherited material wrapper, not the captured business child.
class _CapturedMaterialScope extends StatefulWidget {
  const _CapturedMaterialScope({required this.scope, required this.child});
  final MaterialScope scope;
  final Widget child;
  @override
  State<_CapturedMaterialScope> createState() => _CapturedMaterialScopeState();
}

class _CapturedMaterialScopeState extends State<_CapturedMaterialScope> {
  MaterialSamplingHandle? get _handle => widget.scope.samplingHandle;
  bool _queued = false;
  @override
  void initState() {
    super.initState();
    _handle?.resourceChanges.addListener(_changed);
  }

  @override
  void didUpdateWidget(_CapturedMaterialScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope.samplingHandle != _handle) {
      oldWidget.scope.samplingHandle?.resourceChanges.removeListener(_changed);
      _handle?.resourceChanges.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted || _queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _handle?.resourceChanges.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialScope(
    policy: widget.scope.policy,
    tokens: widget.scope.tokens,
    wallpaper: widget.scope.wallpaper,
    viewportKey: widget.scope.viewportKey,
    samplingHandle: _handle,
    child: widget.child,
  );
}

/// Exactly one card surface. The caller supplies Dialog/MenuAnchor's shell.
/// Scrollable=false supports a caller-owned bounded list and fixed actions.
class MaterialTransientPanel extends StatelessWidget {
  const MaterialTransientPanel({
    required this.child,
    this.capture,
    this.maxWidth = 480,
    this.maxHeightFraction = .8,
    this.padding = const EdgeInsets.all(MaterialTokens.spaceLg),
    this.scrollable = true,
    super.key,
  }) : assert(maxWidth > 0),
       assert(maxHeightFraction > 0 && maxHeightFraction <= 1);
  final Widget child;
  final MaterialOverlayCapture? capture;
  final double maxWidth, maxHeightFraction;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final content = scrollable
        ? SingleChildScrollView(primary: false, padding: padding, child: child)
        : Padding(padding: padding, child: child);
    Widget panel = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.min(maxWidth, math.max(0, viewport.width - 32)),
        maxHeight: viewport.height * maxHeightFraction,
      ),
      child: MaterialCard(
        margin: EdgeInsets.zero,
        elevation: 0,
        child: content,
      ),
    );
    return capture?.wrap(panel) ?? panel;
  }
}
