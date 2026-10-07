import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/preferences/presentation_preferences_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/material/material.dart';
import '../../../core/widgets/context_help.dart';
import '../../../core/preferences/ui_preferences_controller.dart';
import '../../feed/providers/feed_preferences_provider.dart';

class FeedViewSettings extends ConsumerStatefulWidget {
  const FeedViewSettings({this.onDraftStatusChanged, this.isSectionExpanded = true, super.key});
  final void Function({required bool dirty, required bool invalid, required bool pending})? onDraftStatusChanged;
  final bool isSectionExpanded;
  @override
  ConsumerState<FeedViewSettings> createState() => _FeedViewSettingsState();
}

class _FeedViewSettingsState extends ConsumerState<FeedViewSettings> {
  final _menu = MenuController();
  final _focus = FocusNode();
  final _minutesInput = TextEditingController();
  bool _editingMinutes = false;

  bool _statusQueued = false;
  ({bool dirty, bool invalid, bool pending})? _reportedStatus;
  void _scheduleDraftStatus() {
    if (widget.onDraftStatusChanged == null || _statusQueued) return;
    _statusQueued = true;
    // Coalesce actual events; never call a parent from build or expose values.
    scheduleMicrotask(() {
      _statusQueued = false;
      if (!mounted) return;
      final next = (dirty: _editingMinutes && _minutesInput.text != '${ref.read(feedBucketMinutesProvider)}', invalid: _editingMinutes && !validFeedBucketMinutes(int.tryParse(_minutesInput.text) ?? 0), pending: false);
      if (_reportedStatus == next) return;
      _reportedStatus = next;
      widget.onDraftStatusChanged?.call(
        dirty: next.dirty, invalid: next.invalid, pending: next.pending);
    });
  }

  @override
  void initState() {
    super.initState();
    _minutesInput.addListener(_scheduleDraftStatus);
    ref.listenManual(feedBucketMinutesProvider, (_, _) => _scheduleDraftStatus());
  }

  @override
  void didUpdateWidget(FeedViewSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSectionExpanded && !widget.isSectionExpanded) {
      scheduleMicrotask(() {
        if (mounted && !widget.isSectionExpanded) _menu.close();
      });
    }
  }

  void _beginCustomMinutes(int minutes) {
    setState(() { _editingMinutes = true; _minutesInput.text = '$minutes'; });
    _scheduleDraftStatus();
  }
  void _cancelCustomMinutes() {
    setState(() => _editingMinutes = false); _scheduleDraftStatus();
  }
  @override
  void dispose() {
    _focus.dispose();
    _minutesInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = ref.watch(feedBucketMinutesProvider);
    const presets = [5, 10, 15, 30, 60];
    final mode = ref.watch(feedDisplayModeProvider);
    final capture = MaterialOverlayCapture.of(context);
    return Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('工具栏位置', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: MaterialTokens.spaceSm),
          Wrap(
            spacing: MaterialTokens.spaceSm,
            runSpacing: MaterialTokens.spaceSm,
            children: [
              for (final alignment in FeedToolbarAlignment.values)
                MaterialActionButton(
                  buttonKey: ValueKey('feed_toolbar_${alignment.name}'),
                  role: ref.watch(feedToolbarAlignmentProvider) == alignment
                      ? MaterialActionRole.primary : MaterialActionRole.secondary,
                  onPressed: () => ref.read(feedToolbarAlignmentProvider.notifier)
                      .setAlignment(alignment),
                  child: Semantics(
                    selected: ref.watch(feedToolbarAlignmentProvider) == alignment,
                    child: Text(alignment == FeedToolbarAlignment.left ? '左侧' : '右侧'),
                  ),
                ),
            ],
          ),
          const UiPreferencesFeedback('feedToolbar'),
          const SizedBox(height: MaterialTokens.spaceMd),
          Text('每段时长', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: MaterialTokens.spaceSm),
          Wrap(
            spacing: MaterialTokens.spaceSm,
            runSpacing: MaterialTokens.spaceSm,
            children: [
              for (final value in presets)
                ChoiceChip(
                  key: ValueKey('feed-minute-$value'),
                  label: Text('$value 分钟'),
                  selected: minutes == value,
                  onSelected: (_) => ref
                      .read(feedBucketMinutesProvider.notifier)
                      .setMinutes(value),
                ),
              ChoiceChip(
                key: const Key('feed_custom_minutes'),
                label: Text(
                  presets.contains(minutes) ? '自定义' : '$minutes 分钟 · 自定义',
                ),
                selected: !presets.contains(minutes),
                onSelected: (_) => _beginCustomMinutes(minutes),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_editingMinutes)
            TextFormField(
              key: const Key('custom_feed_minutes'),
              controller: _minutesInput,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '自定义分钟',
                hintText: '1–1440',
                border: UnderlineInputBorder(),
                enabledBorder: UnderlineInputBorder(),
                focusedBorder: UnderlineInputBorder(),
                suffixIcon: ContextHelp(message: '1–1440 分钟，输入整数后按 Enter 应用。'),
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) =>
                  value == null ||
                      value.isEmpty ||
                      validFeedBucketMinutes(int.tryParse(value) ?? 0)
                  ? null
                  : '请输入 1–1440 之间的整数',
              onFieldSubmitted: (text) {
                final value = int.tryParse(text);
                if (value != null && validFeedBucketMinutes(value)) {
                  ref
                      .read(feedBucketMinutesProvider.notifier)
                      .setMinutes(value);
                  final operation = ref.read(
                    uiPreferencesControllerProvider,
                  )['feedMinutes'];
                  if (operation == null ||
                      operation.status ==
                          UiPreferencesOperationStatus.verifiedAck) {
                    setState(() => _editingMinutes = false);
                  }
                }
                _scheduleDraftStatus();
              },
            ),
          if (_editingMinutes)
            TextButton(
              onPressed: _cancelCustomMinutes,
              child: const Text('取消'),
            ),
          const UiPreferencesFeedback('feedMinutes'),
          const SizedBox(height: 12),
          const UiPreferencesFeedback('feedMode'),
          MenuAnchor(
            controller: _menu,
            childFocusNode: _focus,
            onClose: () {
              if (mounted && widget.isSectionExpanded) _focus.requestFocus();
            },
            style: materialMenuStyle,
            menuChildren: [
              MaterialTransientPanel(
                capture: capture,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final value in FeedDisplayMode.values)
                      MenuItemButton(
                        onPressed: () {
                          _menu.close();
                          ref
                              .read(feedDisplayModeProvider.notifier)
                              .setMode(value);
                        },
                        trailingIcon: value == mode
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        child: Text(_modeLabel(value)),
                      ),
                  ],
                ),
              ),
            ],
            builder: (context, controller, _) => MaterialActionButton(
              buttonKey: const Key('feed_display_mode'),
              focusNode: _focus,
              onPressed: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                  _focus.requestFocus();
                }
              },
              child: Text('展示方式：${_modeLabel(mode)}'),
            ),
          ),
        ],
      ),
    );
  }
}

String _modeLabel(FeedDisplayMode mode) => switch (mode) {
  FeedDisplayMode.overview => '活动概述',
  FeedDisplayMode.apps => '应用优先',
  FeedDisplayMode.windows => '窗口优先',
};
