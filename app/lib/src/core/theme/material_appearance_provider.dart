import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../material/material_appearance.dart';
import '../preferences/ui_preferences_controller.dart';

class MaterialAppearanceNotifier extends Notifier<MaterialAppearance> {
  @override
  MaterialAppearance build() => MaterialAppearance.fromPreferences(
    ref.read(uiPreferencesControllerProvider.notifier).read(),
  );
  void update(MaterialAppearance value) =>
      state = MaterialAppearance.fromPreferences(value.toPreferences());
  void persist() => ref
      .read(uiPreferencesControllerProvider.notifier)
      .patch('material', state.toPreferences());
  void selectStyle(SurfaceStyle style) {
    update(state.copyWith(style: style));
    persist();
  }

  void reset() {
    state = const MaterialAppearance();
    persist();
  }
}

final materialAppearanceProvider =
    NotifierProvider<MaterialAppearanceNotifier, MaterialAppearance>(
      MaterialAppearanceNotifier.new,
    );
