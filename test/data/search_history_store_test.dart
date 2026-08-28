import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/search_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ignores blank keywords and moves repeats to the front', () async {
    expect(await SearchHistoryStore.add('  '), isEmpty);
    await SearchHistoryStore.add('海贼王');
    await SearchHistoryStore.add('进击的巨人');
    final history = await SearchHistoryStore.add('海贼王');
    expect(history, ['海贼王', '进击的巨人']);
  });

  test('caps history at twenty keywords and supports remove/clear', () async {
    for (var index = 0; index < 25; index++) {
      await SearchHistoryStore.add('词$index');
    }
    final loaded = await SearchHistoryStore.load();
    expect(loaded, hasLength(20));
    expect(loaded.first, '词24');
    expect(loaded.last, '词5');
    expect(await SearchHistoryStore.remove('词24'), isNot(contains('词24')));
    await SearchHistoryStore.clear();
    expect(await SearchHistoryStore.load(), isEmpty);
  });
}
