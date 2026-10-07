import 'dart:io';
import 'dart:async';
import '../../../core/preferences/ui_preferences_controller.dart';
import 'local_storage_information.dart';
import '../data/settings_export_service.dart';
import '../../../core/preferences/local_storage_folder_action.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show PointerDownEvent;
import '../../../core/preferences/presentation_preferences_provider.dart';
import 'feed_view_settings.dart';
import 'ai_connection_settings.dart';
import '../../browsing/providers/ai_connection_provider.dart';
import 'background_color_picker.dart';
import 'material_appearance_settings.dart';
import '../../../core/widgets/context_help.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialSection,
    this.storageLocations,
    this.storageFolderAction,
    this.loadExcludedProcesses,
    this.exportService,
  });
  final String? initialSection;
  final LocalStorageLocations Function()? storageLocations;
  final FolderAction? storageFolderAction;
  final Future<Map<String, String>> Function()? loadExcludedProcesses;
  final SettingsExportService? exportService;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _scrollController = ScrollController();
  final _pageFocus = FocusScopeNode(debugLabel: 'Settings input modality');
  bool _keyboardFocusPaint = false;
  bool _exportBusy = false;
  SettingsExportResult? _exportResult;
  SettingsExportService? _defaultExportService;

  @override
  void initState() {
    super.initState();
    // Observes handled Shortcuts too; never consumes or redispatches keys.
    HardwareKeyboard.instance.addHandler(_observeKey);
  }

  bool _observeKey(KeyEvent event) {
    if (mounted && (_pageFocus.hasFocus || ModalRoute.of(context)?.isCurrent == true) &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        {LogicalKeyboardKey.tab, LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space}.contains(event.logicalKey) &&
        !_keyboardFocusPaint) {
      setState(() => _keyboardFocusPaint = true);
    }
    return false;
  }

  void _observePointer(PointerDownEvent event) {
    if (_keyboardFocusPaint) setState(() => _keyboardFocusPaint = false);
  }
  final _feedSectionKey = GlobalKey();
  final _recapSectionKey = GlobalKey();
  bool _sectionLocated = false;
  bool _showCustomBackgroundColor = false;
  final _collapsed = <_SettingsSectionType>{};
  final _draftStatuses = <_SettingsSectionType, ({bool dirty, bool invalid, bool pending})>{};

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      _sectionLocated = false;
      final target = switch (widget.initialSection) {
        'feed' => _SettingsSectionType.feed,
        'recap' => _SettingsSectionType.recap,
        _ => null,
      };
      if (target != null) _collapsed.remove(target);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_observeKey);
    _pageFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(ref.watch(localeProvider));
    final asyncSettings = ref.watch(settingsProvider);
    if (!_sectionLocated &&
        (widget.initialSection == 'feed' || widget.initialSection == 'recap') &&
        asyncSettings.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target =
            (widget.initialSection == 'recap'
                    ? _recapSectionKey
                    : _feedSectionKey)
                .currentContext;
        if (mounted && target != null) {
          _sectionLocated = true;
          Scrollable.ensureVisible(target, alignment: 0.05);
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _observePointer,
        child: FocusScope(
          node: _pageFocus,
          child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final tokens = MaterialTokens.forWidth(width);
          return Padding(
            padding: EdgeInsets.all(tokens.pageInset),
            child: Align(
              alignment: Alignment.topCenter,
              // Reading measure, not a second set of responsive breakpoints.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: SizedBox(
                  width: double.infinity,
                  child: asyncSettings.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(MaterialTokens.spaceLg),
                        child: Text('加载失败: $error'),
                      ),
                    ),
                    data: (settings) => FocusTraversalGroup(
                      child: ListTileTheme(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: MaterialTokens.spaceMd,
                        ),
                        minVerticalPadding: MaterialTokens.spaceSm,
                        child: Scrollbar(
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            key: const PageStorageKey<String>('settings-body'),
                            controller: _scrollController,
                            primary: false,
                            padding: const EdgeInsets.fromLTRB(12, 12, 28, 24),
                            // Keep the finite settings form mounted. Width
                            // changes alter spacing, not parents or keys of
                            // controls, focus nodes or bridge-backed tiles.
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _settingsCards(
                                context,
                                _settingsSections(context, settings, l, tokens),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
          ),
        ),
      ),
    );
  }

  List<_SettingsSection> _settingsSections(
    BuildContext context,
    AppSettings settings,
    L10n l,
    MaterialTokens tokens,
  ) {
    final dark = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return [
      _SettingsSection(
        type: _SettingsSectionType.theme,
        title: l.theme,
        icon: Icons.palette_outlined,
        
        children: [
      RadioGroup<bool>(
        groupValue: dark,
        onChanged: (value) =>
            ref.read(themeModeProvider.notifier).set(value ?? false),
        child: Column(
          children: [
            RadioListTile<bool>(
              value: false,
              title: Text(l.lightMode),
              secondary: const Icon(Icons.light_mode_outlined),
            ),
            RadioListTile<bool>(
              value: true,
              title: Text(l.darkMode),
              secondary: const Icon(Icons.dark_mode_outlined),
            ),
          ],
        ),
      ),
      const UiPreferencesFeedback('theme'),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.language,
        title: l.language,
        icon: Icons.translate,
        
        children: [
      RadioGroup<AppLocale>(
        groupValue: locale,
        onChanged: (value) =>
            ref.read(localeProvider.notifier).set(value ?? AppLocale.zh),
        child: const Column(
          children: [
            RadioListTile<AppLocale>(
              value: AppLocale.zh,
              title: Text('中文'),
              secondary: Text(
                '中',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            RadioListTile<AppLocale>(
              value: AppLocale.en,
              title: Text('English'),
              secondary: Text(
                'EN',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.font,
        title: l.font,
        icon: Icons.font_download_outlined,
        
        children: [
      _fontPicker(context),
      const UiPreferencesFeedback('font'),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.background,
        title: l.background,
        icon: Icons.wallpaper_outlined,
        
        children: [
      _backgroundPicker(context, l),
      const UiPreferencesFeedback('background'),
      SwitchListTile(
        key: const Key('immersive_window_setting'),
        title: const Text('沉浸式窗口'),
        subtitle: const Text('让标题栏融入应用背景；关闭可恢复标准窗口。'),
        value: ref.watch(immersiveWindowProvider),
        onChanged: (enabled) => ref.read(immersiveWindowProvider.notifier)
            .setEnabled(enabled),
      ),
      const UiPreferencesFeedback('windowPresentation'),
      if (ref.watch(backgroundPickerFailureProvider))
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('图片选择失败；原背景未改动。'),
        ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.workspace,
        title: '工作台组件布局',
        icon: Icons.view_carousel_outlined,
        help: '进入编辑模式后可拖动排序、堆叠或收纳组件；把组件停留在另一组件中央可以堆叠。',
        children: [
      ListTile(
        title: const Text('调整组件位置'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          ref.read(workspaceEditProvider.notifier).start();
          context.go('/dashboard');
        },
      ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.feed,
        title: '时间流',
        icon: Icons.timeline_rounded,
        help: '时间刻度支持 1–1440 分钟，自定义后按 Enter 保存。展示方式只调整活动标题，临时的应用与窗口筛选仍可取消。',
        children: [
      FeedViewSettings(
        isSectionExpanded: !_collapsed.contains(_SettingsSectionType.feed),
        onDraftStatusChanged: ({required bool dirty, required bool invalid, required bool pending}) =>
            _setDraftStatus(_SettingsSectionType.feed, dirty: dirty, invalid: invalid, pending: pending),
      ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.recap,
        title: 'AI 能力接入',
        icon: Icons.auto_awesome_outlined,
        
        children: [
      AiConnectionSettings(
        isSectionExpanded: !_collapsed.contains(_SettingsSectionType.recap),
        onDraftStatusChanged: ({required bool dirty, required bool invalid, required bool pending}) =>
            _setDraftStatus(_SettingsSectionType.recap, dirty: dirty, invalid: invalid, pending: pending),
      ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.monitoring,
        title: l.monitoring,
        icon: Icons.monitor_heart_outlined,
        helpKey: const Key('monitoring_help'),
        help: '关闭窗口最小化到托盘：隐藏窗口，后台继续记录。启动时最小化：只显示托盘图标。自动开始追踪：决定再次启动时是否立即记录。开机启动：写入当前用户启动项，无需管理员权限。暂停记录立即生效；锁屏或待机也会自动暂停计时。',
        children: [
      _PollingInterval(
        label: l.pollInterval,
        value: settings.pollIntervalMs,
        onChanged: (value) => _update(settings.copyWith(pollIntervalMs: value)),
        isSectionExpanded: !_collapsed.contains(_SettingsSectionType.monitoring),
        onDraftStatusChanged: ({required bool dirty, required bool invalid, required bool pending}) =>
            _setDraftStatus(_SettingsSectionType.monitoring, dirty: dirty, invalid: invalid, pending: pending),
      ),
      const _ConfigFeedback('poll'),
      _SliderTile<int>(
        label: l.idleThreshold,
        value: settings.idleThresholdMinutes,
        min: 1,
        max: 60,
        divisions: 59,
        display: '${settings.idleThresholdMinutes} ${l.minutes}',
        description: '键盘/鼠标停止操作多久后视为离开，暂停计时',
        help: '空闲阈值：键盘/鼠标停止操作多久后视为离开并暂停计时。锁屏/屏幕保护/待机会立即暂停，不受此阈值影响。',
        onChanged: (value) =>
            _update(settings.copyWith(idleThresholdMinutes: value)),
      ),
      const _ConfigFeedback('idle'),
      Padding(
        padding: const EdgeInsets.all(MaterialTokens.spaceMd),
        child: Text(l.appliesOnRestart),
      ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.record,
        title: '记录控制',
        icon: Icons.tune,
        
        children: [
      ListTile(
        title: const Text('排除应用'),
        subtitle: Text(
          settings.excludedApps.isEmpty
              ? '未配置'
              : settings.excludedApps.join('、'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _editExcludedApps(context, settings),
      ),
      const _ConfigFeedback('excluded'),
      const Divider(),
      const _PauseRecordTile(),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.startup,
        title: '启动与托盘',
        icon: Icons.desktop_windows_outlined,
        
        children: [
      SwitchListTile(
        title: const Text('关闭窗口时最小化到托盘'),
        value: settings.minimizeToTray,
        onChanged: (value) => _update(settings.copyWith(minimizeToTray: value)),
      ),
      SwitchListTile(
        title: const Text('启动时最小化'),
        value: settings.startMinimized,
        onChanged: (value) =>
            _updateAndSave(settings.copyWith(startMinimized: value)),
      ),
      SwitchListTile(
        title: const Text('启动后自动开始追踪'),
        value: settings.autoStartTracking,
        onChanged: (value) =>
            _update(settings.copyWith(autoStartTracking: value)),
      ),
      const _ConfigFeedback('startup'),
      _SelfStartupTile(startMinimized: settings.startMinimized),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.data,
        title: l.data,
        icon: Icons.storage_outlined,
        
        children: [
      LocalStorageInformation(
        resolve: widget.storageLocations, folderAction: widget.storageFolderAction,
        onDraftStatusChanged: ({required bool dirty, required bool invalid, required bool pending}) =>
            _setDraftStatus(_SettingsSectionType.data, dirty: dirty, invalid: invalid, pending: pending),
      ),
      ListTile(
        key: const Key('settings_export_csv'),
        leading: const Icon(Icons.file_download_outlined),
        title: Text(_exportBusy ? '正在导出 CSV…' : l.exportData),
        subtitle: Text('CSV — ${l.appList}'),
        trailing: const Icon(Icons.chevron_right),
        enabled: !_exportBusy,
        onTap: _exportBusy ? null : () => _exportCsv(),
      ),
      if (_exportBusy)
        const LinearProgressIndicator(key: Key('settings_export_busy')),
      if (_exportResult != null)
        Padding(
          padding: const EdgeInsets.all(MaterialTokens.spaceMd),
          child: Semantics(
            liveRegion: true,
            child: Text(_exportResult!.feedback,
              key: const Key('settings_export_feedback')),
          ),
        ),
        ],
      ),
      _SettingsSection(
        type: _SettingsSectionType.about,
        title: l.about,
        icon: Icons.info_outline,
        
        children: [
      const Padding(
        padding: EdgeInsets.all(MaterialTokens.spaceMd),
        child: Text('TimeTrace v1.0.1 · Rust + Flutter · MIT'),
      ),
        ],
      ),
    ];
  }

  void _setDraftStatus(
    _SettingsSectionType type, {
    required bool dirty,
    required bool invalid,
    required bool pending,
  }) {
    final next = (dirty: dirty, invalid: invalid, pending: pending);
    if (!mounted || _draftStatuses[type] == next) return;
    setState(() => _draftStatuses[type] = next);
  }

  List<Widget> _settingsCards(BuildContext context, List<_SettingsSection> sections) {
    final operations = ref.watch(uiPreferencesControllerProvider);
    final config = ref.watch(settingsWriteFeedbackProvider);
    final keyStatus = ref.watch(savedDeepSeekKeyProvider.select(
      (value) => (pending: value.isLoading, invalid: value.hasError),
    ));
    final backgroundFailed = ref.watch(backgroundPickerFailureProvider);
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    return [
      for (final section in sections)
        Container(
          key: section.type == _SettingsSectionType.feed ? _feedSectionKey
              : section.type == _SettingsSectionType.recap ? _recapSectionKey
              : ValueKey('settings_${section.type.name}_section'),
          margin: const EdgeInsets.only(bottom: MaterialTokens.spaceLg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
            boxShadow: MaterialTokens.cardShadow(dark: dark),
          ),
          child: MaterialCard(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: _SettingsDisclosure(
              section: section,
              paintFocus: _keyboardFocusPaint,
              expanded: !_collapsed.contains(section.type),
              status: _sectionStatus(section.type, operations, config, keyStatus,
                  backgroundFailed),
              onToggle: () => setState(() {
                if (!_collapsed.add(section.type)) _collapsed.remove(section.type);
              }),
            ),
          ),
        ),
    ];
  }

  String _sectionStatus(
    _SettingsSectionType type,
    Map<String, UiPreferencesOperation> operations,
    SettingsWriteIntent? config,
    ({bool pending, bool invalid}) keyStatus,
    bool backgroundFailed,
  ) {
    final groups = switch (type) {
      _SettingsSectionType.theme => const ['theme'],
      _SettingsSectionType.font => const ['font'],
      _SettingsSectionType.background => const ['background', 'material', 'windowPresentation'],
      _SettingsSectionType.workspace => const ['workspace'],
      _SettingsSectionType.feed => const ['feedMinutes', 'feedMode', 'feedToolbar'],
      _SettingsSectionType.recap => const ['aiEnabled', 'aiModel'],
      _SettingsSectionType.data => const ['safeCache'],
      _ => const <String>[],
    };
    final local = _draftStatuses[type];
    var dirty = local?.dirty ?? false;
    var invalid = local?.invalid ?? false;
    var pending = local?.pending ?? false;
    for (final group in groups) {
      final status = operations[group]?.status;
      dirty |= status == UiPreferencesOperationStatus.dirty ||
          status == UiPreferencesOperationStatus.failed;
      invalid |= status == UiPreferencesOperationStatus.failed;
      pending |= status == UiPreferencesOperationStatus.pending;
    }
    final configGroups = switch (type) {
      _SettingsSectionType.monitoring => const ['poll', 'idle'],
      _SettingsSectionType.record => const ['excluded'],
      _SettingsSectionType.startup => const ['startup', 'config'],
      _ => const <String>[],
    };
    if (config != null && !config.verified && configGroups.contains(config.group)) {
      dirty = true;
      invalid |= config.failed;
      pending |= !config.failed;
    }
    if (type == _SettingsSectionType.recap) {
      invalid |= keyStatus.invalid;
      pending |= keyStatus.pending;
    }
    if (type == _SettingsSectionType.background) invalid |= backgroundFailed;
    if (type == _SettingsSectionType.data) {
      pending |= _exportBusy;
      invalid |= _exportResult?.status == SettingsExportStatus.failed;
    }
    // Never publish a value, key, path or backend message in a folded header.
    return [if (dirty) '未保存', if (invalid) '有错误', if (pending) type == _SettingsSectionType.data ? '处理中' : '保存中'].join(' · ');
  }

  Future<void> _editExcludedApps(
    BuildContext context,
    AppSettings settings,
  ) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ExcludedAppsDialog(
        initial: settings.excludedApps,
        loadProcesses: widget.loadExcludedProcesses,
        capture: MaterialOverlayCapture.of(context),
      ),
    );
    if (!mounted || result == null) return;
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.read(settingsProvider).asData?.value ?? settings;
    try {
      await notifier.apply(current.copyWith(excludedApps: result));
    } catch (_) {
      /* field feedback retains intent */
    }
  }

  void _update(AppSettings next) {
    unawaited(_updateAndSave(next));
  }

  Future<void> _updateAndSave(AppSettings next) async {
    try {
      await ref.read(settingsProvider.notifier).apply(next);
    } catch (_) {
      /* Explicit field-bound failure, never a saved snackbar. */
    }
  }

  Widget _fontPicker(BuildContext context) {
    final selected = ref.watch(fontProvider);
    return RadioGroup<AppFont>(
      groupValue: selected,
      onChanged: (value) {
        if (value != null) ref.read(fontProvider.notifier).select(value);
      },
      child: Column(
        children: [
          for (final font in AppFont.all)
            RadioListTile<AppFont>(
              value: font,
              title: Text(font.name, style: TextStyle(fontFamily: font.family)),
              subtitle: Text(
                font.preview,
                style: TextStyle(
                  fontFamily: font.family,
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              secondary: Text(
                'Aa',
                style: TextStyle(
                  fontFamily: font.family,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _backgroundPicker(BuildContext context, L10n l) {
    final pref = ref.watch(backgroundProvider);
    final policy = MaterialScope.of(context).policy;
    const colors = <Color?>[
      null,
      Color(0xFFF7F3FF),
      Color(0xFFE8F4FD),
      Color(0xFFFDF2E9),
      Color(0xFFF0F7EC),
      Color(0xFF1A1A2E),
    ];
    const labels = ['默认背景色', '淡紫背景', '淡蓝背景', '浅杏背景', '浅绿背景', '深蓝背景'];
    return Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: MaterialTokens.spaceXs,
            runSpacing: MaterialTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < colors.length; i++)
                Semantics(
                  selected: pref.color == colors[i],
                  child: MaterialIconButton(
                    tooltip: labels[i],
                    onPressed: () => ref
                        .read(backgroundProvider.notifier)
                        .setColor(colors[i]),
                    icon: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: colors[i] ?? policy.colorScheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: pref.color == colors[i]
                              ? policy.focusColor
                              : policy.boundary,
                          width: pref.color == colors[i]
                              ? MaterialTokens.focusWidth
                              : MaterialTokens.borderWidth,
                        ),
                      ),
                      child: pref.color == colors[i]
                          ? Icon(
                              Icons.check,
                              size: 18,
                              color:
                                  ThemeData.estimateBrightnessForColor(
                                        colors[i] ?? policy.colorScheme.surface,
                                      ) ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black,
                            )
                          : colors[i] == null
                          ? Icon(
                              Icons.close,
                              size: 18,
                              color: policy.colorScheme.onSurface,
                            )
                          : null,
                    ),
                  ),
                ),
              MaterialIconButton(
                key: const Key('background_custom_color'),
                tooltip: '自定义颜色',
                icon: const Icon(Icons.palette_outlined),
                onPressed: () => setState(
                  () =>
                      _showCustomBackgroundColor = !_showCustomBackgroundColor,
                ),
              ),
              MaterialIconButton(
                tooltip: l.backgroundImage,
                icon: const Icon(Icons.image_outlined),
                onPressed: () =>
                    ref.read(backgroundProvider.notifier).pickImage(),
              ),
              if (pref.isImage || pref.color != null)
                MaterialIconButton(
                  tooltip: l.clear,
                  icon: Icon(Icons.refresh, color: policy.colorScheme.error),
                  onPressed: () =>
                      ref.read(backgroundProvider.notifier).clear(),
                ),
            ],
          ),
          if (_showCustomBackgroundColor)
            BackgroundColorPicker(
              initialColor: pref.color ?? policy.colorScheme.surface,
              onApply: (color) =>
                  ref.read(backgroundProvider.notifier).setColor(color),
            ),
          if (pref.isImage || pref.color != null) ...[
            const SizedBox(height: MaterialTokens.spaceSm),
            Text('背景不透明度：${(pref.opacity * 100).round()}%'),
            Slider(
              value: pref.opacity.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 100,
              label: '${(pref.opacity * 100).round()}%',
              semanticFormatterCallback: (value) =>
                  '背景不透明度 ${(value * 100).round()}%',
              onChanged: (value) =>
                  ref.read(backgroundProvider.notifier).setOpacity(value),
            ),
          ],
          const SizedBox(height: MaterialTokens.spaceLg),
          const MaterialAppearanceSettings(),
        ],
      ),
    );
  }

  Future<void> _exportCsv() async {
    if (_exportBusy) return;
    setState(() { _exportBusy = true; _exportResult = null; });
    try {
      final service = widget.exportService ?? (_defaultExportService ??=
        SettingsExportService(query: ({required start, required end}) =>
          ref.read(apiProvider).exportCsvAsync(start: start, end: end)));
      final result = await service.export();
      if (!mounted) return;
      setState(() => _exportResult = result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _exportResult = const SettingsExportResult(
        SettingsExportStatus.failed, SettingsExportStage.query));
    } finally {
      // Leaving the screen suppresses UI notifications, not native/I/O work.
      if (mounted) setState(() => _exportBusy = false);
    }
  }
}

class _SelfStartupTile extends ConsumerStatefulWidget {
  const _SelfStartupTile({required this.startMinimized});

  final bool startMinimized;

  @override
  ConsumerState<_SelfStartupTile> createState() => _SelfStartupTileState();
}

class _SelfStartupTileState extends ConsumerState<_SelfStartupTile> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    try {
      _enabled = ref.read(apiProvider).isSelfStartEnabled();
    } catch (error) {
      AppLogger.log('read self startup failed: $error');
    }
  }

  void _toggle(bool enabled) {
    setState(() => _busy = true);
    try {
      ref
          .read(apiProvider)
          .setSelfStartEnabled(
            enabled: enabled,
            minimized: widget.startMinimized,
          );
      setState(() => _enabled = enabled);
    } catch (error) {
      AppLogger.log('set self startup failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('开机启动'),
      value: _enabled ?? false,
      onChanged: _busy || _enabled == null ? null : _toggle,
    );
  }
}

enum _SettingsSectionType {
  theme, language, font, background, workspace, feed, recap,
  monitoring, record, startup, data, about,
}

class _SettingsSection {
  const _SettingsSection({required this.type, required this.title,
    required this.icon, required this.children, this.help, this.helpKey});
  final _SettingsSectionType type;
  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? help;
  final Key? helpKey;
}

class _SettingsDisclosure extends StatefulWidget {
  const _SettingsDisclosure({required this.section, required this.expanded,
    required this.status, required this.onToggle, required this.paintFocus});
  final _SettingsSection section;
  final bool expanded;
  final String status;
  final VoidCallback onToggle;
  final bool paintFocus;
  @override
  State<_SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<_SettingsDisclosure> {
  final _headerFocus = FocusNode();
  final _bodyFocus = FocusScopeNode();
  @override
  void dispose() {
    _headerFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MaterialTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MaterialTokens.spaceSm),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    expanded: widget.expanded,
                    child: MaterialActionButton(
                      buttonKey: ValueKey('settings_toggle_${section.type.name}'),
                      focusNode: _headerFocus,
                      paintFocus: widget.paintFocus,
                      role: MaterialActionRole.auxiliary,
                      onPressed: () {
                        // Moving focus never submits or discards a field draft.
                        _headerFocus.requestFocus();
                        widget.onToggle();
                      },
                      child: Row(
                        children: [
                          ExcludeSemantics(child: Icon(section.icon, size: 20, color: colors.primary)),
                          const SizedBox(width: MaterialTokens.spaceSm),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(section.title, textAlign: TextAlign.start,
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600, color: colors.primary)),
                              if (widget.status.isNotEmpty)
                                Text(widget.status,
                                  key: ValueKey('settings_status_${section.type.name}'),
                                  textAlign: TextAlign.start,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          )),
                          ExcludeSemantics(child: Icon(widget.expanded
                            ? Icons.expand_less_rounded : Icons.expand_more_rounded)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (section.help != null)
                  ContextHelp(key: section.helpKey, message: section.help!),
              ],
            ),
          ),
          Visibility(
            visible: widget.expanded,
            maintainState: true,
            child: ExcludeFocus(
              excluding: !widget.expanded,
              child: ExcludeSemantics(
                excluding: !widget.expanded,
                child: TickerMode(
                  enabled: widget.expanded,
                  child: FocusScope(
                    node: _bodyFocus,
                    child: Column(
                      key: ValueKey('settings_body_${section.type.name}'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: section.children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PollingInterval extends StatefulWidget {
  const _PollingInterval({
    required this.label,
    required this.value,
    required this.onChanged,
    this.onDraftStatusChanged,
    this.isSectionExpanded = true,
  });
  final void Function({required bool dirty, required bool invalid, required bool pending})? onDraftStatusChanged;
  final bool isSectionExpanded;
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  @override
  State<_PollingInterval> createState() => _PollingIntervalState();
}

class _PollingIntervalState extends State<_PollingInterval> {
  PollingUnit _unit = PollingUnit.seconds;
  late final _input = TextEditingController(
    text: formatPollingValue(widget.value, _unit),
  );
  final _menu = MenuController();
  final _focus = FocusNode();
  String? _error;

  bool _statusQueued = false;
  ({bool dirty, bool invalid, bool pending})? _reportedStatus;
  void _scheduleDraftStatus() {
    if (widget.onDraftStatusChanged == null || _statusQueued) return;
    _statusQueued = true;
    // Coalesce actual events; never call a parent from build or expose values.
    scheduleMicrotask(() {
      _statusQueued = false;
      if (!mounted) return;
      final next = (dirty: _input.text != formatPollingValue(widget.value, _unit), invalid: _error != null, pending: false);
      if (_reportedStatus == next) return;
      _reportedStatus = next;
      widget.onDraftStatusChanged?.call(
        dirty: next.dirty, invalid: next.invalid, pending: next.pending);
    });
  }

  @override
  void initState() { super.initState(); _input.addListener(_scheduleDraftStatus); }
  @override
  void didUpdateWidget(_PollingInterval oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        _input.text == formatPollingValue(oldWidget.value, _unit)) {
      _input.text = formatPollingValue(widget.value, _unit);
    }
    if (oldWidget.value != widget.value) _scheduleDraftStatus();
    if (oldWidget.isSectionExpanded && !widget.isSectionExpanded) {
      scheduleMicrotask(() {
        if (mounted && !widget.isSectionExpanded) _menu.close();
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final parsed = parsePollingMilliseconds(text, _unit);
    setState(() => _error = parsed == null ? '请输入 30–60 秒或 0.5–1 分钟' : null);
    if (parsed != null && parsed != widget.value) widget.onChanged(parsed);
    _scheduleDraftStatus();
  }

  void _changeUnit(PollingUnit next) {
    _menu.close();
    if (next == _unit) return;
    final unchanged = _input.text == formatPollingValue(widget.value, _unit);
    final value = unchanged
        ? widget.value
        : parsePollingMilliseconds(_input.text, _unit);
    if (value == null) {
      setState(() => _error = '先修正数值，再切换单位');
      _scheduleDraftStatus();
      return;
    }
    setState(() {
      _unit = next;
      _input.text = formatPollingValue(value, next);
      _error = null;
    });
    _scheduleDraftStatus();
  }

  @override
  Widget build(BuildContext context) {
    final capture = MaterialOverlayCapture.of(context);
    return Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceMd),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final labelWidth = (160 * scale).clamp(0.0, width);
          final valueWidth = 230.0.clamp(0.0, width);
          return Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: labelWidth,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const ContextHelp(
                      message:
                          '轮询间隔 30–60 秒（0.5–1 分钟）。输入后按 Enter 保存，下次启动生效，不立即改变当前监控。切换单位只改变显示，不保存。旧配置超出范围时只在内存显示有效值，不自动写入；下一次显式保存任一监控配置项会保存当前有效间隔。',
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: valueWidth,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('settings_poll_value'),
                        controller: _input,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          hintText: '输入检测间隔',
                          errorText: _error,
                        ),
                        onSubmitted: _submit,
                      ),
                    ),
                    const SizedBox(width: MaterialTokens.spaceSm),
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
                              for (final value in PollingUnit.values)
                                MenuItemButton(
                                  onPressed: () => _changeUnit(value),
                                  child: Text(
                                    value == PollingUnit.seconds ? '秒' : '分钟',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      builder: (context, controller, _) => MaterialActionButton(
                        buttonKey: const Key('settings_poll_unit'),
                        focusNode: _focus,
                        onPressed: () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                            _focus.requestFocus();
                          }
                        },
                        child: Text(_unit == PollingUnit.seconds ? '秒' : '分钟'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SliderTile<T extends num> extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.description,
    this.help,
  });

  final String label;
  final T value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final String? description;
  final String? help;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(display),
              if (help != null || description != null)
                ContextHelp(message: help ?? description!),
            ],
          ),
          Semantics(
            label: label,
            child: Slider(
              value: value.toDouble().clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: (next) =>
                  onChanged(value is int ? next.round() as T : next as T),
            ),
          ),
        ],
      ),
    );
  }
}

/// Immediate bridge operation; it does not write the settings configuration.
class _PauseRecordTile extends ConsumerStatefulWidget {
  const _PauseRecordTile();

  @override
  ConsumerState<_PauseRecordTile> createState() => _PauseRecordTileState();
}

class _PauseRecordTileState extends ConsumerState<_PauseRecordTile> {
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    try {
      _paused = ref.read(apiProvider).isTrackingPaused();
    } catch (error) {
      AppLogger.log('read pause state failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('暂停记录'),
      value: _paused,
      onChanged: (value) {
        try {
          ref.read(apiProvider).setTrackingPaused(paused: value);
          setState(() => _paused = value);
        } catch (error) {
          AppLogger.log('setTrackingPaused failed: $error');
        }
      },
    );
  }
}

class _ExcludedAppsDialog extends StatefulWidget {
  const _ExcludedAppsDialog({
    required this.initial,
    this.loadProcesses,
    required this.capture,
  });

  final List<String> initial;
  final Future<Map<String, String>> Function()? loadProcesses;
  final MaterialOverlayCapture capture;

  @override
  State<_ExcludedAppsDialog> createState() => _ExcludedAppsDialogState();
}

class _ExcludedAppsDialogState extends State<_ExcludedAppsDialog> {
  final _filter = TextEditingController();
  final _scrollController = ScrollController();
  late final Set<String> _selected = widget.initial.toSet();
  List<_ProcessEntry> _processes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProcesses();
  }

  @override
  void dispose() {
    _filter.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadProcesses() async {
    try {
      final injected = widget.loadProcesses;
      if (injected != null) {
        final values = await injected();
        if (!mounted) return;
        setState(() {
          _processes = [
            for (final entry in values.entries)
              _ProcessEntry(entry.key, entry.value),
          ]..sort((a, b) => a.name.compareTo(b.name));
          _loading = false;
        });
        return;
      }
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-Process | Where-Object { $_.Path } | Select-Object ProcessName,Path | ConvertTo-Csv -NoTypeInformation',
      ]);
      final entries = <String, _ProcessEntry>{};
      for (final line
          in result.stdout.toString().split(RegExp(r'\r?\n')).skip(1)) {
        final match = RegExp(r'^"([^"]+)","(.*)"$').firstMatch(line.trim());
        if (match != null) {
          final name = '${match.group(1)}.exe';
          entries[name.toLowerCase()] = _ProcessEntry(name, match.group(2)!);
        }
      }
      if (!mounted) return;
      setState(() {
        _processes = entries.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addManually() async {
    final capture = MaterialOverlayCapture.of(context);
    final value = await showDialog<String>(
      context: context,
      builder: (_) => capture.wrap(const _ManualAppDialog()),
    );
    if (!mounted) return;
    final name = value?.trim();
    if (name != null && name.isNotEmpty) {
      setState(() => _selected.add(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.toLowerCase();
    // Keep configured/manual entries reachable even if their process is not
    // running. Unchecking only changes this dialog's draft until Save.
    final entries = <String, _ProcessEntry>{
      for (final process in _processes) process.name: process,
      for (final name in widget.initial) name: _ProcessEntry(name, ''),
    };
    for (final name in _selected) {
      entries.putIfAbsent(name, () => _ProcessEntry(name, ''));
    }
    final visible =
        entries.values
            .where((entry) => entry.name.toLowerCase().contains(query))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(MaterialTokens.spaceLg),
      child: MaterialTransientPanel(
        capture: widget.capture,
        maxWidth: 520,
        maxHeightFraction: .85,
        scrollable: false,
        padding: EdgeInsets.zero,
        child: SizedBox(
          width: 520,
          height: 600,
          // Dialog constrains this size to the available viewport. Header,
          // search and actions share the modal's single scroll axis, so even
          // short windows can reach them without a fixed-height form overflow.
          child: Scrollbar(
            controller: _scrollController,
            child: CustomScrollView(
              controller: _scrollController,
              primary: false,
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(MaterialTokens.spaceLg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(
                          namesRoute: true,
                          header: true,
                          child: Text(
                            '排除应用',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: MaterialTokens.spaceLg),
                        TextField(
                          controller: _filter,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: '搜索应用',
                            hintText: '搜索正在运行或已配置的应用',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: MaterialTokens.spaceSm),
                        Wrap(
                          spacing: MaterialTokens.spaceSm,
                          runSpacing: MaterialTokens.spaceSm,
                          children: [
                            TextButton.icon(
                              style: materialActionStyle(context),
                              onPressed: _addManually,
                              icon: const Icon(Icons.add),
                              label: const Text('手动添加其他程序'),
                            ),
                            TextButton(
                              style: materialActionStyle(context),
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              style: materialActionStyle(
                                context,
                                role: MaterialActionRole.primary,
                              ),
                              onPressed: () =>
                                  Navigator.pop(context, _selected.toList()),
                              child: const Text('保存'),
                            ),
                          ],
                        ),
                        if (_loading) ...[
                          const SizedBox(height: MaterialTokens.spaceSm),
                          const LinearProgressIndicator(),
                        ],
                        if (!_loading && visible.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: MaterialTokens.spaceLg,
                            ),
                            child: Text('没有找到匹配的应用，可手动添加。'),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final process = visible[index];
                    return CheckboxListTile(
                      key: ValueKey<String>(process.name),
                      value: _selected.contains(process.name),
                      secondary: process.path.isEmpty
                          ? const Icon(Icons.apps_outlined)
                          : AppIcon(exePath: process.path, size: 28),
                      title: Text(process.name),
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _selected.add(process.name);
                        } else {
                          _selected.remove(process.name);
                        }
                      }),
                    );
                  }, childCount: visible.length),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(MaterialTokens.spaceLg),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        style: materialActionStyle(
                          context,
                          role: MaterialActionRole.primary,
                        ),
                        onPressed: () =>
                            Navigator.pop(context, _selected.toList()),
                        child: const Text('保存'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualAppDialog extends StatefulWidget {
  const _ManualAppDialog();

  @override
  State<_ManualAppDialog> createState() => _ManualAppDialogState();
}

class _ManualAppDialogState extends State<_ManualAppDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: MaterialTransientPanel(
        capture: MaterialOverlayCapture.of(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('手动添加', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: MaterialTokens.spaceMd),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '应用名或 exe 路径',
                hintText: '例如：Code.exe',
              ),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: MaterialTokens.spaceMd),
            Wrap(
              spacing: MaterialTokens.spaceSm,
              children: [
                MaterialActionButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                MaterialActionButton(
                  onPressed: () => Navigator.pop(context, _controller.text),
                  child: const Text('添加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessEntry {
  const _ProcessEntry(this.name, this.path);

  final String name;
  final String path;
}

class _ConfigFeedback extends ConsumerWidget {
  const _ConfigFeedback(this.group);
  final String group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final intent = ref.watch(settingsWriteFeedbackProvider);
    if (intent == null || intent.group != group || intent.verified)
      return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(intent.failed ? '保存失败，输入仍保留，请重试' : '正在验证保存…'),
          if (intent.failed)
            TextButton(
              key: ValueKey('settings_retry_$group'),
              onPressed: () async {
                try {
                  await ref.read(settingsProvider.notifier).retry();
                } catch (_) {}
              },
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
