import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/app/app.dart';
import 'package:jive/data/video_repository.dart';
import 'package:jive/data/vod_source_registry.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/shared/video_grid.dart';
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
  }) async => VideoPage(
    items: List.generate(
      20,
      (i) => Video(id: '$i', title: '影片$i', typeId: 1, category: '电影片'),
    ),
    page: page,
    pageCount: 99,
  );
  @override
  Future<List<VideoCategory>> fetchCategories(VodSource source) async => const [
    VideoCategory(id: 1, name: '电影片'),
  ];
  @override
  Future<Video> fetchDetail(
    VodSource source,
    VideoRef ref, {
    bool forceRefresh = false,
  }) async => const Video(id: '1', title: 't', typeId: 1, category: 'c');
  @override
  Future<Video> resolvePlayback(VodSource source, VideoRef ref) =>
      fetchDetail(source, ref);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home grid extends behind the floating nav bar', (tester) async {
    final container = ProviderContainer(
      overrides: [
        videoRepositoryProvider.overrideWithValue(_FakeRepository()),
        vodSourceRegistryProvider.overrideWith(
          (ref) async => VodSourceRegistry([_testSource], {}),
        ),
      ],
    );
    await container.read(vodSourceRegistryProvider.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const JiveApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final grid = tester.getRect(find.byType(VideoGrid));
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    // ignore: avoid_print
    print('grid: $grid scaffold: $scaffold');
    expect(grid.bottom, scaffold.bottom);
  });
}
