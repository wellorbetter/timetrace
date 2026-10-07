import 'dart:async';
import 'dart:io';

import '../../../core/preferences/local_storage_paths.dart';

typedef SettingsExportQuery = Future<String> Function({
  required String start, required String end,
});
typedef SettingsExportWriter = Future<void> Function(String path, String csv);

enum SettingsExportStatus { success, failed }
enum SettingsExportStage { location, query, write }

class SettingsExportResult {
  const SettingsExportResult(this.status, this.stage);
  final SettingsExportStatus status;
  final SettingsExportStage stage;
  String get feedback => switch ((status, stage)) {
    (SettingsExportStatus.success, _) =>
      'CSV 已导出到应用存储目录的 export.csv。',
    (_, SettingsExportStage.location) =>
      '导出位置不可用；未查询或写入数据，请检查应用存储位置后重试。',
    (_, SettingsExportStage.query) =>
      '导出查询失败；未写入文件，可重试。',
    (_, SettingsExportStage.write) =>
      '导出文件写入未能确认；不报告成功，请检查存储权限后重试。',
  };
}

/// One shared task per service. No API/DB creation or synchronous file writing.
/// Disposing the screen does not cancel a native query or an already begun write.
class SettingsExportService {
  SettingsExportService({
    required SettingsExportQuery query,
    SettingsExportWriter? write,
    String? Function()? location,
    DateTime Function()? clock,
  }) : _query = query,
       _write = write ?? _writeFile,
       _location = location ?? _exportLocation,
       _clock = clock ?? DateTime.now;

  final SettingsExportQuery _query;
  final SettingsExportWriter _write;
  final String? Function() _location;
  final DateTime Function() _clock;
  Future<SettingsExportResult>? _pending;

  bool get busy => _pending != null;

  Future<SettingsExportResult> export() {
    final active = _pending;
    if (active != null) return active;
    // Set the flight before executing callbacks, even a reentrant fake query.
    final completion = Completer<SettingsExportResult>();
    _pending = completion.future;
    unawaited(_run().then((result) {
      _pending = null;
      completion.complete(result);
    }));
    return completion.future;
  }

  Future<SettingsExportResult> _run() async {
    var stage = SettingsExportStage.location;
    try {
      final path = _location();
      if (path == null || !isAbsoluteExportTarget(path)) {
        return const SettingsExportResult(
          SettingsExportStatus.failed, SettingsExportStage.location);
      }
      final now = _clock();
      final year = now.year.toString().padLeft(4, '0');
      final month = now.month.toString().padLeft(2, '0');
      final start = '$year-$month-01';
      final end = '$year-$month-${now.day.toString().padLeft(2, '0')}';
      stage = SettingsExportStage.query;
      final csv = await _query(start: start, end: end);
      // Do not reinterpret valid empty or partial/unknown canonical CSV.
      stage = SettingsExportStage.write;
      await _write(path, csv);
      return const SettingsExportResult(
        SettingsExportStatus.success, SettingsExportStage.write);
    } catch (_) {
      // Native errors may contain private storage paths. Never stringify them.
      return SettingsExportResult(SettingsExportStatus.failed, stage);
    }
  }

  static String? _exportLocation() =>
    timeTraceStorageLocation(Platform.environment['APPDATA'], 'export.csv');

  static Future<void> _writeFile(String path, String csv) async {
    await File(path).writeAsString(csv);
  }
}

/// Exact internal export filename; relative fallbacks and traversal are refused.
bool isAbsoluteExportTarget(String path) =>
  !path.contains('\u0000') &&
  (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
    RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+').hasMatch(path)) &&
  !path.split(RegExp(r'[\\/]')).any((part) => part == '.' || part == '..') &&
  RegExp(r'[\\/]TimeTrace[\\/]export\.csv$').hasMatch(path);
