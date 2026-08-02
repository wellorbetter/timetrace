import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/screens/dashboard_screen.dart';
import 'package:timetrace_app/src/screens/startup_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  bool _dark = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = [const DashboardScreen(), const StartupScreen()];

    return Scaffold(
      body: Row(
        children: [
          // ── Navigation Rail ──
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Icon(Icons.timer_outlined, size: 30, color: scheme.primary),
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
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: IconButton(
                    icon: Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                    onPressed: () {
                      setState(() => _dark = !_dark);
                      // Toggle platform brightness
                      SystemChrome.setSystemUIOverlayStyle(
                        SystemUiOverlayStyle(
                          statusBarIconBrightness: _dark ? Brightness.light : Brightness.dark,
                        ),
                      );
                    },
                    tooltip: '切换主题',
                  ),
                ),
              ),
            ),
          ),
          // ── Content ──
          Expanded(child: pages[_index]),
        ],
      ),
    );
  }
}
