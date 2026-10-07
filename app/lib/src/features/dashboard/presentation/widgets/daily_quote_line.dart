import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/material/material.dart';
import '../../providers/daily_quote_provider.dart';

final dailyQuoteTickProvider = Provider<Duration?>(
  (ref) => const Duration(minutes: 1),
);

/// Shared prose and explicit controls, never a second material surface.
class DailyQuoteLine extends ConsumerStatefulWidget {
  const DailyQuoteLine({this.heading, super.key});
  final String? heading;
  @override
  ConsumerState<DailyQuoteLine> createState() => _DailyQuoteLineState();
}

class _DailyQuoteLineState extends ConsumerState<DailyQuoteLine>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _token = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final interval = ref.read(dailyQuoteTickProvider);
    if (interval != null)
      _timer = Timer.periodic(interval, (_) {
        if (mounted) setState(() {});
      });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _token++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh(String day, {bool offline = false}) async {
    final token = ++_token;
    final repository = ref.read(dailyQuoteRepositoryProvider);
    await repository.refresh(DateTime.parse(day), offline: offline);
    if (!mounted || token != _token) return;
    final now = ref.read(dailyQuoteClockProvider)();
    if (DailyQuoteRepository.stamp(now) !=
        DailyQuoteRepository.stamp(DateTime.parse(day)))
      return;
    ref.invalidate(dailyQuoteProvider(day));
    setState(() {});
  }

  void _expand(DailyQuote quote) {
    final capture = MaterialOverlayCapture.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: MaterialTransientPanel(
          capture: capture,
          scrollable: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                quote.work,
                style: Theme.of(dialogContext).textTheme.titleLarge,
              ),
              const SizedBox(height: MaterialTokens.spaceLg),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: _QuoteContent(quote: quote, expanded: true),
                  ),
                ),
              ),
              MaterialActionButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('收起'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(dailyQuoteClockProvider)();
    final day = DateTime(now.year, now.month, now.day).toIso8601String();
    final loaded = ref.watch(dailyQuoteProvider(day));
    final status =
        ref.watch(dailyQuoteStatusProvider(day)).value ??
        const DailyQuoteStatus();
    final quote = status.quote ?? loaded.value ?? offlineDailyQuotes.first;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.hasBoundedHeight;
        final scaler = MediaQuery.textScalerOf(context);
        final headingStyle = Theme.of(context).textTheme.titleMedium;
        final headingPainter = TextPainter(
          text: TextSpan(text: widget.heading ?? '', style: headingStyle),
          textDirection: Directionality.of(context),
          textScaler: scaler,
        )..layout(maxWidth: (constraints.maxWidth - 56).clamp(1.0, double.infinity));
        final headerHeight = widget.heading == null
            ? 48.0
            : headingPainter.height.clamp(48.0, double.infinity);
        headingPainter.dispose();
        final bodyHeight = bounded
            ? (constraints.maxHeight - headerHeight).clamp(0.0, double.infinity)
            : 0.0;
        // Use the actual card body, not the window or a synthetic size label.
        // Larger faces gain readable type; accessibility scaling stays native.
        final fontSize =
            constraints.maxWidth >= 480 &&
                (!bounded || bodyHeight >= scaler.scale(180))
            ? 23.0
            : 19.0;
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (quote.hasFullPoem)
              TextButton(
                key: const Key('daily_poetry_expand'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                ),
                onPressed: () => _expand(quote),
                child: Semantics(
                  // Merge the action hint into the button's own semantics node,
                  // alongside the visible verse and provenance, not its parent.
                  label: '阅读全文',
                  child: _QuoteContent(
                    quote: quote,
                    fontSize: fontSize,
                    collapsedLines: bounded &&
                            bodyHeight < scaler.scale(fontSize * 3.2 + 24)
                        ? 1
                        : 2,
                  ),
                ),
              )
            else
              _QuoteContent(quote: quote, fontSize: fontSize),
            if (status.busy)
              const Text(
                '正在换一首…',
                key: Key('daily_poetry_busy'),
                textAlign: TextAlign.center,
              ),
            if (!status.busy && status.message != null)
              Text(
                status.message!,
                key: const Key('daily_poetry_status'),
                textAlign: TextAlign.center,
              ),
            if (status.cachePending && !status.busy)
              MaterialActionButton(
                buttonKey: const Key('daily_poetry_cache_retry'),
                onPressed: () => ref
                    .read(dailyQuoteRepositoryProvider)
                    .retryCache(DateTime.parse(day)),
                child: const Text('缓存未保存，重试保存'),
              ),
          ],
        );
        final prose = SingleChildScrollView(
          child: bounded
              ? ConstrainedBox(
                  constraints: BoxConstraints(minHeight: bodyHeight),
                  child: Center(child: content),
                )
              : content,
        );
        final refresh = MaterialIconAction(
          buttonKey: const Key('daily_poetry_refresh'),
          tooltip: '下一首',
          onPressed: status.busy ? null : () => _refresh(day),
          icon: const Icon(Icons.arrow_forward),
        );
        return Column(
          mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: headerHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: widget.heading == null
                        ? const SizedBox()
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Text(widget.heading!, style: headingStyle),
                          ),
                  ),
                  const SizedBox(width: 8),
                  refresh,
                ],
              ),
            ),
            if (bounded) Expanded(child: prose) else prose,
          ],
        );
      },
    );
  }
}

class _QuoteContent extends StatelessWidget {
  const _QuoteContent({
    required this.quote,
    this.expanded = false,
    this.fontSize = 19,
    this.collapsedLines = 2,
  });
  final DailyQuote quote;
  final bool expanded;
  final double fontSize;
  final int collapsedLines;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poetryStyle = theme.textTheme.bodyLarge?.copyWith(
      fontFamily: 'KaiTi',
      fontFamilyFallback: const ['STKaiti', 'FangSong', 'Noto Serif CJK SC'],
      fontSize: fontSize,
      height: 1.6,
      letterSpacing: .5,
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          key: Key(expanded ? 'daily_poetry_full_text' : 'daily_poetry_text'),
          TextSpan(
            children: [
              for (final run
                  in RegExp(r'[\u0000-\u024f]+|[^\u0000-\u024f]+').allMatches(
                    expanded ? quote.fullContent.join('\n') : quote.text,
                  ))
                TextSpan(
                  text: run.group(0),
                  style: run.group(0)!.contains(RegExp(r'[A-Za-z]'))
                      ? poetryStyle?.copyWith(
                          fontFamily: 'Georgia',
                          fontFamilyFallback: const ['Times New Roman'],
                          fontStyle: FontStyle.italic,
                          letterSpacing: .15,
                        )
                      : poetryStyle,
                ),
            ],
          ),
          textAlign: TextAlign.center,
          maxLines: expanded ? null : collapsedLines,
          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: poetryStyle,
        ),
        const SizedBox(height: 4),
        Text(
          quote.attribution,
          key: Key(
            expanded
                ? 'daily_poetry_full_attribution'
                : 'daily_poetry_attribution',
          ),
          textAlign: TextAlign.center,
          maxLines: expanded ? null : 1,
          overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
