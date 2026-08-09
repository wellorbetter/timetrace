import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

/// Dark mode preference (Riverpod 3).
class ThemeNotifier extends Notifier<bool> {
  @override
  bool build() => UiPreferencesStore.read()['dark'] == true;

  void toggle() {
    state = !state;
    UiPreferencesStore.update({'dark': state});
  }

  void set(bool value) {
    state = value;
    UiPreferencesStore.update({'dark': value});
  }
}

final themeModeProvider = NotifierProvider<ThemeNotifier, bool>(ThemeNotifier.new);
