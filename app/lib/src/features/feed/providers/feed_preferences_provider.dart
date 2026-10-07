import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/preferences/ui_preferences_controller.dart';

bool validFeedBucketMinutes(int minutes) => minutes >= 1 && minutes <= 1440;
DateTime floorFeedBucketLocal(DateTime value, int minutes) {
  if (!validFeedBucketMinutes(minutes))
    throw ArgumentError.value(minutes, 'minutes');
  final offset = ((value.hour * 60 + value.minute) ~/ minutes) * minutes;
  return DateTime(
    value.year,
    value.month,
    value.day,
  ).add(Duration(minutes: offset));
}

enum FeedDisplayMode { overview, apps, windows }

final feedDisplayModeProvider =
    NotifierProvider<FeedDisplayModeNotifier, FeedDisplayMode>(
      FeedDisplayModeNotifier.new,
    );

class FeedDisplayModeNotifier extends Notifier<FeedDisplayMode> {
  @override
  FeedDisplayMode build() {
    final saved = ref
        .read(uiPreferencesControllerProvider.notifier)
        .read()['feedDisplayMode'];
    return FeedDisplayMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => FeedDisplayMode.overview,
    );
  }

  void setMode(FeedDisplayMode mode) {
    state = mode;
    ref.read(uiPreferencesControllerProvider.notifier).patch('feedMode', {
      'feedDisplayMode': mode.name,
    });
  }
}

final feedBucketMinutesProvider =
    NotifierProvider<FeedBucketMinutesNotifier, int>(
      FeedBucketMinutesNotifier.new,
    );

class FeedBucketMinutesNotifier extends Notifier<int> {
  @override
  int build() {
    final saved = ref
        .read(uiPreferencesControllerProvider.notifier)
        .read()['feedBucketMinutes'];
    return saved is int && validFeedBucketMinutes(saved) ? saved : 10;
  }

  void setMinutes(int minutes) {
    if (!validFeedBucketMinutes(minutes) || state == minutes) {
      return;
    }
    state = minutes;
    ref.read(uiPreferencesControllerProvider.notifier).patch('feedMinutes', {
      'feedBucketMinutes': minutes,
    });
  }
}
