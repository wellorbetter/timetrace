import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/material/material.dart';
import '../../../core/preferences/safe_cache_service.dart';
import '../../../core/preferences/ui_preferences_controller.dart';
import '../../../core/preferences/local_storage_paths.dart';
import '../../../core/preferences/local_storage_folder_action.dart';
import '../../../core/preferences/windows_storage_folder_opener.dart';

class LocalStorageLocations {
  const LocalStorageLocations({
    required this.appData,
    required this.localAppData,
  });
  final String? appData, localAppData;
  String location(String? base, String suffix) =>
      timeTraceStorageLocation(base, suffix) ?? '位置不可用（需要绝对路径）';
  factory LocalStorageLocations.environment() => LocalStorageLocations(
    appData: Platform.environment['APPDATA'],
    localAppData: Platform.environment['LOCALAPPDATA'],
  );
}

/// Paths are resolved as strings only. Opening and cache inspection require an
/// explicit user action and can both be replaced by strict fixture adapters.
class LocalStorageInformation extends StatefulWidget {
  const LocalStorageInformation({
    this.resolve,
    this.openFolder,
    this.folderAction,
    this.cacheService,
    this.onDraftStatusChanged,
    super.key,
  });
  final LocalStorageLocations Function()? resolve;
  final Future<void> Function(String)? openFolder;
  final FolderAction? folderAction;
  final SafeCacheService? cacheService;
  final void Function({required bool dirty, required bool invalid, required bool pending})? onDraftStatusChanged;
  @override
  State<LocalStorageInformation> createState() =>
      _LocalStorageInformationState();
}

class _LocalStorageInformationState extends State<LocalStorageInformation> {
  String? _feedback;
  String? _folderFeedback;
  bool _opening = false;
  bool _folderFailed = false;
  SafeCacheTicket? _ticket;
  bool _busy = false;

