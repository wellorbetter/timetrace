import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';

class TimetraceApp extends ConsumerWidget {
  const TimetraceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'TimeTrace',
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(),
      darkTheme: TimetraceTheme.dark(),
      routerConfig: router,
    );
  }
}
