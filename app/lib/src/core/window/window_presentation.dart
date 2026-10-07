import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// These are plugin-return acknowledgements, not observed native appearance.
class WindowMainSnapshot {
  const WindowMainSnapshot({
    required this.bounds, required this.maximized, required this.resizable,
    required this.alwaysOnTop, required this.skipTaskbar,
  });
  final Rect bounds;
  final bool maximized, resizable, alwaysOnTop, skipTaskbar;
}

/// Tests must explicitly inject a fake; constructing the default does no IO.
abstract class WindowPresentationPort {
  Future<void> frame(bool immersive);
  Future<WindowMainSnapshot> captureMain();
  Future<void> panel(Rect bounds);
  Future<void> restoreMain(WindowMainSnapshot snapshot);
  Future<void> hide();
  Future<void> minimize();
  Future<bool> isMaximized();
  Future<void> maximize(bool value);
  Future<void> close();
  Future<void> drag();
  Future<void> resize(ResizeEdge edge);
  Future<void> menu();
}

class WindowManagerPresentationPort implements WindowPresentationPort {
  const WindowManagerPresentationPort();
  @override
  Future<void> frame(bool immersive) => immersive
      ? windowManager.setAsFrameless()
      : windowManager.setTitleBarStyle(TitleBarStyle.normal);
  @override
  Future<WindowMainSnapshot> captureMain() async {
    final maximized = await windowManager.isMaximized();
    final resizable = await windowManager.isResizable();
    final alwaysOnTop = await windowManager.isAlwaysOnTop();
    final skipTaskbar = await windowManager.isSkipTaskbar();
    if (maximized) await windowManager.unmaximize();
    try {
      return WindowMainSnapshot(
        bounds: await windowManager.getBounds(), maximized: maximized,
        resizable: resizable, alwaysOnTop: alwaysOnTop, skipTaskbar: skipTaskbar,
      );
    } catch (_) {
      if (maximized) await windowManager.maximize();
      rethrow;
    }
  }
  @override
  Future<void> panel(Rect bounds) async {
    await windowManager.setResizable(false);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setBounds(bounds);
  }
  @override
  Future<void> restoreMain(WindowMainSnapshot snapshot) async {
    await windowManager.setResizable(snapshot.resizable);
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    await windowManager.setSkipTaskbar(snapshot.skipTaskbar);
    await windowManager.setBounds(snapshot.bounds);
    if (snapshot.maximized) await windowManager.maximize();
  }
  @override
  Future<void> hide() => windowManager.hide();
  @override
  Future<void> minimize() => windowManager.minimize();
  @override
  Future<bool> isMaximized() => windowManager.isMaximized();
  @override
  Future<void> maximize(bool value) => value
      ? windowManager.maximize() : windowManager.unmaximize();
  @override
  Future<void> close() => windowManager.close();
  @override
  Future<void> drag() => windowManager.startDragging();
  @override
  Future<void> resize(ResizeEdge edge) => windowManager.startResizing(edge);
  @override
  Future<void> menu() => windowManager.popUpWindowMenu();
}

final windowPresentationPortProvider = Provider<WindowPresentationPort>(
  (ref) => const WindowManagerPresentationPort(),
);
final windowPresentationProvider = Provider.autoDispose<WindowPresentation>((ref) {
  final value = WindowPresentation(ref.watch(windowPresentationPortProvider));
  ref.onDispose(value.dispose);
  return value;
});

/// One serial style writer for main-window preferences and temporary tray mode.
class WindowPresentation extends ChangeNotifier {
  WindowPresentation(this.port);
  final WindowPresentationPort port;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false, _ready = false, _contrast = false;
  bool desiredImmersive = false, effectiveImmersive = false;
  bool frameAcknowledged = false, emergencyCaption = false;
  bool panelVisible = false, maximized = false, resizable = true, busy = false;
  String? error;
  WindowMainSnapshot? _main;

