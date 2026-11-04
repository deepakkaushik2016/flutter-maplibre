import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

const _a = Terrain(sourceId: 'a');
const _b = Terrain(sourceId: 'b', exaggeration: 2);

void main() {
  group('DeferredTerrain', () {
    test('defers nothing while no style loads', () {
      expect(DeferredTerrain().defer(_a), isNull);
    });

    test('applies a terrain set while a style loads once it loaded', () async {
      final deferred = DeferredTerrain()..styleLoading();
      var done = false;
      final applied = deferred.defer(_a)!.then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      final calls = <Terrain?>[];
      await deferred.styleLoaded(calls.add);
      await applied;
      expect(calls, [_a]);
      expect(deferred.defer(_b), isNull);
    });

    test('applies a deferred null, which removes the terrain', () async {
      final deferred = DeferredTerrain()..styleLoading();
      final applied = deferred.defer(null)!;
      final calls = <Terrain?>[];
      await deferred.styleLoaded(calls.add);
      await applied;
      expect(calls, [null]);
    });

    test('applies only the last terrain; earlier calls complete', () async {
      final deferred = DeferredTerrain()..styleLoading();
      final first = deferred.defer(_a)!;
      final second = deferred.defer(_b)!;
      final calls = <Terrain?>[];
      await deferred.styleLoaded(calls.add);
      await Future.wait([first, second]);
      expect(calls, [_b]);
    });

    test('applies nothing if nothing was deferred', () async {
      final deferred = DeferredTerrain()..styleLoading();
      final calls = <Terrain?>[];
      await deferred.styleLoaded(calls.add);
      expect(calls, isEmpty);
    });

    test('completes with the error of a failed apply', () async {
      final deferred = DeferredTerrain()..styleLoading();
      final failed = expectLater(
        deferred.defer(_a),
        throwsA(isA<StateError>()),
      );
      await deferred.styleLoaded((_) => throw StateError('missing source'));
      await failed;
    });
  });
}
