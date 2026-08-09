import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

void main() {
  test('decodes a valid preferences document', () {
    expect(
      UiPreferencesStore.decode('{"version":1,"locale":"zh"}'),
      {'version': 1, 'locale': 'zh'},
    );
  });

  test('ignores malformed preferences documents', () {
    expect(UiPreferencesStore.decode('{not-json'), isEmpty);
    expect(UiPreferencesStore.decode('[]'), isEmpty);
  });
}
