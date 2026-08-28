import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/playback/skip_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldSkipIntro', () {
    test('stays off when disabled or clip is shorter than intro', () {
      expect(
        shouldSkipIntro(
          introSeconds: 0,
          position: Duration.zero,
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
      expect(
        shouldSkipIntro(
          introSeconds: 90,
          position: Duration.zero,
          duration: const Duration(seconds: 80),
        ),
        isFalse,
      );
    });

    test('applies near the start and not after the intro window', () {
      expect(
        shouldSkipIntro(
          introSeconds: 90,
          position: Duration.zero,
          duration: const Duration(minutes: 10),
        ),
        isTrue,
      );
      expect(
        shouldSkipIntro(
          introSeconds: 90,
          position: const Duration(seconds: 89),
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
    });
  });

  group('shouldSkipOutro', () {
    test('applies in the outro window and not when too close to the end', () {
      expect(
        shouldSkipOutro(
          outroSeconds: 60,
          position: const Duration(minutes: 9, seconds: 10),
          duration: const Duration(minutes: 10),
        ),
        isTrue,
      );
      expect(
        shouldSkipOutro(
          outroSeconds: 60,
          position: const Duration(minutes: 9, seconds: 59),
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
      expect(
        shouldSkipOutro(
          outroSeconds: 60,
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 10),
        ),
        isFalse,
      );
    });
  });

  test('skipDurationLabel distinguishes presets, custom and off', () {
    expect(skipDurationLabel(0), '关闭');
    expect(skipDurationLabel(30), '30 秒');
    expect(skipDurationLabel(45), '自定义 · 45 秒');
  });

  test('stores skip durations per video and defaults to off', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      await container.read(skipPolicyProvider('storm:1').future),
      const SkipPolicy(),
    );
    await container
        .read(skipPolicyProvider('storm:1').notifier)
        .setIntroSeconds(90);
    await container
        .read(skipPolicyProvider('storm:1').notifier)
        .setOutroSeconds(45);
    expect(
      container.read(skipPolicyProvider('storm:1')).value,
      const SkipPolicy(introSeconds: 90, outroSeconds: 45),
    );
    expect(
      await container.read(skipPolicyProvider('storm:2').future),
      const SkipPolicy(),
    );
    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString(skipPolicyStoreKey)!)
            as Map<String, dynamic>;
    expect(stored['storm:1'], {'introSeconds': 90, 'outroSeconds': 45});
    expect(stored.containsKey('storm:2'), isFalse);
  });
}
