import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';

/// Quiet desktop shell with a narrow, explicit sidebar rather than a mobile-
/// flavored NavigationRail. The content canvas remains the visual focus.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sidebarColor =
        theme.navigationRailTheme.backgroundColor ?? scheme.surface;
    final useMeta = Platform.isMacOS;
    final selectedIndex = _indexOf(context);
    final shortcutPrefix = useMeta ? '⌘' : 'Ctrl+';

    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.digit1,
          meta: useMeta,
          control: !useMeta,
        ): () => context.go('/dashboard'),
        SingleActivator(
          LogicalKeyboardKey.digit2,
          meta: useMeta,
          control: !useMeta,
        ): () => context.go('/settings'),
        SingleActivator(
          LogicalKeyboardKey.comma,
          meta: useMeta,
          control: !useMeta,
        ): () => context.go('/settings'),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: TimeTraceLayout.railWidth,
                child: ColoredBox(
                  color: sidebarColor,
                  child: SafeArea(
                    right: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TimeTraceSpace.sm,
                        TimeTraceSpace.md,
                        TimeTraceSpace.sm,
                        TimeTraceSpace.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Brand(scheme: scheme),
                          const SizedBox(height: TimeTraceSpace.lg),
                          _SidebarDestination(
                            icon: Icons.space_dashboard_outlined,
                            selectedIcon: Icons.space_dashboard_rounded,
                            label: '概览',
                            shortcut: '${shortcutPrefix}1',
                            selected: selectedIndex == 0,
                            onTap: () => context.go('/dashboard'),
                          ),
                          const SizedBox(height: TimeTraceSpace.xxs),
                          _SidebarDestination(
                            icon: Icons.tune_outlined,
                            selectedIcon: Icons.tune_rounded,
                            label: '设置',
                            shortcut: useMeta ? '⌘,' : 'Ctrl+,',
                            selected: selectedIndex == 1,
                            onTap: () => context.go('/settings'),
                          ),
                          const Spacer(),
                          _LocalStatus(scheme: scheme),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: scheme.outlineVariant,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Icon(
            Icons.timelapse_rounded,
            size: 19,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: TimeTraceSpace.xs),
        Expanded(
          child: Text(
            'TimeTrace',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.15,
            ),
          ),
        ),
      ],
    );
  }
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.shortcut,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String shortcut;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Tooltip(
      message: '$label · $shortcut',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          child: AnimatedContainer(
            duration: TimeTraceMotion.fast,
            curve: TimeTraceMotion.standard,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xs),
            decoration: BoxDecoration(
              color: selected ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 19,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  shortcut,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalStatus extends StatelessWidget {
  const _LocalStatus({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = Platform.isMacOS ? 'macOS' : 'Windows';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.72),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '本地记录',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  platform,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.lock_outline_rounded,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
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
