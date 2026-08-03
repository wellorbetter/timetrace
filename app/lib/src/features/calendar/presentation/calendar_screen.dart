import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  String _diaryDraft = '';
  bool _diaryLoaded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = L10n(ref.watch(localeProvider));

    return Scaffold(
      appBar: AppBar(title: Text(l.calendar)),
      body: Column(
        children: [
          // ── Month calendar (open-source table_calendar) ──
          Card(
            margin: const EdgeInsets.all(8),
            child: TableCalendar(
              firstDay: DateTime(_focused.year, 1, 1),
              lastDay: DateTime(_focused.year, 12, 31),
              focusedDay: _focused,
              selectedDayPredicate: (d) => isSameDay(d, _selected),
              onDaySelected: (selected, focused) {
                setState(() {
                  _selected = selected;
                  _focused = focused;
                  _diaryLoaded = false;
                  _diaryDraft = '';
                });
              },
              calendarFormat: CalendarFormat.month,
              headerStyle: HeaderStyle(
                titleCentered: true,
                formatButtonVisible: false,
                titleTextStyle:
                    TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: scheme.onSurface),
                leftChevronIcon: Icon(Icons.chevron_left, color: scheme.primary),
                rightChevronIcon: Icon(Icons.chevron_right, color: scheme.primary),
              ),
              daysOfWeekStyle: DaysOfWeekStyle(
                weekdayStyle: TextStyle(fontSize: 11, color: scheme.outline),
                weekendStyle: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                todayDecoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                defaultTextStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
            ),
          ),
          const Divider(height: 1),

          // ── Day detail ──
          Expanded(
            child: _DayDetail(
              date: _selected,
              onDiaryChanged: (text) => setState(() => _diaryDraft = text),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayDetail extends ConsumerWidget {
  const _DayDetail({required this.date, required this.onDiaryChanged});

  final DateTime date;
  final ValueChanged<String> onDiaryChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final asyncDay = ref.watch(calendarDayProvider(date));

    return asyncDay.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
      data: (day) {
        final h = day.activeSeconds ~/ 3600;
        final m = (day.activeSeconds % 3600) ~/ 60;
        final ih = day.idleSeconds ~/ 60;

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // ── Date header ──
            Text(
              '${date.year}年${date.month}月${date.day}日',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _Chip(label: '活跃 ${h}h${m}m', color: scheme.primary),
                const SizedBox(width: 8),
                _Chip(label: '离开 ${ih}m', color: scheme.outline),
                const SizedBox(width: 8),
                _Chip(label: '${day.sessionCount} 会话', color: scheme.tertiary),
              ],
            ),
            const SizedBox(height: 12),

            // ── Diary / journal ──
            Text('日记', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 6),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    TextField(
                      controller: TextEditingController(text: day.diary),
                      maxLines: 4,
                      minLines: 2,
                      decoration: const InputDecoration(
                        hintText: '写下今天做了什么…',
                        border: InputBorder.none,
                      ),
                      onChanged: onDiaryChanged,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () async {
                          final current = ref
                              .read(calendarDayProvider(date))
                              .value
                              ?.diary ?? '';
                          try {
                            await saveDiary(ref, date, current);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('日记已保存'),
                                    duration: Duration(seconds: 1)),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('保存失败: $e')),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.save_outlined, size: 16),
                        label: const Text('保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Session timeline ──
            Text('使用记录', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 6),
            if (day.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('当天暂无记录',
                    style: TextStyle(color: scheme.outline, fontSize: 13)),
              )
            else
              for (final s in day.sessions)
                _SessionRow(session: s),
          ],
        );
      },
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session});

  final dynamic session; // DaySessionDto

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = session.durationSecs.toInt() ~/ 3600;
    final m = (session.durationSecs.toInt() % 3600) ~/ 60;
    final dur = h > 0 ? '${h}h${m}m' : '${m}m';

    // Parse start time from ISO string
    String time = '';
    try {
      final dt = DateTime.parse(session.startedAt as String).toLocal();
      time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    if (session.isIdle as bool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(Icons.access_time, size: 14, color: scheme.outline),
            const SizedBox(width: 8),
            Text('离开', style: TextStyle(fontSize: 13, color: scheme.outline)),
            const Spacer(),
            Text(dur, style: TextStyle(fontSize: 13, color: scheme.outline)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: appColor(session.appName as String), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          SizedBox(width: 44, child: Text(time, style: TextStyle(fontSize: 11, color: scheme.outline))),
          Expanded(
            child: Text(session.appName as String,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          ),
          Text(dur, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}
