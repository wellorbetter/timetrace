import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Background preference: solid color or an image path.
@immutable
class BackgroundPref {
  const BackgroundPref({this.color, this.imagePath});

  final Color? color;
  final String? imagePath;

  bool get isImage => imagePath != null;

  BackgroundPref copyWith({Color? color, String? imagePath, bool clearColor = false}) {
    return BackgroundPref(
      color: clearColor ? null : (color ?? this.color),
      imagePath: imagePath ?? this.imagePath,
    );
  }
}

class BackgroundNotifier extends Notifier<BackgroundPref> {
  @override
  BackgroundPref build() => const BackgroundPref();

  void setColor(Color? color) {
    state = BackgroundPref(color: color, imagePath: null);
    AppLogger.log('background color: ${color?.toARGB32().toRadixString(16)}');
  }

  Future<void> pickImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.single.path;
        if (path != null) {
          state = BackgroundPref(color: null, imagePath: path);
          AppLogger.log('background image set: $path');
        }
      }
    } catch (e) {
      AppLogger.log('pick background failed: $e');
    }
  }

  void clear() => state = const BackgroundPref();
}

final backgroundProvider =
    NotifierProvider<BackgroundNotifier, BackgroundPref>(BackgroundNotifier.new);