  bool get captionVisible => !panelVisible &&
      (effectiveImmersive || emergencyCaption);
  bool get resizeEnabled => captionVisible && !maximized && resizable;
  bool get _target => desiredImmersive && !_contrast;
  void _notify() { if (!_disposed) notifyListeners(); }
  Future<T> _guard<T>(Future<T> value) async {
    final result = await value;
    if (_disposed) throw StateError('Window presentation disposed');
    return result;
  }
  Future<T> _serial<T>(Future<T> Function() task, T fallback) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      if (_disposed) { result.complete(fallback); return; }
      busy = true;
      _notify();
      try {
        result.complete(await task());
      } catch (_) {
        if (!_disposed) {
          error = '窗口操作未完成，请重试';
          _notify();
        }
        result.complete(fallback);
      } finally {
        if (!_disposed) { busy = false; _notify(); }
      }
    });
    return result.future;
  }

  Future<void> activate() => _serial<void>(() async {
    _ready = true;
    await _reconcile(force: true);
  }, null);

  Future<void> setDesired(bool immersive, {bool highContrast = false}) {
    if (_disposed) return Future<void>.value();
    final changed = desiredImmersive != immersive || _contrast != highContrast;
    desiredImmersive = immersive;
    _contrast = highContrast;
    if (changed) _notify();
    if (!_ready || panelVisible) return Future<void>.value();
    return _serial<void>(() => _reconcile(), null);
  }
  Future<void> retry() => _serial<void>(() async {
    if (_main != null && !panelVisible) {
      await _restoreMain();
    } else {
      await _reconcile(force: true);
    }
  }, null);

  Future<void> _reconcile({bool force = false}) async {
    if (!_ready || panelVisible || _disposed) return;
    while (!_disposed && !panelVisible &&
        (force || !frameAcknowledged || effectiveImmersive != _target)) {
      force = false;
      final target = _target;
      try {
        await _guard(port.frame(target));
        effectiveImmersive = target;
        frameAcknowledged = true;
        emergencyCaption = false;
        error = null;
        _notify();
      } catch (_) {
        if (_disposed) return;
        error = '窗口外观未切换，已尝试恢复标准窗口';
        try {
          await _guard(port.frame(false));
          effectiveImmersive = false;
          frameAcknowledged = true;
          emergencyCaption = false;
        } catch (_) {
          if (_disposed) return;
          // Partial native failure is unknown. Retain accessible custom controls.
          frameAcknowledged = false;
          emergencyCaption = true;
          error = '标准窗口未确认恢复，请重试';
        }
        _notify();
        return; // retry is explicit; no unbounded failure loop
      }
    }
  }

  Future<bool> enterPanel(
    Future<Rect> Function(Rect mainBounds) resolveBounds,
  ) => _serial<bool>(() async {
    if (panelVisible) return true;
    if (!_ready) return false;
    try {
      _main = await _guard(port.captureMain());
      final bounds = await _guard(resolveBounds(_main!.bounds));
      await _guard(port.hide());
      // Defer main preference requests from this point until leavePanel.
      panelVisible = true;
      _notify();
      await _guard(port.frame(true));
      effectiveImmersive = true;
      frameAcknowledged = true;
      await _guard(port.panel(bounds));
      maximized = false;
      resizable = false;
      error = null;
      _notify();
      return true;
    } catch (_) {
      if (_disposed) return false;
      panelVisible = false;
      await _restoreMain();
      error = '托盘面板未打开，已尝试恢复主窗口';
      _notify();
      return false;
    }
  }, false);

  Future<void> _restoreMain() async {
    panelVisible = false;
    _notify();
    await _reconcile(force: true);
    final snapshot = _main;
    if (snapshot != null) {
      await _guard(port.restoreMain(snapshot));
      maximized = snapshot.maximized;
      resizable = snapshot.resizable;
      _main = null;
      _notify();
    }
  }
  Future<void> leavePanel() => _serial<void>(() async {
    if (!panelVisible && _main == null) return;
    await _guard(port.hide());
    await _restoreMain();
  }, null);

  void noteMaximized(bool value) {
    if (_disposed) return;
    maximized = value;
    _notify();
  }
  Future<void> toggleMaximized() => _serial<void>(() async {
    final next = !await _guard(port.isMaximized());
    await _guard(port.maximize(next));
    maximized = next;
    _notify();
  }, null);
  Future<void> minimize() => _serial<void>(() => _guard(port.minimize()), null);
  Future<void> close() => _serial<void>(() => _guard(port.close()), null);
  Future<void> drag() => _serial<void>(() => _guard(port.drag()), null);
  Future<void> resize(ResizeEdge edge) => _serial<void>(() async {
    if (resizeEnabled) await _guard(port.resize(edge));
  }, null);
  Future<void> menu() => _serial<void>(() => _guard(port.menu()), null);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
