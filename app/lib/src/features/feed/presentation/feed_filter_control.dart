import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/format/app_identity.dart';
import '../../../core/material/material.dart';
import '../../browsing/models/feed_fragment.dart';

/// Global choices come from sanitized, unfiltered canonical fragments.
class FeedFilterControl extends StatefulWidget {
  const FeedFilterControl({
    required this.filter,
    required this.apps,
    required this.windows,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });
  final FeedFilter filter;
  final List<String> apps;
  final List<FeedFilter> windows;
  final ValueChanged<FeedFilter> onChanged;
  final bool enabled;
  @override
  State<FeedFilterControl> createState() => _FeedFilterControlState();
}

class _FeedFilterControlState extends State<FeedFilterControl> {
  final _controller = MenuController();
  final _focus = FocusNode(debugLabel: 'Feed filter trigger');
  bool _windows = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select(FeedFilter value) {
    _controller.close();
    widget.onChanged(value == widget.filter ? const FeedFilter() : value);
  }

  @override
  Widget build(BuildContext context) {
    final choices = _windows
        ? widget.windows
        : [for (final app in widget.apps.toSet()) FeedFilter(appId: app)];
    final groups = <String?, List<FeedFilter>>{};
    if (_windows) {
      for (final choice in choices) {
        groups.putIfAbsent(choice.windowAppId, () => []).add(choice);
      }
    }
    final rows = <(FeedFilter?, String?)>[
      if (_windows)
        for (final entry in groups.entries) ...[
          (null, entry.key),
          for (final choice in entry.value) (choice, null),
        ]
      else
        for (final choice in choices) (choice, null),
    ];
    final capture = MaterialOverlayCapture.of(context);
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _focus,
      onClose: () {
        if (mounted) _focus.requestFocus();
      },
      style: materialMenuStyle,
      alignmentOffset: const Offset(-280, MaterialTokens.spaceSm),
      menuChildren: [
        MaterialTransientPanel(
          capture: capture,
          maxWidth: 320,
          maxHeightFraction: .65,
          scrollable: false,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 320,
            height: math.min(400, MediaQuery.sizeOf(context).height * .65),
            child: Padding(
              padding: const EdgeInsets.all(MaterialTokens.spaceSm),
              child: CustomScrollView(
                primary: false,
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        MenuItemButton(
                          onPressed: () => _select(const FeedFilter()),
                          trailingIcon: widget.filter == const FeedFilter()
                              ? const Icon(Icons.check_rounded, size: 18)
                              : null,
                          child: const Text('全部活动'),
                        ),
                        const SizedBox(height: MaterialTokens.spaceSm),
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: false, label: Text('应用')),
                            ButtonSegment(value: true, label: Text('窗口')),
                          ],
                          selected: {_windows},
                          onSelectionChanged: (value) =>
                              setState(() => _windows = value.single),
                        ),
                        const SizedBox(height: MaterialTokens.spaceSm),
                      ],
                    ),
                  ),
                  if (choices.isEmpty)
                    const SliverToBoxAdapter(child: Text('当前范围没有可筛选的记录'))
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final (choice, process) = rows[index];
                        if (choice == null) {
                          return Semantics(
                            header: true,
                            child: Padding(
                              key: ValueKey('feed_process_group:$process'),
                              padding: const EdgeInsets.all(
                                MaterialTokens.spaceSm,
                              ),
                              child: Text(
                                process == null
                                    ? '未知进程'
                                    : appDisplayLabel(process),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          );
                        }
                        return MenuItemButton(
                          key: ValueKey<FeedFilter>(choice),
                          onPressed: () => _select(choice),
                          trailingIcon: choice == widget.filter
                              ? const Icon(Icons.check_rounded, size: 18)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: MaterialTokens.spaceSm,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _windows
                                      ? choice.windowId!
                                      : appDisplayLabel(choice.appId!),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (_windows && choice.windowAppId != null)
                                  Text(
                                    appDisplayLabel(choice.windowAppId!),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        );
                      }, childCount: rows.length),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        focusNode: _focus,
        key: const Key('feed_global_filter'),
        tooltip: widget.filter == const FeedFilter() ? '筛选时间流' : '筛选时间流（已启用）',
        style: materialActionStyle(context, padding: EdgeInsets.zero),
        onPressed: !widget.enabled
            ? null
            : () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  setState(() => _windows = widget.filter.windowId != null);
                  controller.open();
                  _focus.requestFocus();
                }
              },
        icon: Icon(
          widget.filter == const FeedFilter()
              ? Icons.filter_list_rounded
              : Icons.filter_alt_rounded,
          color: widget.filter == const FeedFilter()
              ? null
              : Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
