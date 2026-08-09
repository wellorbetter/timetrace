import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

/// Background preference: solid color or an image path.
@immutable
class BackgroundPref {
  const BackgroundPref({this.color, this.imagePath, this.opacity = 0.82});

  final Color? color;
  final String? imagePath;
  /// Visibility of the selected background. 0 is hidden, 1 is fully visible.
  final double opacity;

  bool get isImage => imagePath != null;

  BackgroundPref copyWith({Color? color, String? imagePath, double? opacity, bool clearColor = false}) {
    return BackgroundPref(
      color: clearColor ? null : (color ?? this.color),
      imagePath: imagePath ?? this.imagePath,
      opacity: opacity ?? this.opacity,
    );
  }
}

class BackgroundNotifier extends Notifier<BackgroundPref> {
  @override
  BackgroundPref build() {
    final values = UiPreferencesStore.read();
    final color = values['backgroundColor'];
    return BackgroundPref(
      color: color is int ? Color(color) : null,
      imagePath: values['backgroundImage'] as String?,
      opacity: (values['backgroundOpacity'] as num?)?.toDouble() ?? 0.82,
    );
  }

  void setColor(Color? color) {
    state = BackgroundPref(color: color, imagePath: null, opacity: state.opacity);
    UiPreferencesStore.update({
      'backgroundColor': color?.toARGB32(),
      'backgroundImage': null,
      'backgroundOpacity': state.opacity,
    });
    AppLogger.log('background color: ${color?.toARGB32().toRadixString(16)}');
  }

  Future<void> pickImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.single.path;
        if (path != null) {
          state = BackgroundPref(color: null, imagePath: path, opacity: state.opacity);
          UiPreferencesStore.update({
            'backgroundColor': null,
            'backgroundImage': path,
            'backgroundOpacity': state.opacity,
          });
          AppLogger.log('background image set: $path');
        }
      }
    } catch (e) {
      AppLogger.log('pick background failed: $e');
    }
  }

  void clear() {
    state = const BackgroundPref();
    UiPreferencesStore.update({
      'backgroundColor': null,
      'backgroundImage': null,
    });
  }

  void setOpacity(double opacity) {
    state = state.copyWith(opacity: opacity);
    UiPreferencesStore.update({'backgroundOpacity': opacity});
  }
}

final backgroundProvider =
    NotifierProvider<BackgroundNotifier, BackgroundPref>(BackgroundNotifier.new);
