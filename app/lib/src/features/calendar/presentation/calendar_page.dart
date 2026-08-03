import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';

/// Dedicated calendar + diary page.
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('日历 / 日记')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          CalendarCard(),
        ],
      ),
    );
  }
}
