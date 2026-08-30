import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

void main() {
  test('privacy-sensitive window titles default to hidden', () {
    const preferences = NowlinePreferences();

    expect(preferences.showWindowTitles, isFalse);
    expect(preferences.clickThroughOnStart, isFalse);
    expect(preferences.placement, NowlinePlacement.bottom);
  });

  test('loads persisted values and clamps visual ranges', () {
    final preferences = NowlinePreferences.fromJson({
      'line_count': 20,
      'panel_opacity': 0.1,
      'show_window_titles': true,
      'show_timestamps': false,
      'click_through_on_start': true,
      'placement': 'top',
    });

    expect(preferences.lineCount, 6);
    expect(preferences.panelOpacity, 0.5);
    expect(preferences.showWindowTitles, isTrue);
    expect(preferences.showTimestamps, isFalse);
    expect(preferences.clickThroughOnStart, isTrue);
    expect(preferences.placement, NowlinePlacement.top);
    expect(
      NowlinePreferences.fromJson(preferences.toJson()).toJson(),
      preferences.toJson(),
    );
  });
}
