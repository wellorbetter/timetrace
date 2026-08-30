import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_glass_surface.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_timeline_view.dart';

@Preview(name: 'Nowline · 浅色桌面', size: Size(760, 360))
Widget nowlineLightPreview() => _NowlinePreview(
  theme: TimetraceTheme.light(),
  preferences: const NowlinePreferences(lineCount: 4),
);

@Preview(name: 'Nowline · 深色悬浮层', size: Size(540, 280))
Widget nowlineDarkCompactPreview() => _NowlinePreview(
  theme: TimetraceTheme.dark(),
  preferences: const NowlinePreferences(lineCount: 4, panelOpacity: 0.78),
  compact: true,
);

class _NowlinePreview extends StatelessWidget {
  const _NowlinePreview({
    required this.theme,
    required this.preferences,
    this.compact = false,
  });

  final ThemeData theme;
  final NowlinePreferences preferences;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.surface,
                    scheme.primaryContainer.withValues(alpha: 0.82),
                    scheme.tertiaryContainer.withValues(alpha: 0.72),
                  ],
                ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(TimeTraceSpace.lg),
                  child: NowlineGlassSurface(
                    role: NowlineGlassRole.functional,
                    opacity: preferences.panelOpacity,
                    blurSigma: 20,
                    shadow: true,
                    child: NowlineTimelineView(
                      timeline: _previewTimeline(),
                      preferences: preferences,
                      compact: compact,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

NowlineTimeline _previewTimeline() => NowlineTimeline(
  revision: 12,
  paused: false,
  lines: [
    NowlineLine(
      id: 1,
      text: '在 Terminal 里整理 Nowline 实时数据流',
      detail: '32 分钟 · 本地会话',
      startedAt: DateTime(2026, 8, 30, 9, 12),
      duration: const Duration(minutes: 32),
      isCurrent: false,
      isIdle: false,
    ),
    NowlineLine(
      id: 2,
      text: '回到 VS Code 调整桌面端玻璃边界',
      detail: '18 分钟 · feature/nowline-overlay',
      startedAt: DateTime(2026, 8, 30, 9, 44),
      duration: const Duration(minutes: 18),
      isCurrent: false,
      isIdle: false,
    ),
    NowlineLine(
      id: 3,
      text: '打开 Flutter Preview 检查深浅主题',
      detail: '6 分钟 · 可交互预览',
      startedAt: DateTime(2026, 8, 30, 10, 2),
      duration: const Duration(minutes: 6),
      isCurrent: false,
      isIdle: false,
    ),
    NowlineLine(
      id: 4,
      text: '正在对齐 AI Recap 的紧凑桌面风格',
      detail: '当前 · 不调用模型',
      startedAt: DateTime(2026, 8, 30, 10, 8),
      duration: const Duration(minutes: 4),
      isCurrent: true,
      isIdle: false,
    ),
  ],
);
