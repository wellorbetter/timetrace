import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Manages the Windows system tray icon and its interactions.
class TrayService with TrayListener {
  TrayService(this._ref);

  final WidgetRef _ref;
  bool _paused = false;

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
    await trayManager.setIcon(
      'assets/icon.ico',
      isTemplate: false,
    );
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
            label: '显示窗口',
            icon: _kIconShow,
            onClick: (_) => _showWindow(),
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
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _togglePause() async {
    _paused = !_paused;
    try {
      _ref.read(apiProvider).setTrackingPaused(paused: _paused);
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
    _showWindow();
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

final trayExitProvider =
    NotifierProvider<TrayExitNotifier, bool>(TrayExitNotifier.new);
