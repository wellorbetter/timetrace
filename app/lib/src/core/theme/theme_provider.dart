import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../preferences/ui_preferences_controller.dart';

/// Dark mode preference (Riverpod 3).
class ThemeNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(uiPreferencesControllerProvider.notifier).read()['dark'] == true;

  void toggle() {
    state = !state;
    ref.read(uiPreferencesControllerProvider.notifier).patch('theme', {
      'dark': state,
    });
  }

  void set(bool value) {
    state = value;
    ref.read(uiPreferencesControllerProvider.notifier).patch('theme', {
      'dark': value,
    });
  }
}

final themeModeProvider = NotifierProvider<ThemeNotifier, bool>(
  ThemeNotifier.new,
);
