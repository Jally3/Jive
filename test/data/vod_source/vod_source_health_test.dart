import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_health_provider.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _source = VodSource(
  id: 'a',
  name: 'A',
  baseUri: Uri.parse('https://a.example.com'),
  adapterType: 'mac_cms_v10',
);

class _Repository implements VideoRepository {
  final pending = Completer<VideoPage>();
  int calls = 0;
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) {
    calls++;
    return pending.future;
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => throw UnimplementedError();
  @override
  Future<Video> resolvePlayback(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => fetchDetail(source, ref);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final throwsOnWrite in [false, true]) {
    test(
      'health write failure keeps the old result and permits retry (throws=$throwsOnWrite)',
      () async {
        SharedPreferences.setMockInitialValues({
          'source_health_a':
              '{"ok":true,"latencyMs":120,"checkedAt":"2026-10-17T12:00:00"}',
        });
        final prefs = _FailingPreferences(
          await SharedPreferences.getInstance(),
          throwsOnWrite,
        );
        final repository = _Repository();
        repository.pending.complete(
          const VideoPage(items: [], page: 1, pageCount: 1),
        );
        final container = ProviderContainer(
          overrides: [
            videoRepositoryProvider.overrideWithValue(repository),
            vodSourceHealthPreferencesProvider.overrideWith(
              (ref) async => prefs,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(vodSourceHealthProvider.future);
        final notifier = container.read(vodSourceHealthProvider.notifier);
        await expectLater(notifier.check(_source), throwsStateError);
        final failed = container.read(vodSourceHealthProvider).requireValue;
        expect(failed.checking, isEmpty);
        expect(failed.results['a']!.latencyMs, 120);
        expect(failed.results['a']!.checkedAt, DateTime(2026, 10, 17, 12));
        prefs.fail = false;
        await notifier.check(_source);
        expect(
          container
              .read(vodSourceHealthProvider)
              .requireValue
              .results['a']!
              .checkedAt,
          isNot(DateTime(2026, 10, 17, 12)),
        );
        expect(
          container.read(vodSourceHealthProvider).requireValue.checking,
          isEmpty,
        );
      },
    );
  }

  test(
    'historical health loads independently without probing or damaged neighbors',
    () async {
      SharedPreferences.setMockInitialValues({
        'source_health_a':
            '{"ok":true,"latencyMs":120,"checkedAt":"2026-10-17T12:00:00"}',
        'source_health_b': 'broken',
        'source_health_c': 42,
      });
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [videoRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final state = await container.read(vodSourceHealthProvider.future);
      expect(state.results.keys, ['a']);
      expect(state.results['a']!.latencyMs, 120);
      expect(repository.calls, 0);
    },
  );

  test(
    'shared health deduplicates checks and releases in-flight state after failure',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [videoRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      await container.read(vodSourceHealthProvider.future);
      final notifier = container.read(vodSourceHealthProvider.notifier);
      final first = notifier.check(_source);
      final duplicate = notifier.check(_source);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, 1);
      expect(container.read(vodSourceHealthProvider).requireValue.checking, {
        'a',
      });
      repository.pending.completeError(StateError('unreachable'));
      await Future.wait([first, duplicate]);
      final state = container.read(vodSourceHealthProvider).requireValue;
      expect(state.checking, isEmpty);
      expect(state.results['a']!.ok, isFalse);
      expect(state.results['a']!.message, contains('unreachable'));
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('source_health_a')!)['ok'], false);
      expect(prefs.getString('selected_vod_source_id'), isNull);
    },
  );
}

class _FailingPreferences implements SharedPreferences {
  _FailingPreferences(this.delegate, this.throwsOnWrite);
  final SharedPreferences delegate;
  final bool throwsOnWrite;
  bool fail = true;
  @override
  Set<String> getKeys() => delegate.getKeys();
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  Future<bool> setString(String key, String value) async {
    if (fail && throwsOnWrite) throw StateError('disk unavailable');
    if (fail) return false;
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
