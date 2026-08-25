import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_screen.dart';

/// Dashboard-native AI report section linked to the top date range.
///
/// The dashboard owns [rangeKey] and [rangeLabel]. This widget deliberately
/// has no local report-type or period selection, so changing the top range is
/// the only way to change the report projection.
class AiRecapCard extends StatefulWidget {
  const AiRecapCard({
    super.key,
    required this.rangeKey,
    required this.rangeLabel,
  });

  final AiRecapRangeKey rangeKey;
  final String rangeLabel;

  @override
  State<AiRecapCard> createState() => _AiRecapCardState();
}

class _AiRecapCardState extends State<AiRecapCard> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant AiRecapCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rangeKey == widget.rangeKey) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scrollController,
    thumbVisibility: true,
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        key: const Key('ai-recap-linked-scroll'),
        controller: _scrollController,
        primary: false,
        padding: const EdgeInsets.only(right: 8),
        child: AiRecapLinkedSection(
          rangeKey: widget.rangeKey,
          rangeLabel: widget.rangeLabel,
        ),
      ),
    ),
  );
}
