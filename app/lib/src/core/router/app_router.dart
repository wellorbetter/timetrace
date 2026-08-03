import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/features/calendar/presentation/calendar_screen.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import 'package:timetrace_app/src/features/startup/presentation/startup_screen.dart';

/// Shell scaffold with a Material 3 NavigationRail.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = ref.watch(themeModeProvider);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _indexOf(context),
            onDestinationSelected: (i) => context.go(_paths[i]),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 16),
              child: Icon(Icons.timer_outlined, size: 28),
            ),
            // ── Material 3 selected-state colors ──
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
            indicatorColor: Theme.of(context).colorScheme.secondaryContainer,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            selectedIconTheme: IconThemeData(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            selectedLabelTextStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
            unselectedIconTheme: IconThemeData(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            unselectedLabelTextStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.insights_outlined),
                selectedIcon: Icon(Icons.insights),
                label: Text('仪表盘'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.power_settings_new_outlined),
                selectedIcon: Icon(Icons.power_settings_new),
                label: Text('自启动'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: Text('日历'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

const _paths = ['/dashboard', '/startup', '/calendar', '/settings'];

/// Resolve the selected rail index from the current route path.
int _indexOf(BuildContext context) {
  final location = GoRouterState.of(context).uri.path;
  final i = _paths.indexOf(location);
  return i >= 0 ? i : 0;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, _) => const DashboardScreen()),
          GoRoute(path: '/startup', builder: (_, _) => const StartupScreen()),
          GoRoute(path: '/calendar', builder: (_, _) => const CalendarScreen()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  );
});
