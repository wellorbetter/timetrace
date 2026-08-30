import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/tray/tray_service.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';
import 'package:timetrace_app/src/features/settings/providers/ai_diary_scheduler_provider.dart';
import 'package:window_manager/window_manager.dart';

class TimetraceApp extends ConsumerStatefulWidget {
  const TimetraceApp({super.key});

  @override
  ConsumerState<TimetraceApp> createState() => _TimetraceAppState();
}

class _TimetraceAppState extends ConsumerState<TimetraceApp>
    with WindowListener, WidgetsBindingObserver {
  late final TrayService _tray;
  ProviderSubscription<ReminderRuntimeState>? _reminderKeepAlive;
  bool _disposed = false;
  bool _windowListenerAttached = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tray = TrayService(ref);
    // Keep the process-wide runtime alive without watching it from build: the
    // once-per-second state changes must not rebuild MaterialApp/router/theme.
    _reminderKeepAlive = ref.listenManual(
      reminderRuntimeProvider,
      (_, _) {},
      fireImmediately: true,
    );
    unawaited(ref.read(aiDiaryDailySchedulerProvider).start());
    unawaited(_setupDesktopWindowSafely());
  }

  @override
  void dispose() {
    _disposed = true;
    _reminderKeepAlive?.close();
    unawaited(_tray.dispose());
    WidgetsBinding.instance.removeObserver(this);
    if (_windowListenerAttached) {
      windowManager.removeListener(this);
      _windowListenerAttached = false;
    }
    super.dispose();
  }

  Future<void> _setupDesktopWindowSafely() async {
    try {
      await _setupDesktopWindow();
    } catch (_) {
      // This task is intentionally detached from initState. Report failures
      // without allowing an unhandled Future to terminate desktop startup.
      if (!_disposed) {
        AppLogger.log('desktop window setup failed');
      }
    }
  }

  Future<void> _setupDesktopWindow() async {
    await windowManager.ensureInitialized();
    if (!_canContinueDesktopSetup) return;
    windowManager.addListener(this);
    _windowListenerAttached = true;

    // Keep enough room for the explicit desktop sidebar plus a usable compact
    // content canvas. Native title bars remain platform-native.
    await windowManager.setTitle('TimeTrace');
    if (!_canContinueDesktopSetup) return;
    await windowManager.setMinimumSize(const Size(940, 620));
    if (!_canContinueDesktopSetup) return;
    await windowManager.setPreventClose(true);
    if (!_canContinueDesktopSetup) return;

    if (Platform.isWindows) {
      await windowManager.setIcon('assets/icon.ico');
      if (!_canContinueDesktopSetup) return;
    }

    await _tray.init();
    if (!_canContinueDesktopSetup) return;
    final config = ref.read(apiProvider).getConfig();
    if (config.startMinimized ||
        Platform.executableArguments.contains('--minimized')) {
      await windowManager.hide();
    }
  }

  bool get _canContinueDesktopSetup => !_disposed && mounted;

  @override
  void onWindowClose() async {
    final config = ref.read(apiProvider).getConfig();
    if (config.minimizeToTray) {
      await windowManager.hide();
    } else {
      ref.read(trayExitProvider.notifier).requestExit();
    }
  }

  @override
  void onWindowFocus() {
    unawaited(ref.read(aiDiaryDailySchedulerProvider).checkNow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(aiDiaryDailySchedulerProvider).checkNow());
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final dark = ref.watch(themeModeProvider);
    final font = ref.watch(fontProvider);
    final background = ref.watch(backgroundProvider);

    ref.listen(trayExitProvider, (prev, next) {
      if (next) exit(0);
    });

    return MaterialApp.router(
      title: 'TimeTrace',
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(fontFamily: font.family),
      darkTheme: TimetraceTheme.dark(fontFamily: font.family),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
      builder: (context, child) {
        final scheme = Theme.of(context).colorScheme;
        final hasCustom = background.isImage || background.color != null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (background.isImage && background.imagePath != null)
              Image.file(File(background.imagePath!), fit: BoxFit.cover),
            if (background.color != null) ColoredBox(color: background.color!),
            ColoredBox(
              color: scheme.surface.withValues(
                alpha: hasCustom ? 1 - background.opacity : 1,
              ),
            ),
            child!,
          ],
        );
      },
    );
  }
}
