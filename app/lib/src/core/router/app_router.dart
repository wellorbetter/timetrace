import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/startup/presentation/startup_screen.dart';

/// Shell scaffold with a Material 3 NavigationRail.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _indexOf(child),
            onDestinationSelected: (i) => context.go(_paths[i]),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 16),
              child: Icon(Icons.timer_outlined, size: 28),
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
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

const _paths = ['/dashboard', '/startup'];

int _indexOf(Widget child) {
  if (child is DashboardScreen) return 0;
  if (child is StartupScreen) return 1;
  return 0;
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
        ],
      ),
    ],
  );
});
