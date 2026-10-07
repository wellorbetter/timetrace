import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/material/material.dart';
import '../domain/time_tool_state.dart';
import '../providers/time_tools_provider.dart';
import 'time_session_history_screen.dart';

String _duration(int s) => s ~/ 60 >= 60
    ? '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'
    : (s ~/ 60).toString().padLeft(2, '0') +
          ':' +
          (s % 60).toString().padLeft(2, '0');
String _localText(DateTime date, {bool seconds = false}) {
  final d = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return d.year.toString() +
      '-' +
      two(d.month) +
      '-' +
      two(d.day) +
      ' ' +
      two(d.hour) +
      ':' +
      two(d.minute) +
      (seconds ? ':${two(d.second)}' : '');
}

/// Display refresh never accumulates business seconds or writes each tick.
class _ClockView extends ConsumerStatefulWidget {
  const _ClockView({required this.builder});
  final Widget Function(BuildContext, DateTime) builder;
  @override
  ConsumerState<_ClockView> createState() => _ClockViewState();
}

class _ClockViewState extends ConsumerState<_ClockView> {
  Timer? _timer;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (TickerMode.of(context)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        ref.read(timeToolsProvider.notifier).reconcile();
        setState(() {});
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && TickerMode.of(context))
          ref.read(timeToolsProvider.notifier).reconcile();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ref.watch(timeToolsClockProvider)());
}

class _ToolStatus extends ConsumerWidget {
  const _ToolStatus({this.showPending = true});
  final bool showPending;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(timeToolsProvider);
    final notifier = ref.read(timeToolsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!view.loaded || view.loading) const Text('正在读取时间组件…'),
        if (view.error != null)
          Text(
            view.error!,
            key: const Key('time_tools_error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (view.blocked || !view.loaded && !view.loading)
          _ToolButton(
            label: '重试读取',
            actionKey: 'time_tools_reload',
            onPressed: view.loading ? null : () => notifier.reload(),
          ),
        if (view.dirty && !view.blocked && (showPending || view.error != null))
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('修改尚未保存到本机'),
              _ToolButton(
                label: '重试保存',
                actionKey: 'time_tools_retry',
                onPressed: view.canEdit ? () => notifier.retrySave() : null,
              ),
            ],
          ),
      ],
    );
  }
}


/// Pending intent belongs to the task data, not an unrelated shared revision.
/// Real shared failures/read guards remain visible through the original status.
class _TaskSaveStatus extends ConsumerStatefulWidget {
  const _TaskSaveStatus();
  @override
  ConsumerState<_TaskSaveStatus> createState() => _TaskSaveStatusState();
}

class _TaskSaveStatusState extends ConsumerState<_TaskSaveStatus> {
  bool _pending = false;
  @override
  Widget build(BuildContext context) {
    ref.listen<TimeToolsViewState>(timeToolsProvider, (before, after) {
      final changed = before != null &&
          jsonEncode(before.data.tasks.map((task) => task.toJson()).toList()) !=
          jsonEncode(after.data.tasks.map((task) => task.toJson()).toList());
      final next = after.dirty && (_pending || changed);
      if (next != _pending) setState(() => _pending = next);
    });
    return _ToolStatus(showPending: _pending);
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.actionKey,
    this.onPressed,
    this.primary = false,
  });
  final String label, actionKey;
  final bool primary;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => MaterialActionButton(
    buttonKey: Key(actionKey),
    role: primary ? MaterialActionRole.primary : MaterialActionRole.secondary,
    onPressed: onPressed,
    child: Text(label),
  );
}

class _ToolIcon extends StatelessWidget {
  const _ToolIcon({
    required this.label,
    required this.actionKey,
    required this.icon,
    this.onPressed,
  });
  final String label, actionKey;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => MaterialIconAction(
    buttonKey: Key(actionKey),
    tooltip: label,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
  );
}

class PomodoroWidget extends ConsumerStatefulWidget {
  const PomodoroWidget({super.key});
  @override
  ConsumerState<PomodoroWidget> createState() => _PomodoroWidgetState();
}

class _PomodoroWidgetState extends ConsumerState<PomodoroWidget> {
  final _focus = TextEditingController(), _rest = TextEditingController();
  final _focusHours = TextEditingController(),
      _focusSeconds = TextEditingController();
  final _restHours = TextEditingController(),
      _restSeconds = TextEditingController();
  final _end = TextEditingController();
  final _focusTotal = TextEditingController(), _restTotal = TextEditingController();
  final _advancedFocus = FocusNode();
  final _advancedScope = FocusScopeNode();
  bool _panelOpen = false;
  @override
  void dispose() {
    for (final c in [
      _focus,
      _rest,
      _focusHours,
      _focusSeconds,
      _restHours,
      _restSeconds,
      _end,
      _focusTotal,
      _restTotal,
    ]) {
      c.dispose();
    }
    _advancedFocus.dispose();
    _advancedScope.dispose();
    super.dispose();
  }

