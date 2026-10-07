import 'package:flutter/material.dart';
import '../../../../core/material/material.dart';

/// Ordered, bounded tag items. Only the remove action owns a 48dp control;
/// read-only tags remain compact and retain their full text/semantics.
class DiaryTagItems extends StatelessWidget {
  const DiaryTagItems({required this.tags, this.onRemove, super.key});
  final List<String> tags;
  final ValueChanged<String>? onRemove;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: MaterialTokens.spaceSm,
      runSpacing: MaterialTokens.spaceSm,
      children: [
        for (final tag in tags)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(
                  MaterialTokens.controlRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: MaterialTokens.spaceSm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: MaterialTokens.spaceSm,
                          horizontal: MaterialTokens.spaceSm,
                        ),
                        child: Text(
                          tag,
                          key: ValueKey(('diary-tag', tag)),
                          softWrap: true,
                        ),
                      ),
                    ),
                    if (onRemove != null)
                      MaterialIconAction(
                        buttonKey: ValueKey(('diary-remove-tag', tag)),
                        tooltip: '移除标签：$tag',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => onRemove!(tag),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
