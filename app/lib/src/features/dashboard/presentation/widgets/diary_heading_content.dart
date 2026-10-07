import 'package:flutter/material.dart';
import '../../../../core/material/material.dart';
import 'daily_quote_line.dart';

/// Diary identity at the left; poetry gets the unused reading space at right.
class DiaryHeadingContent extends StatelessWidget {
  const DiaryHeadingContent({
    required this.date,
    required this.showQuote,
    this.quote = const DailyQuoteLine(),
    super.key,
  });
  final DateTime date;
  final bool showQuote;
  final Widget quote;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = Column(
      key: const Key('diary_heading_identity'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '日记',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    if (!showQuote) return identity;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth >= 480 * textScale) {
          return Row(
            children: [
              SizedBox(width: 128 * textScale, child: identity),
              const SizedBox(width: MaterialTokens.spaceXl),
              Expanded(child: quote),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            identity,
            const SizedBox(height: MaterialTokens.spaceMd),
            quote,
          ],
        );
      },
    );
  }
}