  void _edit({bool endTime = false}) {
    if (_panelOpen || !ref.read(timeToolsProvider).canEdit) return;
    final p = ref.read(timeToolsProvider).data.pomodoro;
    if (_focus.text.isEmpty) {
      _focus.text = ((p.focusSeconds % 3600) ~/ 60).toString();
      _focusHours.text = (p.focusSeconds ~/ 3600).toString();
      _focusSeconds.text = (p.focusSeconds % 60).toString();
      _rest.text = ((p.restSeconds % 3600) ~/ 60).toString();
      _restHours.text = (p.restSeconds ~/ 3600).toString();
      _restSeconds.text = (p.restSeconds % 60).toString();
    }
    if (_focusTotal.text.isEmpty) {
      _focusTotal.text = ((int.tryParse(_focusHours.text) ?? 0) * 60 +
          (int.tryParse(_focus.text) ?? 0)).toString();
      _restTotal.text = ((int.tryParse(_restHours.text) ?? 0) * 60 +
          (int.tryParse(_rest.text) ?? 0)).toString();
    }
    if (_end.text.isEmpty) {
      final local = ref.read(timeToolsClockProvider)()
          .add(Duration(seconds: p.remainingSeconds)).toLocal();
      _end.text = '${_timerPickerDate(local)} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}:'
          '${local.second.toString().padLeft(2, '0')}';
    }
    var invalid = false, invalidEnd = false, submitted = false;
    var advanced = endTime;
    _panelOpen = true;
    unawaited(_openTimerPanel(context, (dialogContext) => Consumer(
      builder: (context, panelRef, _) {
        final allowed = panelRef.watch(timeToolsProvider.select((v) => v.canEdit));
        return StatefulBuilder(
        builder: (context, update) {
          bool ready() => !submitted && mounted && dialogContext.mounted &&
              ref.read(timeToolsProvider).canEdit;
          void finish(bool ok, {bool ending = false}) {
            if (ok) {
              submitted = true;
              Navigator.of(dialogContext).pop();
            } else {
              update(() {
                if (ending) invalidEnd = true; else invalid = true;
              });
            }
          }
          void save() {
            if (!ready()) return;
            final focus = pomodoroSeconds(_focusHours.text, _focus.text, _focusSeconds.text);
            final rest = pomodoroSeconds(_restHours.text, _rest.text, _restSeconds.text);
            finish(focus != null && rest != null &&
                ref.read(timeToolsProvider.notifier).configurePomodoroSeconds(focus, rest));
          }
          void applyEnd() {
            if (!ready()) return;
            final target = parseLocalCountdown(_end.text);
            finish(target != null &&
                ref.read(timeToolsProvider.notifier).configurePomodoroEnd(target), ending: true);
          }
          void fromBasic(String text, TextEditingController hours,
              TextEditingController minutes) {
            final value = RegExp(r'^[0-9]+$').hasMatch(text) ? int.tryParse(text) : null;
            hours.text = value == null ? '0' : (value ~/ 60).toString();
            minutes.text = value == null ? text : (value % 60).toString();
            // The seconds controller is deliberately untouched.
            update(() {});
          }
          void fromAdvanced(TextEditingController total, TextEditingController hours,
              TextEditingController minutes) {
            final h = int.tryParse(hours.text), m = int.tryParse(minutes.text);
            total.text = h == null || m == null ? '' : (h * 60 + m).toString();
            update(() {});
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('番茄钟设置', style: Theme.of(context).textTheme.titleMedium),
              const Text('专注与休息：1至180分钟，保留秒数。修改会中断本轮，之后须手动开始。'),
              const _ToolStatus(),
              TextField(
                key: const Key('pomodoro_focus_total_minutes'),
                controller: _focusTotal, enabled: allowed,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '专注（分钟）'),
                onChanged: (text) => fromBasic(text, _focusHours, _focus),
                onSubmitted: (_) => save(),
              ),
              TextField(
                key: const Key('pomodoro_rest_total_minutes'),
                controller: _restTotal, enabled: allowed,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '休息（分钟）'),
                onChanged: (text) => fromBasic(text, _restHours, _rest),
                onSubmitted: (_) => save(),
              ),
              Text('秒数保留：专注 ${_focusSeconds.text} 秒，休息 ${_restSeconds.text} 秒'),
              if (invalid) Text('请输入合法时间，范围为60至10800秒',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
              Wrap(spacing: MaterialTokens.spaceSm, children: [
                _ToolButton(label: '保存时长', primary: true,
                  actionKey: 'pomodoro_save_config', onPressed: allowed ? save : null),
                _ToolButton(label: '取消', actionKey: 'pomodoro_cancel_config',
                  onPressed: () => Navigator.of(dialogContext).pop()),
              ]),
              Semantics(expanded: advanced, child: MaterialActionButton(
                buttonKey: const Key('pomodoro_advanced'),
                focusNode: _advancedFocus,
                role: MaterialActionRole.auxiliary,
                onPressed: () {
                  if (advanced && _advancedScope.hasFocus) _advancedFocus.requestFocus();
                  update(() => advanced = !advanced);
                },
                child: Text(advanced ? '收起高级设置' : '高级：时分秒与结束时间'),
              )),
              Visibility(
                visible: advanced, maintainState: true,
                child: ExcludeFocus(excluding: !advanced,
                  child: ExcludeSemantics(excluding: !advanced,
                    child: TickerMode(enabled: advanced,
                      child: FocusScope(node: _advancedScope,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _DurationFields(label: '专注', prefix: 'pomodoro_focus',
                              hours: _focusHours, minutes: _focus, seconds: _focusSeconds,
                              enabled: allowed, onSubmit: save,
                              onChanged: () => fromAdvanced(_focusTotal, _focusHours, _focus)),
                            _DurationFields(label: '休息', prefix: 'pomodoro_rest',
                              hours: _restHours, minutes: _rest, seconds: _restSeconds,
                              enabled: allowed, onSubmit: save,
                              onChanged: () => fromAdvanced(_restTotal, _restHours, _rest)),
                            const Text('本轮结束时间单独应用，不随保存时长提交。'),
                            _TimerDateTimeInput(fieldKey: 'pomodoro_end_target',
                              prefix: 'pomodoro_end', controller: _end,
                              ownerAlive: () => mounted, onSubmit: applyEnd),
                            if (invalidEnd) Text('请输入合法时间，范围为60至10800秒',
                              style: TextStyle(color: Theme.of(context).colorScheme.error)),
                            _ToolButton(label: '应用本轮结束时间',
                              actionKey: 'pomodoro_apply_end',
                              onPressed: allowed ? applyEnd : null),
                            _ToolButton(label: '重置', actionKey: 'pomodoro_reset',
                              onPressed: allowed ? () {
                                if (!ready()) return;
                                finish(ref.read(timeToolsProvider.notifier).resetPomodoro());
                              } : null),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        );
      },
    )).whenComplete(() => _panelOpen = false));
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(timeToolsProvider), p = view.data.pomodoro;
    final notifier = ref.read(timeToolsProvider.notifier);
    return _ClockView(
      builder: (context, now) => _TimerFace(
        title: '番茄钟 · ' + (p.phase == PomodoroPhase.focus ? '专注' : '休息'),
        remainingKey: 'pomodoro_remaining',
        remaining: p.remaining(now) == 0 ? '本轮完成' : _duration(p.remaining(now)),
        detail: p.completed ? '下一阶段待开始' : '专注与休息由你主动开始',
        onEdit: view.canEdit ? () => _edit() : null,
        onEndEdit: view.canEdit ? () => _edit(endTime: true) : null,
        endText: p.running
            ? _localText(p.deadlineUtc!, seconds: true)
            : '预计 ${_localText(now.add(Duration(seconds: p.remainingSeconds)), seconds: true)}',
        historyKind: TimeSessionKind.pomodoro,
        actions: [
          _TimerAction(
            label: p.running
                ? '暂停'
                : p.completed
                ? '下一阶段'
                : view.data.activeSession(TimeSessionKind.pomodoro)?.status ==
                    TimeSessionStatus.paused
                ? '继续'
                : '开始',
            actionKey: 'pomodoro_start_pause',
            primary: true,
            icon: p.running ? Icons.pause : Icons.play_arrow,
            onPressed: view.canEdit
                ? () {
                    p.running
                        ? notifier.pausePomodoro()
                        : notifier.startPomodoro();
                  }
                : null,
          ),
          _TimerAction(
            label: '重置',
            actionKey: 'pomodoro_reset',
            icon: Icons.restart_alt,
            onPressed: view.canEdit ? () => notifier.resetPomodoro() : null,
          ),
          _TimerAction(
            label: '设置时长',
            actionKey: 'pomodoro_configure',
            icon: Icons.tune,
            onPressed: view.canEdit ? () => _edit() : null,
          ),
        ],
      ),
    );
  }
}

class _DurationFields extends StatelessWidget {
  const _DurationFields({
    required this.label,
    required this.prefix,
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.onSubmit,
    this.onChanged,
    this.enabled = true,
  });
  final String label, prefix;
  final TextEditingController hours, minutes, seconds;
  final VoidCallback onSubmit;
  final VoidCallback? onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      Row(
        children: [
          for (final (part, controller) in [
            ('hours', hours),
            ('minutes', minutes),
            ('seconds', seconds),
          ]) ...[
            if (part != 'hours') const SizedBox(width: MaterialTokens.spaceXs),
            Expanded(
              child: TextField(
                key: Key('${prefix}_$part'),
                controller: controller,
                enabled: enabled,
                onChanged: (_) => onChanged?.call(),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => onSubmit(),
                decoration: InputDecoration(
                  labelText: switch (part) {
                    'hours' => '时',
                    'minutes' => '分',
                    _ => '秒',
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    ],
  );
}

Future<void> _openToolPanel(BuildContext context, WidgetBuilder builder) {
  final capture = MaterialOverlayCapture.of(context);
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: MaterialTransientPanel(
        capture: capture,
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// Clock glyphs may shrink; text actions and their 48dp targets never do.
class _TimerAction extends StatelessWidget {
  const _TimerAction({
    required this.label, required this.actionKey, required this.icon,
    this.primary = false, this.onPressed,
  });
  final String label, actionKey;
  final IconData icon;
  final bool primary;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => MaterialActionButton(
    buttonKey: Key(actionKey),
    role: primary ? MaterialActionRole.primary : MaterialActionRole.secondary,
    onPressed: onPressed, child: Text(label),
  );
}

class _TimerFace extends ConsumerWidget {
  const _TimerFace({
    required this.title, required this.remaining, required this.remainingKey,
    required this.detail, required this.actions, this.onEdit, this.onEndEdit,
    this.endText = '目标时间', required this.historyKind,
  });
  final String title, remaining, remainingKey, detail, endText;
  final List<_TimerAction> actions;
  final VoidCallback? onEdit, onEndEdit;
  final TimeSessionKind historyKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(timeToolsProvider);
    final primary = actions.where((action) => action.primary).firstOrNull;
    final moreLabel = view.blocked || view.error != null
        ? '错误' : !view.loaded || view.loading
        ? '读取' : '更多';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MaterialTokens.spaceSm),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: materialControlTarget, width: double.infinity,
            child: Semantics(
              label: '$title，$detail，修改时间',
              child: MaterialActionButton(
                buttonKey: Key(historyKind == TimeSessionKind.countdown
                    ? 'countdown_edit' : remainingKey + '_edit'),
                onPressed: onEdit, role: MaterialActionRole.secondary,
                padding: EdgeInsets.zero,
                child: Stack(alignment: Alignment.center, children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MaterialTokens.spaceLg),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(remaining, key: Key(remainingKey),
                        style: Theme.of(context).textTheme.headlineMedium),
                    ),
                  ),
                  const Align(alignment: Alignment.centerRight,
                    child: Icon(Icons.edit_outlined, size: 20)),
                ]),
              ),
            ),
          ),
          if (primary != null) Center(child: primary),
          Row(children: [
            Expanded(
              child: MaterialActionButton(
                buttonKey: Key(historyKind == TimeSessionKind.pomodoro
                    ? 'pomodoro_configure' : historyKind.name + '_more'),
                padding: const EdgeInsets.symmetric(
                  horizontal: MaterialTokens.spaceXs),
                onPressed: historyKind == TimeSessionKind.pomodoro
                    ? onEdit
                    : () => unawaited(_openTimerPanel(context,
                      (panelContext) => _TimerDetails(
                        title: title, detail: detail, endText: endText,
                        endKey: remainingKey + '_end', onEndEdit: onEndEdit,
                        actions: actions.where((action) => !action.primary).toList(),
                      ))),
                child: Text(historyKind == TimeSessionKind.pomodoro ? '设置' : moreLabel),
              ),
            ),
            const SizedBox(width: MaterialTokens.spaceSm),
            Expanded(
              child: MaterialActionButton(
                buttonKey: Key(historyKind.name + '_history'),
                padding: const EdgeInsets.symmetric(
                  horizontal: MaterialTokens.spaceXs),
                onPressed: () => context.push(timeSessionHistoryLocation(historyKind)),
                child: const Text('记录'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Complete text and secondary actions remain reachable without crowding face.
class _TimerDetails extends ConsumerWidget {
  const _TimerDetails({
    required this.title, required this.detail, required this.endText,
    required this.endKey, required this.actions, this.onEndEdit,
  });
  final String title, detail, endText, endKey;
  final List<_TimerAction> actions;
  final VoidCallback? onEndEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(timeToolsProvider.select((view) => view.canEdit));
    return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      Text(detail),
      const _ToolStatus(),
      MaterialActionButton(
        buttonKey: Key(endKey),
        onPressed: onEndEdit == null || !canEdit ? null : () {
          Navigator.of(context).pop();
          onEndEdit!();
        },
        child: Text('结束时间：$endText'),
      ),
      Wrap(spacing: MaterialTokens.spaceSm,
        runSpacing: MaterialTokens.spaceSm, children: [
          for (final action in actions)
            _TimerAction(
              label: action.label, actionKey: action.actionKey, icon: action.icon,
              primary: action.primary,
              onPressed: action.onPressed == null || !canEdit ? null : () {
                Navigator.of(context).pop();
                action.onPressed!();
              },
            ),
        ]),
      MaterialActionButton(
        buttonKey: const Key('timer_details_close'),
        role: MaterialActionRole.auxiliary,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('返回计时'),
      ),
    ],
  );
  }
}

Future<void> _openTimerPanel(BuildContext context, WidgetBuilder builder) {
  final capture = MaterialOverlayCapture.of(context);
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero : const Duration(milliseconds: 180);
  return showGeneralDialog<void>(
    context: context, barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: duration,
    pageBuilder: (context, _, __) => Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent, elevation: 0,
      child: MaterialTransientPanel(
        capture: capture, child: Builder(builder: builder),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)), child: child,
    ),
  );
}

String _timerPickerDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Date and clock choices edit a draft only, retaining seconds and cancellation.
class _TimerDateTimeInput extends ConsumerWidget {
  const _TimerDateTimeInput({
    required this.fieldKey, required this.prefix, required this.controller,
    required this.ownerAlive, this.onSubmit,
  });
  final String fieldKey, prefix;
  final TextEditingController controller;
  final bool Function() ownerAlive;
  final VoidCallback? onSubmit;

  Future<void> _pick(BuildContext context, WidgetRef ref, {required bool date}) async {
    final old = parseLocalCountdown(controller.text) ??
        ref.read(timeToolsClockProvider)().toLocal();
    final original = controller.text;
    final DateTime? selectedDate;
    final TimeOfDay? selectedTime;
    if (date) {
      selectedDate = await showDatePicker(
        context: context, initialDate: old,
        firstDate: DateTime(1), lastDate: DateTime(9999, 12, 31),
      );
      selectedTime = null;
      if (selectedDate == null) return;
    } else {
      selectedTime = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(old),
      );
      selectedDate = null;
      if (selectedTime == null) return;
    }
    if (!context.mounted || !ownerAlive() ||
        !ref.read(timeToolsProvider).canEdit || controller.text != original) return;
    final value = selectedDate != null
        ? '${_timerPickerDate(selectedDate)} '
            '${old.hour.toString().padLeft(2, '0')}:'
            '${old.minute.toString().padLeft(2, '0')}:'
            '${old.second.toString().padLeft(2, '0')}'
        : '${_timerPickerDate(old)} '
            '${selectedTime!.hour.toString().padLeft(2, '0')}:'
            '${selectedTime.minute.toString().padLeft(2, '0')}:'
            '${old.second.toString().padLeft(2, '0')}';
    // Strict parser rejects normalization of invalid local dates/DST.
    if (parseLocalCountdown(value) != null) controller.text = value;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(timeToolsProvider.select((view) => view.canEdit));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(key: Key(fieldKey), controller: controller,
        enabled: allowed, onSubmitted: (_) => onSubmit?.call(),
        decoration: const InputDecoration(
          labelText: '本地日期时间', hintText: 'YYYY-MM-DD HH:mm:ss')),
      Wrap(spacing: MaterialTokens.spaceSm, children: [
        MaterialActionButton(buttonKey: Key(prefix + '_date_picker'),
          onPressed: allowed ? () => _pick(context, ref, date: true) : null,
          child: const Text('日期')),
        MaterialActionButton(buttonKey: Key(prefix + '_time_picker'),
          onPressed: allowed ? () => _pick(context, ref, date: false) : null,
          child: const Text('时分')),
      ]),
    ]);
  }
}

class TasksWidget extends ConsumerStatefulWidget {
  const TasksWidget({super.key});
  @override
  ConsumerState<TasksWidget> createState() => _TasksWidgetState();
}

class _TasksWidgetState extends ConsumerState<TasksWidget> {
  final _input = TextEditingController(), _due = TextEditingController();
  final _editingIds = <String>{};
  bool _invalid = false,
      _adding = false,
      _completedExpanded = false,
      _pendingExpanded = true;
  void _add(TimeToolsNotifier notifier) {
    final due = _due.text.trim().isEmpty
        ? null
        : parseLocalCountdown(_due.text);
    final ok =
        (_due.text.trim().isEmpty || due != null) &&
        notifier.addTask(_input.text, dueAtUtc: due?.toUtc());
    setState(() {
      _invalid = !ok;
      if (ok) {
        _input.clear();
        _due.clear();
        _adding = false;
      }
    });
  }

  Future<void> _confirmDelete(TimeTask task) async {
    final id = task.id, text = task.text;
    var confirmed = false;
    await _openToolPanel(
      context,
      (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final current = ref.watch(timeToolsProvider);
          final allowed =
              current.canEdit && current.data.tasks.any((t) => t.id == id);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('删除任务？', style: Theme.of(context).textTheme.titleMedium),
              Text(text, key: Key('task_delete_text_' + id)),
              Text('任务 ID：' + id, style: Theme.of(context).textTheme.bodySmall),
              if (!allowed) const Text('任务已改变或暂时不可编辑，本次未删除'),
              Wrap(
                children: [
                  MaterialActionButton(
                    buttonKey: Key('task_delete_cancel_' + id),
                    autofocus: true,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  MaterialActionButton(
                    buttonKey: Key('task_delete_confirm_' + id),
                    role: MaterialActionRole.destructive,
                    onPressed: allowed
                        ? () {
                            if (confirmed || !mounted || !dialogContext.mounted)
                              return;
                            final latest = ref.read(timeToolsProvider);
                            if (!latest.canEdit ||
                                !latest.data.tasks.any((t) => t.id == id))
                              return;
                            confirmed = true;
                            if (ref
                                .read(timeToolsProvider.notifier)
                                .deleteTask(id)) {
                              setState(() => _editingIds.remove(id));
                              Navigator.of(dialogContext).pop();
                            }
                          }
                        : null,
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _due.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(timeToolsProvider);
    final notifier = ref.read(timeToolsProvider.notifier);
    final pending = view.data.tasks.where((task) => !task.done).toList();
    final completed = view.data.tasks.where((task) => task.done).toList();
    final shownPending = pending
        .where((task) => _pendingExpanded || _editingIds.contains(task.id))
        .toList();
    final shownCompleted = completed
        .where((task) => _completedExpanded || _editingIds.contains(task.id))
        .toList();
    final prefix = <Widget>[
      Column(
        key: const ValueKey('tasks_heading'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '任务清单',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _ToolIcon(
                label: '添加任务',
                actionKey: 'time_task_open_add',
                icon: Icons.add,
                onPressed: view.canEdit
                    ? () => setState(() => _adding = !_adding)
                    : null,
              ),
            ],
          ),
          const _TaskSaveStatus(),
          if (view.data.tasks.isNotEmpty)
            Text(
              completed.length.toString() +
                  ' / ' +
                  view.data.tasks.length.toString() +
                  ' 已完成',
            ),
        ],
      ),
      if (_adding)
        _TaskForm(
          key: const ValueKey('tasks_add_form'),
          children: [
            TextField(
              key: const Key('time_task_input'),
              controller: _input,
              enabled: view.canEdit,
              maxLength: 2000,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: '新任务',
                errorText: _invalid ? '请输入任务内容及有效的可选时间' : null,
              ),
              onSubmitted: (_) => _add(notifier),
            ),
            _TaskDueField(
              controller: _due,
              fieldKey: 'time_task_due',
              enabled: view.canEdit,
            ),
            Wrap(
              children: [
                _ToolButton(
                  label: '添加任务',
                  actionKey: 'time_task_add',
                  onPressed: view.canEdit ? () => _add(notifier) : null,
                ),
                _ToolButton(
                  label: '取消',
                  actionKey: 'time_task_cancel_add',
                  onPressed: () => setState(() => _adding = false),
                ),
              ],
            ),
          ],
        ),
      if (view.data.tasks.isEmpty && !_adding)
        Column(
          key: const ValueKey('tasks_empty'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('还没有任务'),
            const Text('例如：读完一章书。可选预计完成时间，示例不会加入清单。'),
            _ToolButton(
              label: '添加第一件任务',
              actionKey: 'time_task_empty_add',
              onPressed: view.canEdit
                  ? () => setState(() => _adding = true)
                  : null,
            ),
          ],
        ),
      if (view.data.tasks.isNotEmpty)
        MergeSemantics(
          key: const ValueKey('tasks_pending_group'),
          child: Semantics(
            expanded: _pendingExpanded,
            child: TextButton(
              key: const ValueKey('tasks_pending_heading'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () =>
                  setState(() => _pendingExpanded = !_pendingExpanded),
              child: Row(
                children: [
                  Icon(
                    _pendingExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                  ),
                  const SizedBox(width: MaterialTokens.spaceXs),
                  Expanded(child: Text('待完成 × ' + pending.length.toString())),
                ],
              ),
            ),
            key: const ValueKey('tasks_pending_semantics'),
          ),
        ),
    ];
    final completedHeader = MergeSemantics(
      key: const ValueKey('tasks_completed_group'),
      child: Semantics(
        key: const ValueKey('tasks_completed_semantics'),
        expanded: _completedExpanded,
        child: TextButton(
          key: const ValueKey('tasks_completed_heading'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () =>
              setState(() => _completedExpanded = !_completedExpanded),
          child: Row(
            children: [
              Icon(
                _completedExpanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
              const SizedBox(width: MaterialTokens.spaceXs),
              Expanded(child: Text('已完成 × ' + completed.length.toString())),
            ],
          ),
        ),
      ),
    );
    final keys = <Key>[
      for (final child in prefix) child.key!,
      for (final task in shownPending) ValueKey(('task', task.id)),
      if (view.data.tasks.isNotEmpty) completedHeader.key!,
      for (final task in shownCompleted) ValueKey(('task', task.id)),
    ];
    Widget row(TimeTask task) => _TaskRow(
      key: ValueKey(('task', task.id)),
      task: task,
      enabled: view.canEdit,
      onDelete: () => unawaited(_confirmDelete(task)),
      onEditingChanged: (editing) => setState(() {
        if (editing) {
          _editingIds.add(task.id);
        } else {
          _editingIds.remove(task.id);
        }
      }),
    );
    return ListView.builder(
      primary: false,
      padding: const EdgeInsets.all(MaterialTokens.spaceMd),
      itemCount: keys.length,
      findChildIndexCallback: (key) {
        final index = keys.indexOf(key);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) {
        if (index < prefix.length) return prefix[index];
        var offset = index - prefix.length;
        if (offset < shownPending.length) return row(shownPending[offset]);
        offset -= shownPending.length;
        if (offset == 0) return completedHeader;
        return row(shownCompleted[offset - 1]);
      },
    );
  }
}

class _TaskRow extends ConsumerStatefulWidget {
  const _TaskRow({
    required this.task,
    required this.enabled,
    required this.onDelete,
    required this.onEditingChanged,
    super.key,
  });
  final TimeTask task;
  final bool enabled;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEditingChanged;
  @override
  ConsumerState<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends ConsumerState<_TaskRow>
    with AutomaticKeepAliveClientMixin<_TaskRow> {
  final _input = TextEditingController(), _due = TextEditingController();
  bool _editing = false, _invalid = false;
  @override
  bool get wantKeepAlive => _editing;
  void _setEditing(bool editing) {
    setState(() => _editing = editing);
    updateKeepAlive();
    widget.onEditingChanged(editing);
  }

  @override
  void dispose() {
    _input.dispose();
    _due.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final notifier = ref.read(timeToolsProvider.notifier);
    if (_editing)
      return _TaskForm(
        children: [
          TextField(
            key: ValueKey('task_edit_input_' + widget.task.id),
            controller: _input,
            enabled: widget.enabled,
            maxLength: 2000,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: '编辑任务',
              errorText: _invalid ? '请输入任务内容及有效的可选时间' : null,
            ),
          ),
          _TaskDueField(
            controller: _due,
            fieldKey: 'task_due_' + widget.task.id,
            enabled: widget.enabled,
          ),
          Wrap(
            children: [
              _ToolButton(
                label: '保存任务',
                actionKey: 'task_save_' + widget.task.id,
                onPressed: widget.enabled
                    ? () {
                        final due = _due.text.trim().isEmpty
                            ? null
                            : parseLocalCountdown(_due.text);
                        final ok =
                            (_due.text.trim().isEmpty || due != null) &&
                            notifier.editTask(
                              widget.task.id,
                              _input.text,
                              dueAtUtc: due?.toUtc(),
                              clearDue: _due.text.trim().isEmpty,
                            );
                        setState(() => _invalid = !ok);
                        if (ok) _setEditing(false);
                      }
                    : null,
              ),
              _ToolButton(
                label: '取消',
                actionKey: 'task_cancel_' + widget.task.id,
                onPressed: () => _setEditing(false),
              ),
            ],
          ),
        ],
      );
    final toggle = SizedBox(
      width: 48,
      height: 48,
      child: Checkbox(
        key: ValueKey('task_toggle_' + widget.task.id),
        value: widget.task.done,
        semanticLabel: widget.task.text,
        onChanged: widget.enabled
            ? (_) => notifier.toggleTask(widget.task.id)
            : null,
      ),
    );
    final description = Padding(
      padding: const EdgeInsets.symmetric(vertical: MaterialTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.task.text,
            style: TextStyle(
              decoration: widget.task.done ? TextDecoration.lineThrough : null,
            ),
          ),
          Text(
            widget.task.createdAtUtc == null
                ? '添加时间：未记录'
                : '添加：' + _localText(widget.task.createdAtUtc!),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (widget.task.dueAtUtc != null)
            Text(
              (widget.task.dueAtUtc!.isAfter(
                        ref.watch(timeToolsClockProvider)().toUtc(),
                      )
                      ? '预计：'
                      : '预计已到期：') +
                  _localText(widget.task.dueAtUtc!),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
    final actions = Wrap(
      children: [
        _ToolIcon(
          label: '编辑任务',
          actionKey: 'task_edit_' + widget.task.id,
          icon: Icons.edit_outlined,
          onPressed: widget.enabled
              ? () {
                  _input.text = widget.task.text;
                  _due.text = widget.task.dueAtUtc == null
                      ? ''
                      : _localText(widget.task.dueAtUtc!);
                  _setEditing(true);
                }
              : null,
        ),
        _ToolIcon(
          label: '删除任务',
          actionKey: 'task_delete_' + widget.task.id,
          icon: Icons.delete_outline,
          onPressed: widget.enabled ? widget.onDelete : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            toggle,
            Expanded(child: description),
          ],
        );
        if (constraints.maxWidth < 280) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              description,
              Row(children: [toggle, const Spacer(), actions]),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            actions,
          ],
        );
      },
    );
  }
}

class _TaskForm extends StatelessWidget {
  const _TaskForm({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

class _TaskDueField extends StatefulWidget {
  const _TaskDueField({
    required this.controller,
    required this.fieldKey,
    required this.enabled,
  });
  final TextEditingController controller;
  final String fieldKey;
  final bool enabled;
  @override
  State<_TaskDueField> createState() => _TaskDueFieldState();
}

class _TaskDueFieldState extends State<_TaskDueField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _ToolButton(
        label: widget.controller.text.isEmpty
            ? '设置预计时间'
            : widget.controller.text,
        actionKey: widget.fieldKey,
        onPressed: widget.enabled
            ? () => unawaited(
                _openToolPanel(
                  context,
                  (_) => _DuePicker(
                    controller: widget.controller,
                    fieldKey: widget.fieldKey,
                    ownerAlive: () => mounted,
                  ),
                ),
              )
            : null,
      ),
      _ToolIcon(
        label: '清除预计完成时间',
        actionKey: widget.fieldKey + '_clear',
        icon: Icons.clear,
        onPressed: widget.enabled ? widget.controller.clear : null,
      ),
    ],
  );
}

class _DuePicker extends ConsumerStatefulWidget {
  const _DuePicker({
    required this.controller,
    required this.fieldKey,
    required this.ownerAlive,
  });
  final TextEditingController controller;
  final String fieldKey;
  final bool Function() ownerAlive;
  @override
  ConsumerState<_DuePicker> createState() => _DuePickerState();
}

class _DuePickerState extends ConsumerState<_DuePicker> {
  final _date = TextEditingController(),
      _hour = TextEditingController(),
      _minute = TextEditingController();
  bool _timeStep = false, _invalid = false;
  late DateTime _selected;
  @override
  void initState() {
    super.initState();
    final old = parseLocalCountdown(widget.controller.text);
    _selected = old ?? ref.read(timeToolsClockProvider)().toLocal();
    _date.text = _localText(_selected).split(' ').first;
    if (old != null) {
      _hour.text = old.hour.toString();
      _minute.text = old.minute.toString();
    }
  }

  @override
  void dispose() {
    _date.dispose();
    _hour.dispose();
    _minute.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _timeStep ? '选择时间' : '选择日期',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (!_timeStep) ...[
        TextField(
          key: Key(widget.fieldKey + '_date'),
          controller: _date,
          decoration: const InputDecoration(
            labelText: '日期',
            hintText: 'YYYY-MM-DD',
          ),
        ),
        CalendarDatePicker(
          currentDate: ref.read(timeToolsClockProvider)().toLocal(),
          initialDate: _selected,
          firstDate: DateTime(1),
          lastDate: DateTime(9999, 12, 31),
          onDateChanged: (date) {
            _selected = date;
            _date.text = _localText(date).split(' ').first;
          },
        ),
      ] else ...[
        TextField(
          key: Key(widget.fieldKey + '_hours'),
          controller: _hour,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '时（0–23）'),
        ),
        TextField(
          key: Key(widget.fieldKey + '_minutes'),
          controller: _minute,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '分（0–59）'),
        ),
      ],
      if (_invalid) const Text('请输入有效日期和明确的时、分，未修改预计时间'),
      Wrap(
        children: [
          _ToolButton(
            label: _timeStep ? '确认时间' : '下一步',
            primary: true,
            actionKey: widget.fieldKey + (_timeStep ? '_confirm' : '_next'),
            onPressed: () {
              final date = parseLocalCountdown(_date.text.trim() + ' 12:00');
              final numeric = RegExp(r'^[0-9]{1,2}$');
              final hour = numeric.hasMatch(_hour.text)
                  ? int.tryParse(_hour.text)
                  : null;
              final minute = numeric.hasMatch(_minute.text)
                  ? int.tryParse(_minute.text)
                  : null;
              if (date == null ||
                  _timeStep &&
                      (hour == null ||
                          hour > 23 ||
                          minute == null ||
                          minute > 59)) {
                setState(() => _invalid = true);
                return;
              }
              if (!_timeStep) {
                setState(() {
                  _timeStep = true;
                  _invalid = false;
                });
                return;
              }
              final result = DateTime(
                date.year,
                date.month,
                date.day,
                hour!,
                minute!,
              );
              if (!widget.ownerAlive() || !ref.read(timeToolsProvider).canEdit)
                return;
              widget.controller.text = _localText(result);
              Navigator.of(context).pop();
            },
          ),
          _ToolButton(
            label: '取消',
            actionKey: widget.fieldKey + '_cancel',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ],
  );
}

class CountdownWidget extends ConsumerStatefulWidget {
  const CountdownWidget({super.key});
  @override
  ConsumerState<CountdownWidget> createState() => _CountdownWidgetState();
}

class _CountdownWidgetState extends ConsumerState<CountdownWidget> {
  void _editTarget() {
    final view = ref.read(timeToolsProvider);
    if (_panelOpen || !view.canEdit) return;
    final countdown = view.data.countdown;
    final notifier = ref.read(timeToolsProvider.notifier);

    if (!_initialized) {
      _title.text = countdown?.title ?? '';
      _target.text = _localText(
        countdown?.targetUtc ??
            ref.read(timeToolsClockProvider)().add(const Duration(days: 1)),
        seconds: true,
      );
      _initialized = true;
    }
    var invalid = false, submitted = false;
    _panelOpen = true;
    unawaited(
      _openTimerPanel(
        context,
        (context) => StatefulBuilder(
          builder: (context, update) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('倒计时目标', style: Theme.of(context).textTheme.titleMedium),
              const _ToolStatus(),
              TextField(
                key: const Key('countdown_title'),
                controller: _title,
                maxLength: 2000,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              _TimerDateTimeInput(
                fieldKey: 'countdown_target', prefix: 'countdown',
                controller: _target, ownerAlive: () => mounted,
              ),
              if (invalid) const Text('请输入标题及有效的本地日期时间'),
              Wrap(
                children: [
                  _ToolButton(
                    label: '保存目标',
                    primary: true,
                    actionKey: 'countdown_save',
                    onPressed: () {
                      if (submitted || !mounted || !context.mounted ||
                          !ref.read(timeToolsProvider).canEdit) return;
                      final date = parseLocalCountdown(_target.text);
                      final ok =
                          date != null &&
                          notifier.setCountdown(_title.text, date);
                      if (ok && mounted) {
                        submitted = true;
                        _initialized = false;
                        Navigator.of(context).pop();
                      } else {
                        update(() => invalid = true);
                      }
                    },
                  ),
                  _ToolButton(
                    label: '取消',
                    actionKey: 'countdown_cancel',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ).whenComplete(() => _panelOpen = false),
    );
  }

  final _title = TextEditingController(), _target = TextEditingController();
  bool _initialized = false, _panelOpen = false;
  @override
  void dispose() {
    _title.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(timeToolsProvider), countdown = view.data.countdown;
    return _ClockView(
      builder: (context, now) => _TimerFace(
        historyKind: TimeSessionKind.countdown,
        onEdit: view.canEdit ? () => _editTarget() : null,
        onEndEdit: view.canEdit ? () => _editTarget() : null,
        endText: countdown == null ? '目标时间' : _localText(countdown.targetUtc),
        title: countdown?.title ?? '倒计时',
        remainingKey: 'countdown_remaining',
        remaining: countdown == null
            ? '--:--'
            : countdown.expired(now)
            ? '已到期'
            : '剩余 ' +
                  _duration(
                    countdown.targetUtc
                        .difference(now.toUtc())
                        .inSeconds
                        .clamp(0, 1 << 31),
                  ),
        detail: countdown == null
            ? '设置一个目标日期与时间'
            : '本地时间 ' + _localText(countdown.targetUtc),
        actions: [
          _TimerAction(
            label: countdown == null ? '设置目标' : '修改目标',
            actionKey: 'countdown_set_target', icon: Icons.edit_calendar,
            primary: true,
            onPressed: view.canEdit ? () => _editTarget() : null,
          ),
        ],
      ),
    );
  }
}
