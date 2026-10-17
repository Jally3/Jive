import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_customization_provider.dart';
import 'package:jive/data/vod_source/vod_source_customization_store.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/domain/vod_source_customization.dart';
import 'package:jive/features/detail/detail_more_sources_sheet.dart';
import 'package:jive/features/detail/detail_source_controller.dart';
import 'package:jive/features/detail/widgets/detail_source_section.dart';
import 'package:jive/features/search/search_launch_request.dart';
import 'package:jive/features/search/search_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _sources = [
  for (final entry in {
    'a': 'Alpha',
    'b': 'Beta',
    'c': 'Gamma',
    'd': 'Delta',
  }.entries)
    VodSource(
      id: entry.key,
      name: entry.value,
      baseUri: Uri.parse('https://${entry.key}.example.com'),
      adapterType: 'mac_cms_v10',
    ),
];

class _MemoryStore extends VodSourceCustomizationStore {
  VodSourceCustomizations value = VodSourceCustomizations()
      .togglePinned('c')
      .togglePinned('d');
  @override
  Future<VodSourceCustomizations> load() async => value;
  @override
  Future<void> save(VodSourceCustomizations next) async {
    value = next;
  }
}

class _Repository implements VideoRepository {
  final List<String> searches = [];
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async {
    searches.add(source.id);
    return VideoPage(
      items: [Video(id: 'v', title: '影片', sourceId: source.id)],
      page: 1,
      pageCount: 1,
    );
  }

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => [];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => Video(id: ref.sourceVideoId, title: '影片', sourceId: source.id);
  @override
  Future<Video> resolvePlayback(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) => fetchDetail(source, ref);
}

ProviderContainer _container(_Repository repository) {
  final container = ProviderContainer(
    overrides: [
      vodSourceCustomizationStoreProvider.overrideWithValue(_MemoryStore()),
      vodSourceRegistryProvider.overrideWith(
        (ref) async => VodSourceRegistry(_sources, {}),
      ),
      videoRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _search(WidgetTester tester, ProviderContainer container) async {
  await container.read(vodSourceRegistryProvider.future);
  await container.read(vodSourceCustomizationsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SearchPage())),
    ),
  );
  await tester.pumpAndSettle();
  container
      .read(searchLaunchRequestProvider.notifier)
      .launch(
        keyword: '影片',
        sourceId: 'a',
        mode: SearchLaunchMode.reviewCurrentSource,
      );
  await tester.pumpAndSettle();
}

Finder _text(String value) => find.textContaining(value).hitTestable();

void main() {
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({'selected_vod_source_id': 'a'}),
  );

  testWidgets(
    'search chips show pinned unqueried sources in shared order without fetching',
    (tester) async {
      final repository = _Repository();
      final container = _container(repository);
      await _search(tester, container);
      expect(_text('Delta'), findsOneWidget);
      expect(_text('Gamma'), findsOneWidget);
      expect(
        tester.getTopLeft(_text('Alpha')).dx,
        lessThan(tester.getTopLeft(_text('Delta')).dx),
      );
      expect(
        tester.getTopLeft(_text('Delta')).dx,
        lessThan(tester.getTopLeft(_text('Gamma')).dx),
      );
      expect(repository.searches, ['a']);
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('b');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Beta')).dx,
        lessThan(tester.getTopLeft(_text('Delta')).dx),
      );
      expect(repository.searches, ['a']);
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('b');
      await tester.pumpAndSettle();
      expect(_text('Beta'), findsNothing);
      await tester.tap(_text('Delta'));
      await tester.pumpAndSettle();
      expect(repository.searches, contains('d'));
    },
  );

  testWidgets('search all sources reorders live when pinning changes', (
    tester,
  ) async {
    final repository = _Repository();
    final container = _container(repository);
    await _search(tester, container);
    await tester.tap(find.text('更多 ▾'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_text('Delta')).dy,
      lessThan(tester.getTopLeft(_text('Alpha')).dy),
    );
    expect(
      tester.getTopLeft(_text('Delta')).dy,
      lessThan(tester.getTopLeft(_text('Gamma')).dy),
    );
    await container
        .read(vodSourceCustomizationsProvider.notifier)
        .togglePinned('b');
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_text('Beta')).dy,
      lessThan(tester.getTopLeft(_text('Delta')).dy),
    );
    expect(repository.searches, ['a']);
    await container
        .read(vodSourceCustomizationsProvider.notifier)
        .togglePinned('d');
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_text('Alpha')).dy,
      lessThan(tester.getTopLeft(_text('Delta')).dy),
    );
    await container
        .read(vodSourceCustomizationsProvider.notifier)
        .toggleDemoted('b');
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_text('Beta')).dy,
      greaterThan(tester.getTopLeft(_text('Delta')).dy),
    );
    expect(repository.searches, ['a']);
  });

  testWidgets(
    'detail source bar exposes pinned sources and tracks live order without probing',
    (tester) async {
      final repository = _Repository();
      final container = _container(repository);
      await container.read(vodSourceCustomizationsProvider.future);
      final controller = DetailSourceController(
        repository: repository,
        registry: VodSourceRegistry(_sources, {}),
        initialVideo: const Video(id: 'v', title: '影片', sourceId: 'a'),
      );
      addTearDown(controller.dispose);
      String? tapped;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: DetailSourceSection(
                controller: controller,
                onChipTap: (state) => tapped = state.source.id,
                onMoreSources: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_text('Delta'), findsOneWidget);
      expect(
        tester.getTopLeft(_text('Alpha')).dx,
        lessThan(tester.getTopLeft(_text('Delta')).dx),
      );
      expect(
        tester.getTopLeft(_text('Delta')).dx,
        lessThan(tester.getTopLeft(_text('Gamma')).dx),
      );
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('b');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Beta')).dx,
        lessThan(tester.getTopLeft(_text('Delta')).dx),
      );
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('b');
      await tester.pumpAndSettle();
      expect(_text('Beta'), findsNothing);
      await tester.tap(_text('Delta'));
      expect(tapped, 'd');
      expect(controller.activeSourceId, 'a');
      expect(repository.searches, isEmpty);
    },
  );

  testWidgets(
    'detail all sources shares ordering and preserves source callbacks',
    (tester) async {
      final repository = _Repository();
      final container = _container(repository);
      await container.read(vodSourceCustomizationsProvider.future);
      final controller = DetailSourceController(
        repository: repository,
        registry: VodSourceRegistry(_sources, {}),
        initialVideo: const Video(id: 'v', title: '影片', sourceId: 'a'),
      );
      addTearDown(controller.dispose);
      String? tapped;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: DetailMoreSourcesSheet(
                sources: _sources,
                controller: controller,
                onSourceTap: (id) => tapped = id,
                onDetectAll: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Delta')).dy,
        lessThan(tester.getTopLeft(_text('Alpha')).dy),
      );
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('b');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Beta')).dy,
        lessThan(tester.getTopLeft(_text('Delta')).dy),
      );
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .togglePinned('d');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Alpha')).dy,
        lessThan(tester.getTopLeft(_text('Delta')).dy),
      );
      await container
          .read(vodSourceCustomizationsProvider.notifier)
          .toggleDemoted('c');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(_text('Gamma')).dy,
        greaterThan(tester.getTopLeft(_text('Delta')).dy),
      );
      await tester.tap(_text('Gamma'));
      expect(tapped, 'c');
      expect(repository.searches, isEmpty);
      expect(controller.activeSourceId, 'a');
    },
  );
}
