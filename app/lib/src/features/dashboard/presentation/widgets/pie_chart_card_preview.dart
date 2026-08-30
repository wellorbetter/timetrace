import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';

const _previewApps = [
  AppUsageItem(
    appName: 'Visual Studio Code',
    activeSeconds: 3600,
    idleSeconds: 0,
  ),
  AppUsageItem(appName: 'Chrome', activeSeconds: 1800, idleSeconds: 0),
  AppUsageItem(appName: 'Terminal', activeSeconds: 900, idleSeconds: 0),
  AppUsageItem(appName: 'TimeTrace', activeSeconds: 720, idleSeconds: 0),
  AppUsageItem(appName: 'Figma', activeSeconds: 480, idleSeconds: 0),
];

@Preview(name: '占比联动 · 桌面', size: Size(560, 420))
Widget pieChartCardDesktopPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.dark(),
  home: const Scaffold(
    body: Padding(padding: EdgeInsets.all(16), child: _InteractivePiePreview()),
  ),
);

@Preview(name: '占比联动 · 窄窗', size: Size(390, 350))
Widget pieChartCardCompactPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(),
  home: const Scaffold(
    body: Padding(padding: EdgeInsets.all(12), child: _InteractivePiePreview()),
  ),
);

class _InteractivePiePreview extends StatefulWidget {
  const _InteractivePiePreview();

  @override
  State<_InteractivePiePreview> createState() => _InteractivePiePreviewState();
}

class _InteractivePiePreviewState extends State<_InteractivePiePreview> {
  int? _selected;

  @override
  Widget build(BuildContext context) => PieChartCard(
    apps: _previewApps,
    selectedIndex: _selected,
    onSelectApp: (index) => setState(() => _selected = index),
  );
}
