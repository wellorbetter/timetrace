import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../material/material.dart';
import '../widgets/workspace_glyph.dart';
import '../../features/feed/providers/feed_preferences_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/feed/presentation/feed_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import '../../features/time_tools/presentation/time_session_history_screen.dart';

/// Shell scaffold with a Material 3 NavigationRail.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  String? _lastMainRoute;

  void _returnFromSettings() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(_lastMainRoute == '/dashboard' ? '/dashboard' : '/feed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = GoRouterState.of(context).uri.path;
    final history = route.startsWith('/dashboard/time-history/');
    if (route == '/feed' || route == '/dashboard') _lastMainRoute = route;
    final minutes = ref.watch(feedBucketMinutesProvider);
    return Listener(
      onPointerDown: (event) {
        if ((event.buttons & kBackMouseButton) != 0) {
          if (route == '/settings') {
            _returnFromSettings();
          } else if (history) {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          } else if (context.canPop()) {
            context.pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Row(
              children: [
                NavigationRail(
                  selectedIndex: route == '/settings'
                      ? null
                      : _indexOf(context),
                  onDestinationSelected: (i) => context.go(_paths[i]),
                  labelType: NavigationRailLabelType.none,
                  minWidth: 64,
                  leading: const SizedBox(height: MaterialTokens.spaceXl),
                  // ── Material 3 selected-state colors ──
                  backgroundColor: Colors.transparent,
                  indicatorColor: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer,
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
                      icon: Tooltip(
                        message: '时间流',
                        child: Icon(Icons.history_rounded),
                      ),
                      selectedIcon: Tooltip(
                        message: '时间流',
                        child: Icon(Icons.history_toggle_off_rounded),
                      ),
                      label: Text('时间流'),
                    ),
                    NavigationRailDestination(
                      icon: Tooltip(
                        message: '工作台',
                        child: WorkspaceGlyph(WorkspaceGlyphKind.data),
                      ),
                      selectedIcon: Tooltip(
                        message: '工作台',
                        child: WorkspaceGlyph(WorkspaceGlyphKind.data),
                      ),
                      label: Text('工作台'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 56),
                    child: widget.child,
                  ),
                ),
              ],
            ),
            Positioned(
              right: MaterialTokens.spaceLg,
              bottom: MaterialTokens.spaceMd,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (route == '/feed')
                    Tooltip(
                      message: '修改时间流刻度',
                      child: TextButton(
                        key: const Key('feed_interval_settings'),
                        onPressed: () => context.push('/settings?section=feed'),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                          backgroundColor: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.65),
                        ),
                        child: Text(
                          minutes == 60 ? '1 小时 / 段' : '$minutes 分钟 / 段',
                        ),
                      ),
                    ),
                  const SizedBox(width: MaterialTokens.spaceSm),
                  IconButton.filledTonal(
                    key: const Key('workspace_settings'),
                    tooltip: route == '/settings' ? '返回' : '设置',
                    onPressed: route == '/settings'
                        ? _returnFromSettings
                        : () => context.push('/settings'),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.65),
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    icon: route == '/settings'
                        ? const Icon(Icons.arrow_back_rounded)
                        : const WorkspaceGlyph(WorkspaceGlyphKind.settings),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _paths = ['/feed', '/dashboard', '/settings'];

/// Resolve the selected rail index from the current route path.
int _indexOf(BuildContext context) {
  final location = GoRouterState.of(context).uri.path;
  if (location.startsWith('/dashboard/time-history/')) return 1;
  final i = _paths.indexOf(location);
  return i >= 0 ? i : 0;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/feed',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/feed', builder: (_, _) => const FeedScreen()),
          GoRoute(
            path: '/dashboard',
            builder: (_, _) => const DashboardScreen(),
            routes: [createTimeSessionHistoryRoute()],
          ),
          GoRoute(
            path: '/settings',
            builder: (_, state) => SettingsScreen(
              initialSection: state.uri.queryParameters['section'],
            ),
          ),
        ],
      ),
    ],
  );
});
