import 'dart:convert';
import 'dart:ffi';

import 'package:timetrace_app/src/core/bridge/desktop_bridge.dart';
import 'package:timetrace_app/src/features/nowline/data/live_activity_port.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';

typedef _ReadSnapshotNative = Pointer<Uint8> Function();
typedef _ReadSnapshotDart = Pointer<Uint8> Function();
typedef _FreeSnapshotNative = Void Function(Pointer<Uint8>);
typedef _FreeSnapshotDart = void Function(Pointer<Uint8>);

class NativeLiveActivityPort implements LiveActivityPort {
  NativeLiveActivityPort();

  static const _maxSnapshotBytes = 1024 * 1024;

  late final DynamicLibrary _library = DynamicLibrary.open(
    DesktopBridge.libraryPath(),
  );
  late final _ReadSnapshotDart _read = _library
      .lookupFunction<_ReadSnapshotNative, _ReadSnapshotDart>(
        'timetrace_live_activity_json',
      );
  late final _FreeSnapshotDart _free = _library
      .lookupFunction<_FreeSnapshotNative, _FreeSnapshotDart>(
        'timetrace_live_activity_json_free',
      );

  @override
  LiveActivitySnapshot read() {
    final pointer = _read();
    if (pointer.address == 0) {
      throw StateError('Native live activity returned a null snapshot');
    }
    try {
      var length = 0;
      while (length < _maxSnapshotBytes && (pointer + length).value != 0) {
        length++;
      }
      if (length == _maxSnapshotBytes) {
        throw const FormatException(
          'Native live activity snapshot is too large',
        );
      }
      final text = utf8.decode(pointer.asTypedList(length));
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Native live activity snapshot is not JSON',
        );
      }
      return LiveActivitySnapshot.fromJson(decoded);
    } finally {
      _free(pointer);
    }
  }
}
