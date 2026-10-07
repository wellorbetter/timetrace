import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ffi';
import 'dart:ui';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import '../router/app_router.dart';
import 'tray_panel.dart';
import '../window/window_presentation.dart';

/// Manages the Windows system tray icon and its interactions.
class TrayService with TrayListener, WindowListener {
  TrayService(this._ref, {WindowPresentation? presentation})
    : _presentation = presentation ?? _ref.read(windowPresentationProvider);

  final WidgetRef _ref;
  bool _paused = false;
  bool _changingWindow = false;
  bool _disposed = false;
  bool _panel = false;
  final WindowPresentation _presentation;

  // Tray context menu icons (16x16 base64 PNG).
  static const String _kIconShow =
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAZklEQVR4nO1SWwrAMAizsmPp6fVeHWU4SqtScJ/LX0PzIAjwo0UTEFFfOVXd/rdIKCKbKTOHRq94xnivnPGPAgAhwEizFpacgqakkybWArMGJ+nokV51b9RPRrwyw5PU8h2UL7GMGzCSkIWLkZkvAAAAAElFTkSuQmCC';
  static const String _kIconPause =
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAALUlEQVR4nGNgGH7AxsbmPwgTK8eErgAbG58cE6UuZho1gGEYhAEGIDUlDjwAALBjFHdOOiO6AAAAAElFTkSuQmCC';
  static const String _kIconResume =
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAT0lEQVR4nN2SOw4AIAhDteFYHL/30tWlfFxM7EZCH23CGP/J3VdnHwpSBSFLk4FQuRJBUAFEaVAFKJB1ASTnOdutsVWBwpwmYGCU6n7ie23ByBv+NEZV0QAAAABJRU5ErkJggg==';
  static const String _kIconQuit =
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAVElEQVR4nGNgoCWwsbH5D8L41DBRagkjPtvRxY4cOcJIlAtscDgbmzgTqTajyzPh0ozuXFyGMGFzKja/4hJnwaaQkEFUjUYmqsbCESKcTIo6hhECANIvJ3wHSlFkAAAAAElFTkSuQmCC';

  Future<void> init() async {
    trayManager.addListener(this);
    windowManager.addListener(this);
    _paused = _ref.read(apiProvider).isTrackingPaused();
    await trayManager.setIcon('assets/icon.ico', isTemplate: false);
    await trayManager.setToolTip('TimeTrace — 应用使用追踪');
    await _updateMenu();
    AppLogger.log('tray initialized');
  }

  Future<void> _updateMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'status',
            label: _paused ? '已暂停追踪' : '正在追踪使用时间',
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'show',
            label: '打开工作台',
            icon: _kIconShow,
            onClick: (_) => openWorkspace(),
          ),
          MenuItem(
            key: 'pause',
            label: _paused ? '▶ 恢复追踪' : '⏸ 暂停追踪',
            icon: _paused ? _kIconResume : _kIconPause,
            onClick: (_) => _togglePause(),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit',
            label: '退出',
            icon: _kIconQuit,
            onClick: (_) => _quit(),
          ),
        ],
      ),
    );
  }

  Future<void> _showWindow() async {
    await dismissPanel();
    if (_disposed) return;
    await windowManager.show();
    if (_disposed) return;
    await windowManager.focus();
  }

  Future<void> openWorkspace() async {
    await _showWindow();
    if (!_disposed) _ref.read(appRouterProvider).go('/dashboard');
  }

  Future<void> openSettings() async {
    await _showWindow();
    if (!_disposed) _ref.read(appRouterProvider).push('/settings');
  }

  Future<void> showPanel() async {
    if (_disposed || _changingWindow) return;
    if (_panel) { await dismissPanel(); return; }
    _changingWindow = true;
    try {
      final opened = await _presentation.enterPanel((mainBounds) async {
        final anchor = await trayManager.getBounds() ?? mainBounds;
        final ratio = windowManager.getDevicePixelRatio();
        final rect = calloc<RECT>();
        final monitorInfo = calloc<MONITORINFO>();
        late Rect work;
        try {
          rect.ref
            ..left = (anchor.left * ratio).round()
            ..top = (anchor.top * ratio).round()
            ..right = (anchor.right * ratio).round()
            ..bottom = (anchor.bottom * ratio).round();
          monitorInfo.ref.cbSize = sizeOf<MONITORINFO>();
          final monitor = MonitorFromRect(rect, MONITOR_DEFAULTTONEAREST);
          if (GetMonitorInfo(monitor, monitorInfo) == 0) {
            throw StateError('Monitor unavailable');
          }
          final area = monitorInfo.ref.rcWork;
          work = Rect.fromLTRB(
            area.left / ratio, area.top / ratio,
            area.right / ratio, area.bottom / ratio,
          );
        } finally {
          calloc.free(rect);
          calloc.free(monitorInfo);
        }
        return trayPanelBounds(work, anchor);
      });
      if (_disposed) return;
      if (!opened) {
        AppLogger.log('tray panel could not open');
        await windowManager.show();
        return;
      }
      _panel = true;
      _ref.read(trayPanelVisibleProvider.notifier).setVisible(true);
      _ref.invalidate(trayOverviewProvider);
      await windowManager.show();
      if (_disposed) return;
      await windowManager.focus();
    } catch (_) {
      if (_disposed) return;
      AppLogger.log('tray panel could not open');
      await _presentation.leavePanel();
      if (_disposed) return;
      _panel = false;
      _ref.read(trayPanelVisibleProvider.notifier).setVisible(false);
      await windowManager.show();
    } finally {
      _changingWindow = false;
    }
  }

  Future<void> dismissPanel() async {
    if (!_panel || _changingWindow) return;
    _changingWindow = true;
    try {
      await _presentation.leavePanel();
      if (_disposed) return;
      _panel = false;
      _ref.read(trayPanelVisibleProvider.notifier).setVisible(false);
    } finally {
      _changingWindow = false;
    }
  }

  @override
  void onWindowBlur() {
    if (_panel && !_changingWindow) dismissPanel();
  }

  void dispose() {
    _disposed = true;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
  }

  Future<void> togglePaused() async {
    await _togglePause();
    _ref.invalidate(trayOverviewProvider);
  }

  Future<void> _togglePause() async {
    try {
      final api = _ref.read(apiProvider);
      api.setTrackingPaused(paused: !api.isTrackingPaused());
      _paused = api.isTrackingPaused();
      AppLogger.log('tracking ${_paused ? 'paused' : 'resumed'} via tray');
    } catch (e) {
      AppLogger.log('tray pause failed: $e');
    }
    await trayManager.setToolTip(
      _paused ? 'TimeTrace — 已暂停' : 'TimeTrace — 应用使用追踪',
    );
    await _updateMenu();
  }

  Future<void> _quit() async {
    AppLogger.log('quit via tray');
    await trayManager.destroy();
    _ref.read(trayExitProvider.notifier).requestExit();
  }

  @override
  void onTrayIconMouseDown() {
    showPanel();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }
}

/// Signals the app to exit (set by tray Quit).
class TrayExitNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void requestExit() => state = true;
}

final trayExitProvider = NotifierProvider<TrayExitNotifier, bool>(
  TrayExitNotifier.new,
);
