import 'package:flutter/widgets.dart';

/// One content instance remains in the host; only its presentation is animated.
class WorkspaceStackTransition extends StatefulWidget {
  const WorkspaceStackTransition({
    required this.selection,
    required this.child,
    this.resetToken,
    super.key,
  });
  final int selection;
  final Widget child;
  final Object? resetToken;
  @override
  State<WorkspaceStackTransition> createState() =>
      WorkspaceStackTransitionState();
}

class WorkspaceStackTransitionState extends State<WorkspaceStackTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  int _request = 0;
  double _direction = 1;
  bool _leaving = false;
  void settle() {
    _request++;
    _leaving = false;
    _controller.stop();
    _controller.value = 1;
  }

  Future<void> switchTo(int selection, VoidCallback commit) async {
    final request = ++_request;
    if (selection == widget.selection) {
      _leaving = false;
      _controller.forward();
      return;
    }
    _direction = selection > widget.selection ? 1 : -1;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _leaving = true;
      try {
        await _controller
            .animateTo(0, duration: const Duration(milliseconds: 80))
            .orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || request != _request) return;
    _leaving = false;
    commit();
  }

  @override
  void didUpdateWidget(WorkspaceStackTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken) {
      settle();
      return;
    }
    if (oldWidget.selection != widget.selection) {
      _request++;
      _leaving = false;
      _direction = widget.selection > oldWidget.selection ? 1 : -1;
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _request++;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) {
      final progress =
          MediaQuery.disableAnimationsOf(context) || _controller.isCompleted
          ? 1.0
          : Curves.easeOutQuart.transform(_controller.value);
      return FractionalTranslation(
        key: const Key('workspace_stack_slide'),
        translation: Offset(
          (_leaving ? -1 : 1) * _direction * .045 * (1 - progress),
          0,
        ),
        child: Transform.scale(
          scale: .985 + .015 * progress,
          child: Opacity(opacity: progress, child: child),
        ),
      );
    },
  );
}
