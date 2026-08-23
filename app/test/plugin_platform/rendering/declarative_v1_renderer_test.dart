import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/plugin_platform/rendering/declarative_v1_renderer.dart';

void main() {
  testWidgets('renders the complete closed v1 vocabulary as host widgets', (
    tester,
  ) async {
    final document = DeclarativeV1Document(
      contributionId: 'sample-insights.overview',
      root: DeclarativeV1StackNode([
        DeclarativeV1TextNode('Signed plain text'),
        DeclarativeV1MetricNode(label: 'Today', value: '3'),
        DeclarativeV1ListNode(['First', 'Second']),
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DeclarativeV1Renderer(document: document)),
      ),
    );

    expect(find.text('Signed plain text'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
  });

  test(
    'renderer source has no executable or remote rendering escape hatch',
    () {
      final source = File(
        'lib/src/plugin_platform/rendering/declarative_v1_renderer.dart',
      ).readAsStringSync();
      for (final forbidden in [
        'WebView',
        'Html',
        'Uri',
        'Image.network',
        'dart:js',
        'Function',
        'onTap',
        'onPressed',
        'dynamic',
        'jsonDecode',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: forbidden);
      }
    },
  );
}
