import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';

void main() {
  test('keeps trimmed ordinary application names', () {
    expect(safeDisplayLabel('  Visual Studio Code  '), 'Visual Studio Code');
    expect(safeDisplayLabel('Editor: Preview'), 'Editor: Preview');
  });

  test('rejects executable paths and control characters', () {
    for (final unsafe in [
      r'C:\Users\private\secret.exe',
      '/Applications/Secret.app/Contents/MacOS/Secret',
      r'folder\secret.exe',
      'Editor\nprivate document',
      'Editor\u007fprivate',
      '\tEditor',
    ]) {
      expect(safeDisplayLabel(unsafe), '未命名应用');
    }
  });

  test('uses a caller-provided neutral fallback', () {
    expect(safeDisplayLabel('  ', fallback: '当前应用'), '当前应用');
  });
}
