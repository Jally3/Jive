import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/offline_progress_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

WatchRecord _record(int episode, {int positionMs = 1000}) => WatchRecord(
  video: const Video(
    id: 'video',
    title: '影片',
    sourceId: 'source',
    sourceVideoId: 'video',
  ),
  episodeId: '$episode',
  episodeName: '第$episode集',
  episodeIdentity: 'episode-$episode',
  playbackLineIdentity: 'line',
  positionMs: positionMs,
  durationMs: 10000,
  updatedAt: DateTime(2026).add(Duration(minutes: episode)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('replaces the same downloaded episode progress', () async {
    final repository = OfflineProgressRepository();
    await repository.saveWatchRecord(_record(1));
    await repository.saveWatchRecord(_record(1, positionMs: 7000));

    final records = await repository.load();
    expect(records, hasLength(1));
    expect(records.single.positionMs, 7000);
    expect(records.single.progress, .7);
  });

  test('keeps only the one hundred most recent episode records', () async {
    final repository = OfflineProgressRepository();
    for (var episode = 1; episode <= 105; episode++) {
      await repository.saveWatchRecord(_record(episode));
    }

    final records = await repository.load();
    expect(records, hasLength(offlineProgressLimit));
    expect(records.first.key, endsWith('episode-105'));
    expect(records.last.key, endsWith('episode-6'));
  });
}
