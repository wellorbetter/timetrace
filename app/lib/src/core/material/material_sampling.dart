import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'material_policy.dart';
import 'material_tokens.dart';

/// Borrowed resources. Only the environment releases its ImageInfo/image.
/// Inactive snapshots never expose an image, even if a caller supplied one.
@immutable
class MaterialSamplingSnapshot {
  const MaterialSamplingSnapshot({
    required this.generation,
    required this.policy,
    required this.tokens,
    this.image,
    this.viewportKey,
    this.active = false,
    this.interactionEnabled = false,
  });

  final int generation;
  final MaterialPolicy policy;
  final MaterialTokens tokens;
  final ui.Image? image;
  final GlobalKey? viewportKey;
  final bool active;
  final bool interactionEnabled;

  bool get allowsInteraction =>
      active && interactionEnabled && policy.allowsRefraction && image != null;

  MaterialSamplingSnapshot withoutImage({required int generation}) =>
      MaterialSamplingSnapshot(
        generation: generation,
        policy: policy,
        tokens: tokens,
        viewportKey: viewportKey,
      );
}

/// Non-owning, closeable current-resource handle. No providers, files or timers.
/// Environment must publish invalidation BEFORE releasing the borrowed image.
class MaterialSamplingHandle {
  MaterialSamplingHandle(MaterialSamplingSnapshot initial)
    : _current = _safe(initial);

  MaterialSamplingSnapshot _current;
  bool _closed = false;
  final _resources = _ClosableSignal();
  final _paint = _ClosableSignal();

  MaterialSamplingSnapshot get current => _current;
  bool get closed => _closed;
  Listenable get resourceChanges => _resources;
  Listenable get paintInvalidation => _paint;

  static MaterialSamplingSnapshot _safe(MaterialSamplingSnapshot snapshot) =>
      snapshot.active
      ? snapshot
      : snapshot.withoutImage(generation: snapshot.generation);

  /// Old/late generations cannot revive replaced resources.
  void publish(MaterialSamplingSnapshot snapshot) {
    if (_closed || snapshot.generation < _current.generation) return;
    final next = _safe(snapshot);
    final old = _current;
    if (next.generation == old.generation &&
        identical(next.image, old.image) &&
        identical(next.policy, old.policy) &&
        identical(next.tokens, old.tokens) &&
        identical(next.viewportKey, old.viewportKey) &&
        next.active == old.active &&
        next.interactionEnabled == old.interactionEnabled) {
      return;
    }
    _current = next;
    _resources.fire();
  }

  void invalidate({required int generation}) {
    if (_closed || generation < _current.generation) return;
    publish(_current.withoutImage(generation: generation));
  }

  /// Paint-only geometry/scroll signals never notify resource listeners.
  void invalidatePaint() {
    if (!_closed) _paint.fire();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _current = _current.withoutImage(generation: _current.generation + 1);
    // Closed state/image-free snapshot are visible inside every callback.
    _resources.fire();
    _paint.fire();
    _resources.close();
    _paint.close();
  }
}

/// Closed listenables accept late add/remove safely without retaining callbacks.
class _ClosableSignal implements Listenable {
  final Set<VoidCallback> _listeners = {};
  bool _closed = false;

  @override
  void addListener(VoidCallback listener) {
    if (!_closed) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void fire() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      if (!_closed && _listeners.contains(listener)) listener();
    }
  }

  void close() {
    _closed = true;
    _listeners.clear();
  }
}

@immutable
class MaterialPointerSample {
  const MaterialPointerSample({this.position, this.active = false});
  final Offset? position;
  final bool active;

  @override
  bool operator ==(Object other) =>
      other is MaterialPointerSample &&
      other.position == position &&
      other.active == active;
  @override
  int get hashCode => Object.hash(position, active);
}

/// Public leaf installed around the existing legacy renderer constructor.
/// Later renderer reads current during paint; no foundation back-write needed.
class MaterialSamplingInput extends InheritedWidget {
  const MaterialSamplingInput({
    required super.child,
    this.handle,
    this.pointer,
    super.key,
  });

  final MaterialSamplingHandle? handle;
  final ValueListenable<MaterialPointerSample>? pointer;

  static MaterialSamplingInput? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MaterialSamplingInput>();

  @override
  bool updateShouldNotify(MaterialSamplingInput oldWidget) =>
      handle != oldWidget.handle || pointer != oldWidget.pointer;
}
