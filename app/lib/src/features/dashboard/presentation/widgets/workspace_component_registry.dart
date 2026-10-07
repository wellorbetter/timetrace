import 'package:flutter/material.dart';

import '../../../../core/material/material.dart';
import '../../../../core/workspace/workspace_host.dart';
import '../../../../core/workspace/workspace_model.dart';
import '../../../time_tools/presentation/time_tool_widgets.dart';
import '../../providers/workspace_layout_provider.dart';
import 'daily_quote_line.dart';

typedef WorkspaceBusinessBuilder =
    Widget Function(BuildContext context, WorkspaceContentLayout layout);

List<WorkspaceSize> workspaceSupportedSizes(WorkspaceComponent component) =>
    switch (component) {
      WorkspaceComponent.diary => const [WorkspaceSize.fullNatural],
      WorkspaceComponent.pomodoro || WorkspaceComponent.countdown => const [
        WorkspaceSize.oneByOne,
        WorkspaceSize.twoByOne,
        WorkspaceSize.twoByTwo,
      ],
      WorkspaceComponent.tasks => const [
        WorkspaceSize.twoByTwo,
        WorkspaceSize.twoByThree,
        WorkspaceSize.fullNatural,
      ],
      WorkspaceComponent.dailyPoetry => const [
        WorkspaceSize.twoByOne,
        WorkspaceSize.twoByTwo,
        WorkspaceSize.twoByThree,
        WorkspaceSize.fullNatural,
      ],
      _ => const [WorkspaceSize.twoByTwo, WorkspaceSize.twoByThree],
    };

/// Builders are outside the core. Shelf/feedback never mount business widgets.
Map<String, WorkspaceDescriptor> createWorkspaceRegistry({
  Map<WorkspaceComponent, Widget> components = const {},
  Map<WorkspaceComponent, WorkspaceBusinessBuilder> builders = const {},
  bool includeTools = true,
}) => {
  for (final component in WorkspaceComponent.values)
    if (components.containsKey(component) ||
        builders.containsKey(component) ||
        includeTools && component.index >= WorkspaceComponent.pomodoro.index)
      component.name: WorkspaceDescriptor(
        id: component.name,
        label: component.label,
        defaultSize: component.defaultSize,
        supportedSizes: workspaceSupportedSizes(component),
        thumbnailBuilder: (_) => WorkspaceComponentMiniature(
          key: ValueKey('workspace_drag_preview_' + component.name),
          component: component,
        ),
        thumbnailForSize: (_, size) => WorkspaceComponentMiniature(
          key: ValueKey('workspace_drag_preview_' + component.name),
          component: component,
          size: size,
        ),
        contentBuilder: (context, layout) {
          final builder = builders[component];
          if (builder != null) return builder(context, layout);
          final supplied = components[component];
          if (supplied != null) return supplied;
          final content = switch (component) {
            WorkspaceComponent.pomodoro => const PomodoroWidget(),
            WorkspaceComponent.tasks => const TasksWidget(),
            WorkspaceComponent.countdown => const CountdownWidget(),
            WorkspaceComponent.dailyPoetry => WorkspacePoetryContent(
              layout: layout,
            ),
            _ => const SizedBox(),
          };
          return MaterialCard(margin: EdgeInsets.zero, child: content);
        },
      ),
};

class WorkspacePoetryContent extends StatelessWidget {
  const WorkspacePoetryContent({this.layout, super.key});
  final WorkspaceContentLayout? layout;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(MaterialTokens.spaceMd),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // The line owns its heading and budgets the real remaining body.
        return const DailyQuoteLine(heading: '每日诗词');
      },
    ),
  );
}

class WorkspaceComponentMiniature extends StatelessWidget {
  const WorkspaceComponentMiniature({
    required this.component,
    this.size,
    super.key,
  });
  final WorkspaceComponent component;
  final WorkspaceSize? size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? size != null
                  ? constraints.maxWidth
                  : constraints.maxWidth.clamp(0.0, 140.0)
            : 140.0;
        final height = size != null && constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.hasBoundedHeight
            ? (width * 92 / 140).clamp(0.0, constraints.maxHeight)
            : width * 92 / 140;
        return SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: _MiniaturePainter(
              component,
              Theme.of(context).colorScheme,
              MaterialScope.maybeOf(context)?.policy.contentSurface,
            ),
          ),
        );
      },
    ),
  );
}

class _MiniaturePainter extends CustomPainter {
  const _MiniaturePainter(this.component, this.colors, this.surface);
  final WorkspaceComponent component;
  final ColorScheme colors;
  final Color? surface;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 140, size.height / 92);
    final paint = Paint()..color = surface ?? colors.surface;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(2, 2, 136, 88),
        const Radius.circular(MaterialTokens.contentRadius),
      ),
      paint,
    );

    // Abstract composition only. Large neutral blocks and one accent identify
    // structure; no text, clock face, chart values or hidden content is painted.
    // The shared thumbnail frame supplies the persisted size's aspect ratio.
    final blocks = switch (component) {
      WorkspaceComponent.bar => const [
        Rect.fromLTWH(14, 28, 42, 50),
        Rect.fromLTWH(64, 28, 62, 50),
      ],
      WorkspaceComponent.hourly => const [
        Rect.fromLTWH(14, 28, 28, 50),
        Rect.fromLTWH(50, 28, 28, 50),
        Rect.fromLTWH(86, 28, 40, 50),
      ],
      WorkspaceComponent.calendar => const [
        Rect.fromLTWH(14, 28, 50, 22),
        Rect.fromLTWH(72, 28, 54, 22),
        Rect.fromLTWH(14, 58, 112, 20),
      ],
      WorkspaceComponent.summary => const [
        Rect.fromLTWH(14, 28, 50, 50),
        Rect.fromLTWH(72, 28, 54, 20),
        Rect.fromLTWH(72, 56, 54, 22),
      ],
      WorkspaceComponent.apps => const [
        Rect.fromLTWH(14, 28, 112, 12),
        Rect.fromLTWH(14, 48, 112, 12),
        Rect.fromLTWH(14, 68, 112, 10),
      ],
      WorkspaceComponent.diary => const [
        Rect.fromLTWH(14, 28, 112, 50),
      ],
      WorkspaceComponent.pomodoro => const [
        Rect.fromLTWH(14, 28, 76, 50),
        Rect.fromLTWH(98, 28, 28, 50),
      ],
      WorkspaceComponent.tasks => const [
        Rect.fromLTWH(14, 28, 24, 50),
        Rect.fromLTWH(46, 28, 80, 22),
        Rect.fromLTWH(46, 58, 80, 20),
      ],
      WorkspaceComponent.countdown => const [
        Rect.fromLTWH(14, 28, 112, 32),
        Rect.fromLTWH(14, 68, 112, 10),
      ],
      WorkspaceComponent.dailyPoetry => const [
        Rect.fromLTWH(14, 28, 112, 20),
        Rect.fromLTWH(14, 56, 72, 22),
      ],
    };
    paint.color = colors.onSurface.withValues(alpha: .18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(14, 14, 48, 6),
        const Radius.circular(3),
      ),
      paint,
    );
    for (var index = 0; index < blocks.length; index++) {
      paint.color = index == 0
          ? colors.primary.withValues(alpha: .55)
          : colors.onSurface.withValues(alpha: .12);
      canvas.drawRRect(
        RRect.fromRectAndRadius(blocks[index], const Radius.circular(4)),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MiniaturePainter oldDelegate) =>
      oldDelegate.component != component ||
      oldDelegate.colors != colors ||
      oldDelegate.surface != surface;
}
