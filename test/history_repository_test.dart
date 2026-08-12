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
}
