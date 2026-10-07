import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../preferences/ui_preferences_controller.dart';

/// Background preference: solid color or an image path.
@immutable
class BackgroundPref {
  const BackgroundPref({this.color, this.imagePath, this.opacity = 0.82});

  final Color? color;
  final String? imagePath;

  /// Visibility of the selected background. 0 is hidden, 1 is fully visible.
  final double opacity;

  bool get isImage => imagePath != null;

  BackgroundPref copyWith({
    Color? color,
    String? imagePath,
    double? opacity,
    bool clearColor = false,
  }) {
    return BackgroundPref(
      color: clearColor ? null : (color ?? this.color),
      imagePath: imagePath ?? this.imagePath,
      opacity: opacity ?? this.opacity,
    );
  }
}

class BackgroundNotifier extends Notifier<BackgroundPref> {
  int _generation = 0;
  void _persist({bool continuePending = false}) {
    final controller = ref.read(uiPreferencesControllerProvider.notifier);
    final previous = continuePending
        ? ref.read(uiPreferencesControllerProvider)['background']
        : null;
    controller.patch('background', {
      'backgroundColor': state.color?.toARGB32(),
      'backgroundImage': state.imagePath,
      'backgroundOpacity': state.opacity,
    }, continuation: previous);
  }

  @override
  BackgroundPref build() {
    final values = ref.read(uiPreferencesControllerProvider.notifier).read();
    final color = values['backgroundColor'];
    return BackgroundPref(
      color: color is int ? Color(color) : null,
      imagePath: values['backgroundImage'] is String
          ? values['backgroundImage'] as String
          : null,
      opacity:
          values['backgroundOpacity'] is num &&
              (values['backgroundOpacity'] as num).isFinite
          ? (values['backgroundOpacity'] as num).toDouble().clamp(0, 1)
          : 0.82,
    );
  }

  void setColor(Color? color) {
    ++_generation;
    state = BackgroundPref(
      color: color,
      imagePath: null,
      opacity: state.opacity,
    );
    _persist();
  }

  Future<void> pickImage() async {
    final generation = ++_generation;
    ref.read(backgroundPickerFailureProvider.notifier).dismiss();
    try {
      final path = await ref.read(backgroundImagePickerProvider)();
      if (!ref.mounted || generation != _generation) return;
      if (path != null && path.isNotEmpty) {
        state = BackgroundPref(
          color: null,
          imagePath: path,
          opacity: state.opacity,
        );
        _persist();
      }
    } catch (_) {
      if (!ref.mounted || generation != _generation) return;
      // A picker failure is not a write and must not expose a private path.
      ref.read(backgroundPickerFailureProvider.notifier).fail();
    }
  }

  void clear() {
    ++_generation;
    state = const BackgroundPref();
    _persist();
  }

  void setOpacity(double opacity) {
    if (!opacity.isFinite) return;
    ++_generation;
    opacity = opacity.clamp(0, 1);
    state = state.copyWith(opacity: opacity);
    _persist(continuePending: true);
  }
}

final backgroundImagePickerProvider = Provider<Future<String?> Function()>(
  (ref) => () async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    return result == null || result.files.isEmpty
        ? null
        : result.files.single.path;
  },
);

class BackgroundPickerFailure extends Notifier<bool> {
  @override
  bool build() => false;
  void dismiss() => state = false;
  void fail() => state = true;
}

final backgroundPickerFailureProvider =
    NotifierProvider<BackgroundPickerFailure, bool>(
      BackgroundPickerFailure.new,
    );

final backgroundProvider = NotifierProvider<BackgroundNotifier, BackgroundPref>(
  BackgroundNotifier.new,
);
