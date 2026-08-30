import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_glass_surface.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_timeline_view.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_mode_provider.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_provider.dart';
import 'package:window_manager/window_manager.dart';

class NowlineOverlay extends ConsumerWidget {
  const NowlineOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(nowlineModeProvider);
    final preferences =
        ref.watch(nowlinePreferencesProvider).value ??
        const NowlinePreferences();
    final timeline = ref.watch(nowlineTimelineProvider);

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        minimum: const EdgeInsets.all(TimeTraceSpace.sm),
        child: Semantics(
          label: 'Nowline 本地实时活动悬浮层',
          container: true,
          explicitChildNodes: true,
          child: NowlineGlassSurface(
            role: NowlineGlassRole.functional,
            opacity: preferences.panelOpacity,
            blurSigma: 22,
            shadow: true,
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.md,
              TimeTraceSpace.xs,
              TimeTraceSpace.sm,
              TimeTraceSpace.sm,
            ),
            child: Column(
              children: [
                _OverlayHeader(mode: mode),
                Divider(
                  height: TimeTraceSpace.xs,
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.78),
                ),
                Expanded(
                  child: timeline.when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: (error, _) => _OverlayError(error: error),
                    data: (value) => NowlineTimelineView(
                      timeline: value,
                      preferences: preferences,
                      compact: true,
                    ),
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

class _OverlayHeader extends ConsumerWidget {
  const _OverlayHeader({required this.mode});

  final NowlineModeState mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Row(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: TimeTraceSpace.xs),
                    Text(
                      'NOWLINE · LOCAL',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(width: TimeTraceSpace.sm),
                    Text(
                      mode.clickThrough ? '已锁定 · 从托盘解锁' : '拖动以摆放',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Tooltip(
            message: mode.clickThrough ? '解锁交互' : '锁定并允许点击穿透',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: mode.busy
                  ? null
                  : () => ref
                        .read(nowlineModeProvider.notifier)
                        .toggleClickThrough(),
              icon: Icon(
                mode.clickThrough
                    ? Icons.lock_outline_rounded
                    : Icons.lock_open_rounded,
                size: 17,
              ),
            ),
          ),
          Tooltip(
            message: '返回 TimeTrace',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: mode.busy
                  ? null
                  : () => ref.read(nowlineModeProvider.notifier).exit(),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverlayError extends ConsumerWidget {
  const _OverlayError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16),
          const SizedBox(width: TimeTraceSpace.xs),
          const Flexible(child: Text('实时活动暂时不可用')),
          TextButton(
            onPressed: () => ref.invalidate(nowlineTimelineProvider),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
