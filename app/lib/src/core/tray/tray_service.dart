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
            key: 'show',
            label: '显示窗口',
            onClick: (_) => _showWindow(),
          ),
          MenuItem(
            key: 'pause',
            label: _paused ? '▶ 恢复追踪' : '⏸ 暂停追踪',
            onClick: (_) => _togglePause(),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'quit',
            label: '退出',
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
