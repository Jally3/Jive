import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/history_repository.dart';
import 'package:jive/domain/video.dart';
import 'package:jive/domain/watch_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'saves progress and replaces the prior record for the same video',
    () async {
      final repository = HistoryRepository();
      final first = WatchRecord(
        video: const Video(id: '1', title: '影片'),
        episodeId: '1',
        episodeName: '第1集',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: DateTime(2026),
      );
      await repository.save(first);
      await repository.save(
        WatchRecord(
          video: first.video,
          episodeId: '2',
          episodeName: '第2集',
          positionMs: 5000,
          durationMs: 10000,
          updatedAt: DateTime(2026, 2),
        ),
      );
      final records = await repository.load();
      expect(records, hasLength(1));
      expect(records.single.episodeName, '第2集');
      expect(records.single.progress, .5);
      await repository.clear();
      expect(await repository.load(), isEmpty);
    },
  );

  test(
    'serializes concurrent saves so different videos are not lost',
    () async {
      final repository = HistoryRepository();
      WatchRecord record(String id) => WatchRecord(
        video: Video(id: id, title: '影片$id'),
        episodeId: '1',
        episodeName: '正片',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: DateTime(2026, 8, 12, 0, 0, int.parse(id)),
      );
      await Future.wait([
        repository.save(record('1')),
        repository.save(record('2')),
      ]);
      final records = await repository.load();
      expect(records.map((item) => item.video.id), containsAll(['1', '2']));
    },
  );

  test(
    'load waits for an unawaited player save already in the queue',
    () async {
      final repository = HistoryRepository();
      unawaited(
        repository.save(
          WatchRecord(
            video: const Video(id: '1', title: '影片'),
            episodeId: '1',
            episodeName: '正片',
            positionMs: 5000,
            durationMs: 10000,
            updatedAt: DateTime(2026, 8, 20),
          ),
        ),
      );

      final records = await repository.load();

      expect(records.single.positionMs, 5000);
    },
  );

  test('normalizes corrupt progress and restores completed state', () async {
    SharedPreferences.setMockInitialValues({
      'watch_history_v1':
          '[{"video":{"id":"1","title":"影片"},"episodeId":"1",'
          '"episodeName":"正片","positionMs":99999,"durationMs":1000,'
          '"completed":true,"updatedAt":"2026-08-12T00:00:00.000"}]',
    });
    final record = (await HistoryRepository().load()).single;
    expect(record.positionMs, 1000);
    expect(record.durationMs, 1000);
    expect(record.completed, isTrue);
  });

  test('sorts newest first and keeps at most fifty videos', () async {
    final repository = HistoryRepository();
    for (var index = 0; index < 55; index++) {
      await repository.save(
        WatchRecord(
          video: Video(id: '$index', title: '影片$index'),
          episodeId: '1',
          episodeName: '正片',
          positionMs: index,
          durationMs: 100,
          updatedAt: DateTime(2026, 1, 1).add(Duration(minutes: index)),
        ),
      );
    }
    final records = await repository.load();
    expect(records, hasLength(50));
    expect(records.first.video.id, '54');
    expect(records.last.video.id, '5');
  });

  test('v2 records preserve stable identities and timeline metadata', () async {
    final repository = HistoryRepository();
    await repository.save(
      WatchRecord(
        video: Video(id: '1', title: '影片'),
        episodeId: '3',
        episodeName: '第3集',
        positionMs: 5000,
        durationMs: 10000,
        updatedAt: DateTime(2026, 3),
        playbackLineIdentity: 'macv10:line:0:linea',
        episodeIdentity: 'macv10:episode:2:第3集',
        filterVersion: 0,
        timelineVersion: 0,
      ),
    );
    final record = (await repository.load()).single;
    expect(record.playbackLineIdentity, 'macv10:line:0:linea');
    expect(record.episodeIdentity, 'macv10:episode:2:第3集');
    expect(record.timelineType, 'source');
    expect(record.filterVersion, 0);
  });

  test('v1 records without schemaVersion load as implicit v1', () async {
    SharedPreferences.setMockInitialValues({
      'watch_history_v1':
          '[{"video":{"id":"1","title":"影片"},"episodeId":"1",'
          '"episodeName":"正片","positionMs":1000,"durationMs":10000,'
          '"completed":false,"updatedAt":"2026-08-12T00:00:00.000"}]',
    });
    final record = (await HistoryRepository().load()).single;
    expect(record.playbackLineIdentity, '');
    expect(record.episodeIdentity, '');
    expect(record.filterVersion, 0);
    expect(record.timelineVersion, 0);
  });

  test('classifies movies and series from category or episode name', () {
    WatchRecord record({String category = '', String episodeName = ''}) =>
        WatchRecord(
          video: Video(id: '1', title: '片', category: category),
          episodeId: '1',
          episodeName: episodeName,
          positionMs: 1000,
          durationMs: 10000,
          updatedAt: DateTime(2026),
        );
    expect(isMovieWatchRecord(record(category: '电影片')), isTrue);
    expect(isMovieWatchRecord(record(episodeName: '正片')), isTrue);
    expect(isMovieWatchRecord(record(category: '连续剧')), isFalse);
    expect(isMovieWatchRecord(record(category: '电视剧')), isFalse);
    expect(isMovieWatchRecord(record(episodeName: '第3集')), isFalse);
    expect(isMovieWatchRecord(record(category: '动漫')), isFalse);
  });

  test('home continue watching picks one eligible record', () {
    final movieMid = WatchRecord(
      video: const Video(id: '1', title: '进行中电影', category: '电影片'),
      episodeId: '1',
      episodeName: '正片',
      positionMs: 5000,
      durationMs: 10000,
      updatedAt: DateTime(2026, 3),
    );
    final seriesDone = WatchRecord(
      video: const Video(id: '2', title: '已播完剧', category: '连续剧'),
      episodeId: '1',
      episodeName: '第1集',
      positionMs: 10000,
      durationMs: 10000,
      updatedAt: DateTime(2026, 2),
      completed: true,
    );
    final movieLate = WatchRecord(
      video: const Video(id: '3', title: '快看完的电影', category: '电影片'),
      episodeId: '1',
      episodeName: '正片',
      positionMs: 8000,
      durationMs: 10000,
      updatedAt: DateTime(2026, 4),
    );
    final noProgress = WatchRecord(
      video: const Video(id: '4', title: '无进度', category: '连续剧'),
      episodeId: '1',
      episodeName: '第1集',
      positionMs: 0,
      durationMs: 10000,
      updatedAt: DateTime(2026, 5),
    );
    expect(homeContinueWatchingRecord([movieLate])?.video.id, isNull);
    expect(homeContinueWatchingRecord([noProgress])?.video.id, isNull);
    expect(homeContinueWatchingRecord([seriesDone])?.video.id, '2');
    expect(
      homeContinueWatchingRecord([movieLate, movieMid, seriesDone])?.video.id,
      '1',
    );
  });

  test('removes a single video without clearing the rest', () async {
    final repository = HistoryRepository();
    await repository.save(
      WatchRecord(
        video: const Video(id: '1', title: '影片1'),
        episodeId: '1',
        episodeName: '第1集',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: DateTime(2026, 1),
      ),
    );
    await repository.save(
      WatchRecord(
        video: const Video(id: '2', title: '影片2'),
        episodeId: '1',
        episodeName: '第1集',
        positionMs: 2000,
        durationMs: 10000,
        updatedAt: DateTime(2026, 2),
      ),
    );
    await repository.remove(const Video(id: '1', title: '影片1').globalId);
    final records = await repository.load();
    expect(records, hasLength(1));
    expect(records.single.video.id, '2');
  });

  test('one corrupt or unknown-version record does not wipe history', () async {
    SharedPreferences.setMockInitialValues({
      'watch_history_v1':
          '[{"schemaVersion":9,"video":{"id":"bad"}},'
          '{"schemaVersion":2,"video":{"id":"2","title":"好影片"},'
          '"episodeId":"1","episodeName":"正片","positionMs":100,'
          '"durationMs":1000,"updatedAt":"2026-08-12T00:00:00.000"}]',
    });
    final records = await HistoryRepository().load();
    expect(records, hasLength(1));
    expect(records.single.video.id, '2');
  });
}
