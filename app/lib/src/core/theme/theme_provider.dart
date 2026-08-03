import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dark mode preference (Riverpod 3).
class ThemeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void set(bool value) => state = value;
}

final themeModeProvider = NotifierProvider<ThemeNotifier, bool>(ThemeNotifier.new);
