import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/cache_manager.dart';
import 'package:jive/data/download/platform_disk_space.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jive/cache');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final provider = PlatformDiskSpaceProvider();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('missing space channel is not reported as an empty disk', () async {
    await expectLater(
      provider.availableBytes(),
      throwsA(isA<DiskSpaceQueryException>()),
    );
  });

  test('platform query errors are not reported as an empty disk', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'disk_space_unavailable');
    });
    await expectLater(
      provider.availableBytes(),
      throwsA(isA<DiskSpaceQueryException>()),
    );
  });

  test('null and negative space readings are rejected', () async {
    for (final value in <int?>[null, -1]) {
      messenger.setMockMethodCallHandler(channel, (_) async => value);
      await expectLater(
        provider.availableBytes(),
        throwsA(isA<DiskSpaceQueryException>()),
      );
    }
  });

  test('a real zero reading remains zero', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 0);
    expect(await provider.availableBytes(), 0);
  });

  test('space readings above 32 bits are preserved', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'availableBytes' => 7516192768,
        'totalCapacityBytes' => 10737418240,
        _ => null,
      };
    });
    expect(await provider.availableBytes(), 7516192768);
    expect(await provider.totalCapacityBytes(), 10737418240);
    expect(await provider.platformCacheLimitBytes(), isNull);
  });
}
