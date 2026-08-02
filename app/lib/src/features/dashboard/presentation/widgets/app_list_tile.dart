import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Single app row in the dashboard list.
class AppListTile extends StatelessWidget {
  const AppListTile({required this.app, super.key});

  final AppUsageItem app;

  @override
  Widget build(BuildContext context) {
    final color = appColor(app.appName);
    final h = app.activeSeconds ~/ 3600;
    final m = (app.activeSeconds % 3600) ~/ 60;
    final activeLabel = h > 0 ? '${h}时${m}分' : '${m}分';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(Icons.apps, color: color),
        title: Text(app.appName, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (app.idleSeconds > 0)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text('挂机 ${app.idleLabel}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            Text(activeLabel,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
