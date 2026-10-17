import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jive/data/vod_source/vod_source_customization_store.dart';
import 'package:jive/data/vod_source/vod_source_customization_provider.dart';
import 'package:jive/data/vod_source/vod_source_presentation.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/vod_source_customization.dart';

VodSource source(String id, {int priority = 999}) => VodSource(
  id: id,
  name: '原名$id',
  baseUri: Uri.parse('https://$id.example.com'),
  adapterType: 'mac_cms_v10',
  priority: priority,
);

class RecordingStore extends VodSourceCustomizationStore {
  VodSourceCustomizations saved = VodSourceCustomizations();
  bool fail = false;

  @override
  Future<VodSourceCustomizations> load() async => saved;

  @override
  Future<void> save(VodSourceCustomizations value) async {
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('disk unavailable');
    saved = value;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('character limits preserve complete emoji accepted by the editor', () {
    final emojis = List.filled(16, '👍🏽').join();
    final value = VodSourceCustomization(displayName: emojis, note: emojis);
    expect(value.displayName, emojis);
    expect(value.note, emojis);
  });

  test('normalizes individual records and tolerates damaged neighbors', () {
    final value = VodSourceCustomizations.fromJson({
      'schemaVersion': 1,
      'sources': {
        'a': {
          'displayName': ' 常用 ',
          'tags': ['variety', 'unknown', 'variety'],
          'note': ' 更新快 ',
        },
        'broken': 42,
      },
      'pinnedSourceIds': ['a', 'a', 42, '', 'missing'],
    });
    expect(value.forSource('a').displayName, '常用');
    expect(value.forSource('a').tags, {VodContentTag.variety});
    expect(value.forSource('a').note, '更新快');
    expect(value.pinnedSourceIds, ['a', 'missing']);
    expect(value.forSource('broken').tags, isEmpty);
    expect(
      VodSourceCustomizations.fromJson({'schemaVersion': 99}).sources,
      isEmpty,
    );
  });

  test(
    'persists independent personal data without touching directory cache',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vod_source_config_remote_cache', 'directory');
      final store = VodSourceCustomizationStore(preferences: prefs);
      final value = VodSourceCustomizations()
          .update(
            'a',
            VodSourceCustomization(
              displayName: ' 别名 ',
              tags: {VodContentTag.movie},
              note: ' 老片多 ',
            ),
          )
          .togglePinned('a');
      await store.save(value);
      final loaded = await store.load();
      expect(loaded.forSource('a').displayName, '别名');
      expect(loaded.forSource('a').note, '老片多');
      expect(loaded.pinnedSourceIds, ['a']);
      expect(prefs.getString('vod_source_config_remote_cache'), 'directory');
      expect(jsonEncode(loaded.toJson()), isNot(contains('baseUri')));
    },
  );

