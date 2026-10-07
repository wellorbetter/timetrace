import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/preferences/presentation_preferences_provider.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/feed/providers/feed_preferences_provider.dart';
import 'package:timetrace_app/src/features/settings/presentation/feed_view_settings.dart';

class FakeMinutes extends FeedBucketMinutesNotifier {
  @override
  int build() => 10;
  @override
  void setMinutes(int minutes) {
    if (validFeedBucketMinutes(minutes)) state = minutes;
  }
}

class FakeMode extends FeedDisplayModeNotifier {
  @override
  FeedDisplayMode build() => FeedDisplayMode.overview;
  @override
  void setMode(FeedDisplayMode value) => state = value;
}

void main() {
  for (final width in [280.0,720.0,1100.0]) {
    for (final scale in [1.0,2.0]) {
      testWidgets('toolbar settings preserve custom draft $width scale$scale', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = MemoryPreferencesBackend();
        final container = ProviderContainer(overrides: [
          uiPreferencesBackendProvider.overrideWithValue(backend),
          feedBucketMinutesProvider.overrideWith(FakeMinutes.new),
          feedDisplayModeProvider.overrideWith(FakeMode.new),
        ]);
        addTearDown(container.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: Scaffold(body: MediaQuery(
            data: MediaQueryData(size: Size(width,1000), textScaler: TextScaler.linear(scale)),
            child: const SingleChildScrollView(child: FeedViewSettings()),
          ))),
        ));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('feed_custom_minutes')));
        await tester.tap(find.byKey(const Key('feed_custom_minutes')));
        await tester.pumpAndSettle();
        final input = find.descendant(of: find.byKey(const Key('custom_feed_minutes')),
          matching: find.byType(TextField));
        await tester.enterText(input, '0');
        final controller = tester.widget<TextField>(input).controller!;
        controller.selection = const TextSelection.collapsed(offset: 1);
        for (final alignment in FeedToolbarAlignment.values.reversed) {
          final button = find.byKey(ValueKey('feed_toolbar_${alignment.name}'));
          await tester.ensureVisible(button);
          expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(container.read(feedToolbarAlignmentProvider), alignment);
          expect(tester.widget<TextField>(input).controller, same(controller));
          expect(controller.text, '0');
          expect(controller.selection, const TextSelection.collapsed(offset: 1));
          expect(container.read(feedBucketMinutesProvider), 10);
        }
        expect(backend.commits, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('compact presets and custom minutes have no box borders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiPreferencesBackendProvider.overrideWithValue(MemoryPreferencesBackend()),
          feedBucketMinutesProvider.overrideWith(FakeMinutes.new),
          feedDisplayModeProvider.overrideWith(FakeMode.new),
        ],
        child: const MaterialApp(home: Scaffold(body: FeedViewSettings())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('feed-minute-30')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('feed-minute-30')))
          .selected,
      isTrue,
    );
    final custom = find.byKey(const Key('custom_feed_minutes'));
    expect(custom, findsNothing);
    await tester.tap(find.byKey(const Key('feed_custom_minutes')));
    await tester.pumpAndSettle();
    await tester.enterText(custom, '22');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('feed_custom_minutes')))
          .selected,
      isTrue,
    );
    expect(custom, findsNothing);
    await tester.tap(find.byKey(const Key('feed_custom_minutes')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.descendant(of: custom, matching: find.byType(TextField)),
          )
          .decoration
          ?.border,
      isA<UnderlineInputBorder>(),
    );
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(
      find.descendant(of: custom, matching: find.byType(TextField)),
    );
    expect(field.decoration!.helperText, isNull);
    await tester.enterText(custom, '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–1440 之间的整数'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('feed_custom_minutes')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('feed_display_mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '窗口优先'));
    await tester.pumpAndSettle();
    expect(find.text('展示方式：窗口优先'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
