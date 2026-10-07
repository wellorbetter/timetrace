import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/material/material.dart';
import '../domain/time_tool_state.dart';
import '../providers/time_tools_provider.dart';

String timeSessionHistoryLocation(TimeSessionKind kind) =>
    '/dashboard/time-history/${kind.name}';

/// One factory is registered by production and used by pure navigation tests.
GoRoute createTimeSessionHistoryRoute() => GoRoute(
  path: 'time-history/:kind',
  pageBuilder: (context, state) {
    final raw = state.pathParameters['kind'];
    final kind = switch (raw) {
      'pomodoro' => TimeSessionKind.pomodoro,
      'countdown' => TimeSessionKind.countdown,
      _ => null,
    };
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return CustomTransitionPage<void>(
      key: state.pageKey,
      opaque: false,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .24),
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      child: kind == null
          ? const _UnavailableHistoryScreen()
          : TimeSessionHistoryScreen(kind: kind),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
            child: child,
          ),
    );
  },
);

void _back(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/dashboard');
  }
}

/// Only observes the existing owner. No clock, timer or navigation mutation.
class TimeSessionHistoryScreen extends ConsumerWidget {
  const TimeSessionHistoryScreen({required this.kind, super.key});
  final TimeSessionKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(timeToolsProvider);
    final sessions = view.data.sessions
        .where((session) => session.kind == kind)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    final title = kind == TimeSessionKind.pomodoro ? '番茄钟记录' : '倒计时记录';
    return _HistoryFrame(
      title: title,
      child: ListView.builder(
        key: const Key('time_history_list'),
        primary: false,
        itemCount: sessions.isEmpty ? 2 : sessions.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _HistoryStatus(view: view);
          if (sessions.isEmpty) {
            if (!view.loaded || view.loading || view.blocked || view.error != null) {
              return const Text('记录暂未确认，请完成读取或重试',
                key: Key('time_history_unloaded'));
            }
            return const Text('尚无记录，旧计时的开始时间未知，不追造历史',
              key: Key('time_history_empty'));
          }
          return _HistoryRecord(session: sessions[index - 1]);
        },
      ),
    );
  }
}

class _HistoryFrame extends StatelessWidget {
  const _HistoryFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final capture = MaterialOverlayCapture.of(context);
    final insets = MediaQuery.viewInsetsOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _back(context),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            () => _back(context),
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(MaterialTokens.spaceLg) + insets,
            child: LayoutBuilder(builder: (context, constraints) => Center(
              child: SizedBox(
                key: const Key('time_history_page'),
                width: math.min(560.0, constraints.maxWidth),
                height: math.min(480.0, constraints.maxHeight),
                child: MaterialTransientPanel(
                  capture: capture,
                  maxWidth: 560,
                  maxHeightFraction: 1,
                  scrollable: false,
                  padding: const EdgeInsets.all(MaterialTokens.spaceMd),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: MaterialTokens.spaceSm,
                        runSpacing: MaterialTokens.spaceSm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          MaterialActionButton(
                            buttonKey: const Key('time_history_back'),
                            role: MaterialActionRole.auxiliary,
                            onPressed: () => _back(context),
                            child: const Text('关闭'),
                          ),
                          Text(title, style: Theme.of(context).textTheme.titleLarge),
                        ],
                      ),
                      const SizedBox(height: MaterialTokens.spaceMd),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            )),
          ),
        ),
      ),
    );
  }
}

class _HistoryStatus extends ConsumerWidget {
  const _HistoryStatus({required this.view});
  final TimeToolsViewState view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(timeToolsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (view.loading)
          const Text('正在读取记录…', key: Key('time_history_loading')),
        if (view.blocked)
          const Text('读取受限，现有记录已保留，未覆盖原文件',
            key: Key('time_history_blocked')),
        if (view.error != null)
          Text(view.error!, key: const Key('time_history_error')),
        if (view.dirty)
          const Text('修改尚未保存到本机', key: Key('time_history_dirty')),
        if (view.blocked || view.error != null || !view.loaded && !view.loading)
          Align(
            alignment: Alignment.centerLeft,
            child: MaterialActionButton(
              buttonKey: const Key('time_history_reload'),
              onPressed: view.loading ? null : () => notifier.reload(),
              child: const Text('重试读取'),
            ),
          ),
        if (view.dirty)
          Align(
            alignment: Alignment.centerLeft,
            child: MaterialActionButton(
              buttonKey: const Key('time_history_retry_save'),
              onPressed: view.canEdit ? () => notifier.retrySave() : null,
              child: const Text('重试保存'),
            ),
          ),
        if (view.loading || view.blocked || view.error != null || view.dirty)
          const SizedBox(height: MaterialTokens.spaceSm),
      ],
    );
  }
}

class _HistoryRecord extends StatelessWidget {
  const _HistoryRecord({required this.session});
  final TimeSession session;

  @override
  Widget build(BuildContext context) {
    final status = switch (session.status) {
      TimeSessionStatus.active => '进行中',
      TimeSessionStatus.paused => '暂停',
      TimeSessionStatus.completed => '完成',
      TimeSessionStatus.interrupted => '中断',
      TimeSessionStatus.cancelled => '取消',
    };
    final phase = session.kind == TimeSessionKind.pomodoro
        ? '${session.phase == PomodoroPhase.focus ? '专注' : '休息'} · '
        : '';
    final effective = session.effectiveActiveSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MaterialTokens.spaceSm),
      child: Text(
        '$phase$status · ${_localText(session.startUtc)}\n'
        '结束：${session.endUtc == null ? '未结束' : _localText(session.endUtc!)}\n'
        '有效：${effective == null ? '未知（已知部分 ${session.knownMicroseconds ~/ 1000000} 秒）' : '$effective 秒'}',
        key: Key('time_session_${session.id}'),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

String _localText(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class _UnavailableHistoryScreen extends StatelessWidget {
  const _UnavailableHistoryScreen();

  @override
  Widget build(BuildContext context) => const _HistoryFrame(
    title: '记录不可用',
    child: Align(
      alignment: Alignment.topLeft,
      child: Text('此记录类型不存在，请返回工作台',
        key: Key('time_history_invalid_kind')),
    ),
  );
}
