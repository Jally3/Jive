import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/cache/single_flight.dart';

void main() {
  group('SingleFlight', () {
    test('deduplicates concurrent calls with the same key', () async {
      final flight = SingleFlight<int>();
      var runs = 0;
      Future<int> task() async {
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 42;
      }

      final results = await Future.wait([
        flight.run('k', task),
        flight.run('k', task),
        flight.run('k', task),
      ]);
      expect(results, everyElement(42));
      expect(runs, 1);
    });

    test('runs tasks independently for different keys', () async {
      final flight = SingleFlight<int>();
      var runs = 0;
      final results = await Future.wait([
        flight.run('a', () async {
          runs++;
          return 1;
        }),
        flight.run('b', () async {
          runs++;
          return 2;
        }),
      ]);
      expect(results, [1, 2]);
      expect(runs, 2);
    });

    test('clears the in-flight entry after failure', () async {
      final flight = SingleFlight<int>();
      await expectLater(
        flight.run('k', () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(flight.isIdle, isTrue);
      expect(await flight.run('k', () async => 7), 7);
    });
  });

  group('AsyncMutex', () {
    test('serializes critical sections', () async {
      final mutex = AsyncMutex();
      var concurrent = 0;
      var maxConcurrent = 0;
      Future<void> work() => mutex.synchronize(() async {
        concurrent++;
        maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        concurrent--;
      });

      await Future.wait([work(), work(), work()]);
      expect(maxConcurrent, 1);
    });

    test('returns the action result', () async {
      final mutex = AsyncMutex();
      expect(await mutex.synchronize(() async => 5), 5);
    });

    test('propagates errors without breaking the queue', () async {
      final mutex = AsyncMutex();
      await expectLater(
        mutex.synchronize(() async => throw StateError('x')),
        throwsA(isA<StateError>()),
      );
      expect(await mutex.synchronize(() async => 3), 3);
    });
  });
}
