import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';

/// Quiet desktop shell: compact, top-aligned navigation with almost no
/// decorative chrome. The content canvas remains the visual focus.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: TimeTraceLayout.railWidth,
            child: NavigationRail(
              selectedIndex: _indexOf(context),
              onDestinationSelected: (i) => context.go(_paths[i]),
              labelType: NavigationRailLabelType.all,
              minWidth: 72,
              // Desktop navigation is an anchor, not a vertically floating
              // mobile control. Keep both destinations attached to the top.
              groupAlignment: -1,
              leading: Padding(
                padding: const EdgeInsets.fromLTRB(
                  TimeTraceSpace.xs,
                  TimeTraceSpace.md,
                  TimeTraceSpace.xs,
                  TimeTraceSpace.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius:
                            BorderRadius.circular(TimeTraceRadius.control),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Icon(
                        Icons.timelapse_rounded,
                        size: 20,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: TimeTraceSpace.xs),
                    Text(
                      'TimeTrace',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.15,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.space_dashboard_outlined),
                  selectedIcon: Icon(Icons.space_dashboard_rounded),
                  label: Text('概览'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: Text('设置'),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant),
          Expanded(child: child),
        ],
      ),
    );
  }
}

const _paths = ['/dashboard', '/settings'];

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
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  );
});
