import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/library_repository.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/video.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const video = Video(
    id: '1',
    title: '影片',
    posterUrl: 'poster',
    typeId: 20,
    category: '电影',
    episodes: [Episode(id: 'ep', name: '正片', url: 'https://secret')],
  );
  final now = DateTime.utc(2026, 8, 12);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'favorites persist snapshots without playback urls and deduplicate',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repository = LibraryRepository(preferences: prefs, now: () => now);
      await repository.saveFavorite(
        FavoriteRecord(video: video, createdAt: now, updatedAt: now),
      );
      await repository.saveFavorite(
        FavoriteRecord(
          video: video,
          createdAt: now.add(const Duration(days: 1)),
          updatedAt: now.add(const Duration(days: 1)),
        ),
      );
      final records = await repository.loadFavorites();
      expect(records, hasLength(1));
      expect(records.single.createdAt, now);
      expect(records.single.video.episodes, isEmpty);
      expect(
        prefs.getString(LibraryRepository.favoritesKey),
        isNot(contains('secret')),
      );
    },
  );

  test('corrupt json and incomplete items are ignored', () async {
    SharedPreferences.setMockInitialValues({
      LibraryRepository.favoritesKey: '[broken',
      LibraryRepository.playlistsKey: jsonEncode([
        {'id': 'bad'},
        {
          'id': 'ok',
          'name': '列表',
          'videos': [],
          'createdAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
        },
      ]),
    });
    final repository = LibraryRepository(
      preferences: await SharedPreferences.getInstance(),
    );
    expect(await repository.loadFavorites(), isEmpty);
    expect(await repository.loadPlaylists(), hasLength(1));
  });

  test('playlists validate names, preserve order and deduplicate', () async {
    final repository = LibraryRepository(
      preferences: await SharedPreferences.getInstance(),
      now: () => now,
    );
    await expectLater(repository.createPlaylist(' '), throwsArgumentError);
    await expectLater(
      repository.createPlaylist(List.filled(41, 'x').join()),
      throwsArgumentError,
    );
    final playlist = await repository.createPlaylist(' 周末 ');
    await repository.addToPlaylist(playlist.id, video);
    await repository.addToPlaylist(playlist.id, video);
    await repository.addToPlaylist(
      playlist.id,
      const Video(id: '2', title: '第二部'),
    );
    expect((await repository.loadPlaylists()).single.videos.map((v) => v.id), [
      '1',
      '2',
    ]);
    await repository.removeFromPlaylist(playlist.id, '1');
    expect((await repository.loadPlaylists()).single.videos.single.id, '2');
    await repository.deletePlaylist(playlist.id);
    expect(await repository.loadPlaylists(), isEmpty);
  });
}
