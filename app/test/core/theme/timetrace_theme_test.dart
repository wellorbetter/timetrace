import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';

void main() {
  test('semantic text styles keep the selected desktop font and hierarchy', () {
    final text = TimetraceTheme.light(
      fontFamily: 'Microsoft YaHei UI',
    ).textTheme;

    expect(text.headlineSmall?.fontFamily, 'Microsoft YaHei UI');
    expect(text.titleLarge?.fontFamily, 'Microsoft YaHei UI');
    expect(text.bodyMedium?.fontFamily, 'Microsoft YaHei UI');
    expect(text.labelSmall?.fontFamily, 'Microsoft YaHei UI');
    expect(text.headlineSmall?.fontWeight, FontWeight.w600);
    expect(text.bodyMedium?.fontWeight, FontWeight.w400);
    expect(text.labelSmall?.fontWeight, FontWeight.w500);
  });
}
