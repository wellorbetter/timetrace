import 'package:flutter/material.dart';
import '../material/material.dart';

/// Supplemental copy stays off the primary task surface until requested.
class ContextHelp extends StatefulWidget {
  const ContextHelp({required this.message, super.key});
  final String message;
  @override
  State<ContextHelp> createState() => _ContextHelpState();
}

class _ContextHelpState extends State<ContextHelp> {
  final _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capture = MaterialOverlayCapture.of(context);
    final panel = MaterialTransientPanel(
      key: const Key('context_help_surface'),
      capture: capture,
      maxWidth: 280,
      maxHeightFraction: .65,
      child: Text(widget.message, style: Theme.of(context).textTheme.bodySmall),
    );
    return MenuAnchor(
      childFocusNode: _focus,
      onClose: () {
        if (mounted) _focus.requestFocus();
      },
      style: materialMenuStyle,
      menuChildren: [panel],
      builder: (context, controller, _) => IconButton(
        focusNode: _focus,
        tooltip: '说明',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        style: materialActionStyle(
          context,
          role: MaterialActionRole.auxiliary,
          padding: EdgeInsets.zero,
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.question_mark_rounded, size: 18),
      ),
    );
  }
}