  test('corrupt and future storage is preserved until explicit save', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = VodSourceCustomizationStore(preferences: prefs);
    for (final raw in [
      'broken json',
      '{"schemaVersion":99,"sources":{"a":{}}}',
    ]) {
      await prefs.setString(VodSourceCustomizationStore.storageKey, raw);
      expect((await store.load()).sources, isEmpty);
      expect(prefs.getString(VodSourceCustomizationStore.storageKey), raw);
    }
  });

  test(
    'bottom preferences survive edits and sort after ordinary sources',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        VodSourceCustomizationStore.storageKey,
        jsonEncode({
          'schemaVersion': 1,
          'sources': <String, dynamic>{},
          'pinnedSourceIds': ['d'],
          'demotedSourceIds': ['b', 'a', 'b', '', 42, 'd'],
        }),
      );
      final store = VodSourceCustomizationStore(preferences: prefs);
      var value = await store.load();
      final sources = [source('a'), source('b'), source('c'), source('d')];
      expect(presentVodSources(sources, value).map((s) => s.source.id), [
        'd',
        'c',
        'b',
        'a',
      ]);
      value = value
          .update('a', VodSourceCustomization(note: '备用'))
          .togglePinned('b');
      await store.save(value);
      value = await store.load();
      expect(presentVodSources(sources, value).map((s) => s.source.id), [
        'b',
        'd',
        'c',
        'a',
      ]);
      expect(value.toJson()['demotedSourceIds'], ['a']);
      expect(value.reset('a').toJson()['demotedSourceIds'], isEmpty);
    },
  );

  test(
    'presentation pins newest first and filters without mutating source identity',
    () {
      final a = source('a', priority: 1);
      final b = source('b', priority: 2);
      final c = source('c', priority: 3);
      var value = VodSourceCustomizations()
          .update(
            'b',
            VodSourceCustomization(
              displayName: '电影库',
              tags: {VodContentTag.movie},
            ),
          )
          .togglePinned('b')
          .togglePinned('c');
      expect(presentVodSources([b, c, a], value).map((v) => v.source.id), [
        'c',
        'b',
        'a',
      ]);
      final filtered = presentVodSources(
        [a, b, c],
        value,
        tag: VodContentTag.movie,
      );
      expect(filtered.single.name, '电影库');
      expect(identical(filtered.single.source, b), isTrue);
      value = value.togglePinned('b').reset('c');
      expect(presentVodSources([b, c, a], value).map((v) => v.source.id), [
        'a',
        'b',
        'c',
      ]);
      expect(value.forSource('b').tags, {VodContentTag.movie});
    },
  );

  test(
    'serial edits preserve other sources and recover after failed save',
    () async {
      final store = RecordingStore();
      final container = ProviderContainer(
        overrides: [
          vodSourceCustomizationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      await container.read(vodSourceCustomizationsProvider.future);
      final notifier = container.read(vodSourceCustomizationsProvider.notifier);
      await Future.wait([
        notifier.save('a', VodSourceCustomization(note: 'A')),
        notifier.save('b', VodSourceCustomization(note: 'B')),
        notifier.togglePinned('a'),
        notifier.togglePinned('b'),
      ]);
      expect(store.saved.forSource('a').note, 'A');
      expect(store.saved.forSource('b').note, 'B');
      expect(store.saved.pinnedSourceIds, ['b', 'a']);
      store.fail = true;
      await expectLater(notifier.reset('a'), throwsStateError);
      expect(
        container
            .read(vodSourceCustomizationsProvider)
            .requireValue
            .forSource('a')
            .note,
        'A',
      );
      store.fail = false;
      await notifier.reset('a');
      expect(store.saved.forSource('a').note, isEmpty);
      expect(store.saved.forSource('b').note, 'B');
      expect(store.saved.pinnedSourceIds, ['b']);
    },
  );

  test(
    'queued bottom operations are exclusive reversible and survive failed saves',
    () async {
      final store = RecordingStore();
      final container = ProviderContainer(
        overrides: [
          vodSourceCustomizationStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      await container.read(vodSourceCustomizationsProvider.future);
      final notifier = container.read(vodSourceCustomizationsProvider.notifier);
      await Future.wait([
        notifier.togglePinned('a'),
        notifier.toggleDemoted('a'),
        notifier.toggleDemoted('b'),
      ]);
      expect(store.saved.pinnedSourceIds, isEmpty);
      expect(store.saved.demotedSourceIds, ['a', 'b']);
      store.fail = true;
      await expectLater(notifier.toggleDemoted('a'), throwsStateError);
      expect(
        container
            .read(vodSourceCustomizationsProvider)
            .requireValue
            .demotedSourceIds,
        ['a', 'b'],
      );
      store.fail = false;
      await notifier.togglePinned('a');
      expect(store.saved.pinnedSourceIds, ['a']);
      expect(store.saved.demotedSourceIds, ['b']);
      await notifier.toggleDemoted('b');
      expect(store.saved.demotedSourceIds, isEmpty);
    },
  );
}
