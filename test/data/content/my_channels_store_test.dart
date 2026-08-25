import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/content/my_channels_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('returns null when nothing was saved', () async {
    expect(await MyChannelsStore.load('storm'), isNull);
  });

  test('save then load round-trips ids in order', () async {
    await MyChannelsStore.save('storm', [3, 1, 7]);
    expect(await MyChannelsStore.load('storm'), [3, 1, 7]);
  });

  test('stores channels per source independently', () async {
    await MyChannelsStore.save('a', [1]);
    await MyChannelsStore.save('b', [2, 3]);
    expect(await MyChannelsStore.load('a'), [1]);
    expect(await MyChannelsStore.load('b'), [2, 3]);
  });

  test('reset removes the saved record', () async {
    await MyChannelsStore.save('storm', [1, 2]);
    await MyChannelsStore.reset('storm');
    expect(await MyChannelsStore.load('storm'), isNull);
  });
}
