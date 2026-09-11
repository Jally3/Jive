import 'package:flutter_test/flutter_test.dart';
import 'package:jive/domain/library.dart';
import 'package:jive/domain/video.dart';

void main() {
  test('episode signature prefers identity and excludes playback urls', () {
    const episodes = [
      Episode(
        id: '1',
        name: '第 1 集',
        identity: 'stable-1',
        url: 'https://secret.example/one.m3u8',
      ),
      Episode(id: 'special', name: ' 特 别 篇 ', url: 'https://secret/two'),
    ];
    final signature = episodeVersionSignature(episodes);
    expect(signature, contains('i:stable-1'));
    expect(signature, contains(Uri.encodeComponent('特别篇')));
    expect(signature, isNot(contains('secret')));
  });

  test('episodic content is followable but completed content is not', () {
    const episodes = [
      Episode(id: '1', name: '第1集', url: ''),
      Episode(id: '2', name: '第2集', url: ''),
    ];
    expect(
      const Video(
        id: 'series',
        title: '剧集',
        category: '电视剧',
        remarks: '更新至2集',
        episodes: episodes,
      ).supportsFollowUpdates,
      isTrue,
    );
    expect(
      const Video(
        id: 'done',
        title: '剧集',
        category: '电视剧',
        remarks: '全12集完结',
        episodes: episodes,
      ).supportsFollowUpdates,
      isFalse,
    );
  });
}
