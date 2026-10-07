import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui_preferences_controller.dart';

enum FeedToolbarAlignment { left, right }

final feedToolbarAlignmentProvider =
    NotifierProvider<FeedToolbarAlignmentNotifier, FeedToolbarAlignment>(
      FeedToolbarAlignmentNotifier.new,
    );

class FeedToolbarAlignmentNotifier extends Notifier<FeedToolbarAlignment> {
  @override
  FeedToolbarAlignment build() {
    final saved = ref.read(uiPreferencesControllerProvider.notifier)
        .read()['feedToolbarAlignment'];
    return saved == 'right'
        ? FeedToolbarAlignment.right : FeedToolbarAlignment.left;
  }

  Future<void> setAlignment(FeedToolbarAlignment alignment) async {
    if (state == alignment) return;
    state = alignment;
    ref.read(uiPreferencesControllerProvider.notifier).patch('feedToolbar', {
      'feedToolbarAlignment': alignment.name,
    });
  }
}

final immersiveWindowProvider =
    NotifierProvider<ImmersiveWindowNotifier, bool>(ImmersiveWindowNotifier.new);

class ImmersiveWindowNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(uiPreferencesControllerProvider.notifier)
      .read()['immersiveWindow'] == true;

  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    ref.read(uiPreferencesControllerProvider.notifier).patch('windowPresentation', {
      'immersiveWindow': enabled,
    });
  }
}
