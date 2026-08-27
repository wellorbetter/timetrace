import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/tray/tray_service.dart';
import 'package:window_manager/window_manager.dart';

class TimetraceApp extends ConsumerStatefulWidget {
  const TimetraceApp({super.key});

  @override
  ConsumerState<TimetraceApp> createState() => _TimetraceAppState();
}

class _TimetraceAppState extends ConsumerState<TimetraceApp>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    _setupDesktopWindow();
  }

  Future<void> _setupDesktopWindow() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    // Keep enough room for the explicit desktop sidebar plus a usable compact
    // content canvas. Native title bars remain platform-native.
    await windowManager.setTitle('TimeTrace');
    await windowManager.setMinimumSize(const Size(940, 620));
    await windowManager.setPreventClose(true);

    if (Platform.isWindows) {
      await windowManager.setIcon('assets/icon.ico');
    }

    final tray = TrayService(ref);
    await tray.init();
    final config = ref.read(apiProvider).getConfig();
    if (config.startMinimized ||
        Platform.executableArguments.contains('--minimized')) {
      await windowManager.hide();
    }
  }

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
            if (background.color != null)
              ColoredBox(color: background.color!),
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
