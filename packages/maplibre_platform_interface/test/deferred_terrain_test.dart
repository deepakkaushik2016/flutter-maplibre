import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

const _a = Terrain(sourceId: 'a');
const _b = Terrain(sourceId: 'b', exaggeration: 2);

Matcher _stateError(String message) =>
    throwsA(isA<StateError>().having((e) => e.message, 'message', message));

void main() {
  group('DeferredTerrain', () {
    test('defers nothing while no style loads', () {
      expect(DeferredTerrain().defer(_a), isNull);
    });

    test('loads from styleLoading until the load ends', () {
      final deferred = DeferredTerrain();
      expect(deferred.loading, isFalse);
      final first = deferred.styleLoading();
      expect(deferred.loading, isTrue);
      deferred.styleLoaded(first, (_) {});
      expect(deferred.loading, isFalse);
      deferred.styleLoadFailed(deferred.styleLoading(), StateError('404'));
      expect(deferred.loading, isFalse);
      deferred
        ..styleLoading()
        ..dispose();
      expect(deferred.loading, isFalse);
    });

    test('applies a terrain set while a style loads once it loaded', () async {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      var done = false;
      final applied = deferred.defer(_a)!.then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      final calls = <Terrain?>[];
      await deferred.styleLoaded(generation, calls.add);
      await applied;
      expect(calls, [_a]);
      expect(deferred.defer(_b), isNull);
    });

    test('completes at once when the apply is synchronous', () {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      deferred.defer(_a);
      expect(deferred.styleLoaded(generation, (_) {}), isNull);
    });

    test('applies a deferred null, which removes the terrain', () async {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      final applied = deferred.defer(null)!;
      final calls = <Terrain?>[];
      await deferred.styleLoaded(generation, calls.add);
      await applied;
      expect(calls, [null]);
    });

    test(
      'applies only the last terrain, and completes every call then',
      () async {
        final deferred = DeferredTerrain();
        final generation = deferred.styleLoading();
        var firstDone = false;
        final first = deferred.defer(_a)!.then((_) => firstDone = true);
        final second = deferred.defer(_b)!;
        await Future<void>.delayed(Duration.zero);
        expect(firstDone, isFalse);

        final calls = <Terrain?>[];
        await deferred.styleLoaded(generation, calls.add);
        await Future.wait([first, second]);
        expect(calls, [_b]);
      },
    );

    test('fails every call with the error of a failed apply', () async {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      final first = expectLater(deferred.defer(_a), _stateError('no source'));
      final second = expectLater(deferred.defer(_b), _stateError('no source'));
      await deferred.styleLoaded(
        generation,
        (_) => throw StateError('no source'),
      );
      await Future.wait([first, second]);
    });

    test('waits for the last requested style', () async {
      final deferred = DeferredTerrain();
      final first = deferred.styleLoading();
      final second = deferred.styleLoading();
      final calls = <Terrain?>[];
      final applied = deferred.defer(_a)!;

      // The first style loaded after the second was requested, which
      // replaces it: nothing is applied, and calls still wait.
      await deferred.styleLoaded(first, calls.add);
      expect(calls, isEmpty);
      final later = deferred.defer(_b);
      expect(later, isNotNull);

      await deferred.styleLoaded(second, calls.add);
      await Future.wait([applied, later!]);
      expect(calls, [_b]);
      expect(deferred.defer(_a), isNull);
    });

    test('applies nothing if nothing was deferred', () async {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      final calls = <Terrain?>[];
      await deferred.styleLoaded(generation, calls.add);
      expect(calls, isEmpty);
      expect(deferred.defer(_a), isNull);
    });

    test('fails the calls of a style that failed to load', () async {
      final deferred = DeferredTerrain();
      final generation = deferred.styleLoading();
      final failed = expectLater(deferred.defer(_a), _stateError('404'));
      deferred.styleLoadFailed(generation, StateError('404'));
      await failed;
      // A later call is not deferred.
      expect(deferred.defer(_b), isNull);
    });

    test('ignores the failure of a replaced style', () async {
      final deferred = DeferredTerrain();
      final first = deferred.styleLoading();
      final second = deferred.styleLoading();
      final applied = deferred.defer(_a)!;
      deferred.styleLoadFailed(first, StateError('404'));
      final calls = <Terrain?>[];
      await deferred.styleLoaded(second, calls.add);
      await applied;
      expect(calls, [_a]);
    });

    test('fails pending and later calls once disposed', () async {
      final deferred = DeferredTerrain()..styleLoading();
      const message = 'The map was disposed before its style loaded.';
      final pending = expectLater(deferred.defer(_a), _stateError(message));
      deferred.dispose();
      await pending;
      await expectLater(
        deferred.defer(_b),
        _stateError('The map was disposed.'),
      );
    });
  });
}
