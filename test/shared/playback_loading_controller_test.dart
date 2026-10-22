import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/playback_loading_controller.dart';

void main() {
  test(
    'route owners isolate phases and are released after their last listener',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = playbackLoadingProvider(Object());
      final second = playbackLoadingProvider(Object());
      final firstSubscription = container.listen(first, (_, _) {});
      final secondSubscription = container.listen(second, (_, _) {});
      final firstController = container.read(first.notifier);
      firstController.show(PlaybackLoadingPhase.expiredAddress);
      expect(container.read(first).visible, isTrue);
      expect(container.read(second).visible, isFalse);
      expect(container.read(second).phase, PlaybackLoadingPhase.preparingVideo);
      firstSubscription.close();
      await container.pump();
      expect(container.exists(first), isFalse);
      expect(container.exists(second), isTrue);
      secondSubscription.close();
      await container.pump();
      expect(container.exists(second), isFalse);
    },
  );
}