  bool _statusQueued = false;
  ({bool dirty, bool invalid, bool pending})? _reportedStatus;
  void _scheduleDraftStatus() {
    if (widget.onDraftStatusChanged == null || _statusQueued) return;
    _statusQueued = true;
    // Coalesce actual events; never call a parent from build or expose values.
    scheduleMicrotask(() {
      _statusQueued = false;
      if (!mounted) return;
      final next = (dirty: false, invalid: _folderFailed, pending: _opening || _busy);
      if (_reportedStatus == next) return;
      _reportedStatus = next;
      widget.onDraftStatusChanged?.call(
        dirty: next.dirty, invalid: next.invalid, pending: next.pending);
    });
  }
  SafeCacheService _service() =>
      widget.cacheService ??
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(safeCacheServiceProvider);
  Future<void> _clean() async {
    if (_busy || _opening) return;
    final service = _service();
    final ticket = _ticket ?? service.capture(SafeCacheScope.dailyQuoteV2);
    if (ticket == null) {
      setState(() => _feedback = '没有可安全清理的已知诗词缓存；未修改任何数据。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => Dialog(
        backgroundColor: Colors.transparent,
        child: MaterialTransientPanel(
          capture: MaterialOverlayCapture.of(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('仅清理当前诗词缓存？'),
              const Text('不会删除任务、计时历史、日记、标签、图片或配置备份。'),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    key: const Key('confirm_safe_cache_clear'),
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('清理诗词缓存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    _scheduleDraftStatus();
    final outcome = service.clear(ticket, confirmed: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      final success =
          outcome?.status == UiPreferencesOperationStatus.verifiedAck;
      _ticket = success ? null : ticket;
      _feedback = success ? '诗词缓存已清理；其他数据未改动。' : '清理未能验证；其他数据未改动，可重试。';
    });
    _scheduleDraftStatus();
  }

  Future<void> _open(String target) async {
    if (_opening || _busy) return;
    setState(() => _opening = true);
    _scheduleDraftStatus();
    var result = const FolderActionResult(
      FolderActionStatus.requestFailed,
      stage: FolderActionStage.request,
    );
    try {
      // The legacy override is authoritative: do not validate, probe, construct
      // a production adapter, or run a worker against its synthetic path.
      final legacy = widget.openFolder;
      if (legacy != null) {
        await legacy(target);
        result = const FolderActionResult(
          FolderActionStatus.accepted,
          stage: FolderActionStage.request,
        );
      } else {
        result = await (widget.folderAction ?? const WindowsStorageFolderOpener())
            .open(target);
      }
    } catch (_) {
      // Feedback never includes native exceptions, paths or private content.
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _folderFailed = result.status != FolderActionStatus.accepted;
          _folderFeedback = switch (result.status) {
            FolderActionStatus.accepted => '文件夹打开请求已发送。',
            FolderActionStatus.missing => '尚无存储目录；未修改任何数据。',
            FolderActionStatus.inaccessible => '无法访问存储目录；未修改任何数据，可重试。',
            FolderActionStatus.requestFailed => '文件夹打开请求失败；未修改任何数据，可重试。',
            FolderActionStatus.unsupported => '当前系统不支持打开存储文件夹；未修改任何数据。',
          };
          if (result.status != FolderActionStatus.accepted) {
            _folderFeedback = '$_folderFeedback ${storageFolderFailureDetails(result)}';
          }
        });
        _scheduleDraftStatus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths = (widget.resolve ?? LocalStorageLocations.environment)();
    final folderTargets = [
      timeTraceStorageFolderLocation(paths.appData, 'ui_config.json'),
      timeTraceStorageFolderLocation(paths.localAppData, 'workspace-time-tools-v1'),
      timeTraceStorageFolderLocation(paths.localAppData, 'diary-candidates-v1'),
      timeTraceStorageFolderLocation(paths.localAppData, 'diary-entry-metadata-v1'),
      timeTraceStorageFolderLocation(paths.localAppData, diaryDraftTagsAssetSuffix),
      timeTraceStorageFolderLocation(paths.appData, 'diary_images'),
    ];
    final rows = [
      (
        '诗词缓存',
        paths.location(paths.appData, 'ui_config.json'),
        '当前诗句保存在配置 ui_config.json 的 dailyQuoteV2；此按钮打开配置所在目录，不是独立诗词历史。最多 7 项内存诗句，配置安全备份也不是诗词历史。',
      ),
      (
        '任务与计时',
        paths.location(paths.localAppData, 'workspace-time-tools-v1'),
        '任务、截止时间与计时历史，不是可自动清理的缓存。',
      ),
      (
        '日记候选',
        paths.location(paths.localAppData, 'diary-candidates-v1'),
        '保留本地与 AI 候选及保存凭据，不自动清理。',
      ),
      (
        '来源与标签',
        paths.location(paths.localAppData, 'diary-entry-metadata-v1'),
        '日记元数据历史，不自动清理。',
      ),
      (
        '草稿标签与发表凭据',
        paths.location(paths.localAppData, diaryDraftTagsAssetSuffix),
        '草稿标签与发表意图的持久资产及历史，不是每日缓存，不自动清理。',
      ),
      ('日记图片', paths.location(paths.appData, 'diary_images'), '用户图片资产，不自动清理。'),
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('本地存储', style: Theme.of(context).textTheme.titleSmall),
          for (var index = 0; index < rows.length; index++) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rows[index].$1,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        rows[index].$3,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('storage_folder_$index'),
                  tooltip: '打开存储文件夹',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _opening || _busy || folderTargets[index] == null
                      ? null
                      : () => _open(folderTargets[index]!),
                  icon: const Icon(Icons.folder_open_outlined),
                ),
              ],
            ),
          ],
          TextButton(
            key: const Key('safe_cache_clear'),
            onPressed: _busy || _opening ? null : _clean,
            child: Text(_ticket == null ? '清理诗词缓存' : '重试清理诗词缓存'),
          ),
          if (_feedback != null)
            Text(_feedback!, key: const Key('safe_cache_feedback')),
          if (_folderFeedback != null)
            Text(_folderFeedback!, key: const Key('storage_folder_feedback')),
        ],
      ),
    );
  }
}

/// Public enum/numeric diagnostics only; no native message or machine path.
String storageFolderFailureDetails(FolderActionResult result) {
  final stage = switch (result.stage) {
    FolderActionStage.validation => '目标验证',
    FolderActionStage.allocation => '参数分配',
    FolderActionStage.probe => '目录访问检查',
    FolderActionStage.com => 'COM 初始化',
    FolderActionStage.request => '系统打开请求',
    FolderActionStage.cleanup => '资源释放',
    FolderActionStage.worker => '后台工作线程',
  };
  final code = result.nativeCode == null ? '未提供' : result.nativeCode.toString();
  return '阶段：$stage；错误码：$code。'
      '${result.cleanupFailed ? ' 资源释放未能确认。' : ''}';
}
