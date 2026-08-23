import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/extension/manager_screen.dart';
import 'package:timetrace_app/src/features/extensions/marketplace/marketplace.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';
import 'package:timetrace_app/src/plugin_platform/presentation/plugin_page_host.dart';

/// Application shell whose plugin destinations come only from Rust projection.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contributionState = ref.watch(contributionControllerProvider);
    final navigation = contributionState.value?.navigation ?? const [];
    final paths = <String>[
      '/dashboard',
      for (final contribution in navigation) contribution.route!,
      '/extensions/marketplace',
      '/settings',
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex(context, paths),
            onDestinationSelected: (index) => context.go(paths[index]),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          Theme.of(context).colorScheme.tertiary,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.timer_outlined,
                      size: 24,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'TimeTrace',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
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
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.insights_outlined),
                selectedIcon: Icon(Icons.insights),
                label: Text('仪表盘'),
              ),
              for (final contribution in navigation)
                NavigationRailDestination(
                  icon: Icon(_navigationIcon(contribution.iconToken)),
                  selectedIcon: Icon(
                    _navigationIcon(contribution.iconToken, selected: true),
                  ),
                  label: Text(contribution.title),
                ),
              const NavigationRailDestination(
                icon: Icon(Icons.storefront_outlined),
                selectedIcon: Icon(Icons.storefront),
                label: Text('插件商店'),
              ),
              const NavigationRailDestination(
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

int _selectedIndex(BuildContext context, List<String> paths) {
  final location = GoRouterState.of(context).uri.path;
  if (location == '/extensions') {
    return paths.indexOf('/extensions/marketplace');
  }
  final index = paths.indexOf(location);
  return index < 0 ? 0 : index;
}

IconData _navigationIcon(String? token, {bool selected = false}) {
  return switch (token) {
    'flight' => selected ? Icons.flight_takeoff : Icons.flight_takeoff_outlined,
    'calendar' =>
      selected ? Icons.calendar_month : Icons.calendar_month_outlined,
    'journal' => selected ? Icons.menu_book : Icons.menu_book_outlined,
    'dashboard' => selected ? Icons.dashboard : Icons.dashboard_outlined,
    _ => selected ? Icons.extension : Icons.extension_outlined,
  };
}

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, _) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/flight',
            redirect: (_, _) => '/extensions/private-flight/flight',
          ),
          GoRoute(
            path: '/extensions',
            builder: (_, _) => const ExtensionManagerScreen(),
          ),
          GoRoute(
            path: '/extensions/marketplace',
            builder: (_, _) => MarketplaceScreen(
              port: ref.watch(marketplaceCatalogPortProvider),
            ),
          ),
          GoRoute(
            name: 'marketplace-detail',
            path: '/extensions/marketplace/:publisherId/:pluginId',
            builder: (_, state) {
              final publisherId = state.pathParameters['publisherId'];
              final pluginId = state.pathParameters['pluginId'];
              if (!_isCanonicalMarketplaceId(publisherId) ||
                  !_isCanonicalMarketplaceId(pluginId)) {
                return const MarketplaceUnavailableScreen();
              }
              // The route identifies an entity only. It deliberately has no
              // release, digest, consent, or install instruction: detail and
              // installation are resolved afresh by the verified native port.
              return MarketplaceDetailScreen(
                port: ref.watch(marketplaceCatalogPortProvider),
                publisherId: MarketplacePublisherId(publisherId!),
                pluginId: MarketplacePluginId(pluginId!),
              );
            },
          ),
          GoRoute(
            path: '/extensions/:pluginId/:viewId',
            builder: (_, state) => PluginPageHost(
              pluginId: state.pathParameters['pluginId']!,
              viewId: state.pathParameters['viewId']!,
            ),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        ],
      ),
    ],
  );
});

final RegExp _canonicalMarketplaceId = RegExp(
  r'^[a-z0-9]+(?:[-._:][a-z0-9]+)*$',
);

bool _isCanonicalMarketplaceId(String? value) =>
    value != null &&
    value.length <= 128 &&
    _canonicalMarketplaceId.hasMatch(value);
