import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/tray/tray_service.dart';

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
    _setup();
  }

  Future<void> _setup() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setIcon('assets/icon.ico');

    final tray = TrayService(ref);
    await tray.init();
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
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
      // Custom background (color or image) applied below the router.
      builder: (context, child) {
        if (!background.isImage && background.color == null) return child!;
        Widget decorated = child!;
        if (background.isImage && background.imagePath != null) {
          decorated = Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: FileImage(File(background.imagePath!)),
                fit: BoxFit.cover,
              ),
            ),
            child: decorated,
          );
        } else if (background.color != null) {
          decorated = ColoredBox(
            color: background.color!,
            child: decorated,
          );
        }
        return decorated;
      },
    );
  }
}
