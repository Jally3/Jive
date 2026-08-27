import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/data/download/download_providers.dart';
import 'package:jive/data/download/download_task_manager.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/features/splash/splash_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testSource = VodSource(
  id: 'storm',
  name: '测试源',
  baseUri: Uri.parse('https://test.example.com/api.php/provide/vod'),
  adapterType: 'mac_cms_v10',
);

class _FakeRepository implements VideoRepository {
  @override
  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  }) async => const VideoPage(items: [], page: 1, pageCount: 1);

  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async =>
      const [];

  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => const Video(id: '1', title: 't');

  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

ProviderContainer _container({
  required Future<VodSourceRegistry> Function() registry,
}) => ProviderContainer(
  overrides: [
    videoRepositoryProvider.overrideWithValue(_FakeRepository()),
    vodSourceRegistryProvider.overrideWith((ref) => registry()),
    downloadTasksProvider.overrideWith(
      (ref) => Stream.value(const <DownloadTask>[]),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows logo and Jive while sources are loading', (tester) async {
    final gate = Completer<VodSourceRegistry>();
    final container = _container(registry: () => gate.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-logo')), findsOneWidget);
    expect(find.text('Jive'), findsOneWidget);
    expect(find.byKey(const ValueKey('floating-nav-bar')), findsNothing);

    gate.complete(VodSourceRegistry([_testSource], const {}));
    await tester.pump();
    await tester.pump(splashMinHold);
  });

  testWidgets('keeps splash until the minimum hold elapses', (tester) async {
    final container = _container(
      registry: () async => VodSourceRegistry([_testSource], const {}),
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('splash-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('floating-nav-bar')), findsNothing);

    await tester.pump(splashMinHold);
    expect(find.byKey(const ValueKey('splash-page')), findsNothing);
    expect(find.byKey(const ValueKey('floating-nav-bar')), findsOneWidget);
  });

  testWidgets('source failure shows retry and can recover', (tester) async {
    var shouldFail = true;
    final container = _container(
      registry: () async {
        if (shouldFail) {
          return VodSourceRegistry(const [], const {});
        }
        return VodSourceRegistry([_testSource], const {});
      },
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-page')), findsNothing);

    shouldFail = false;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('splash-page')), findsOneWidget);

    await tester.pump(splashMinHold);
    expect(find.byKey(const ValueKey('floating-nav-bar')), findsOneWidget);
  });
}
