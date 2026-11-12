import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

/// A GPS fix every second.
const _fixInterval = Duration(seconds: 1);

/// One eased camera move per fix, ending before the next fix.
const _ease = Duration(milliseconds: 800);

const _zoom = 15.0;
const _pitch = 50.0;

/// How far the camera's center may be from the fix, in meters.
const _centerToleranceM = 0.5;

/// How far in logical pixels the ground under the center may be drawn from
/// the middle of the map. The camera's center on the ground within a meter
/// (Plan 01 Task 15) moves the ground about half a pixel at this zoom and
/// pitch; two allows for the projection's rounding.
const _groundTolerancePx = 2.0;

const double _kmPerDegree = 6371.0088 * pi / 180;

double _meters(Geographic a, Geographic b) {
  final dx = (a.lon - b.lon) * 111320 * cos(a.lat * pi / 180);
  final dy = (a.lat - b.lat) * 111320;
  return sqrt(dx * dx + dy * dy);
}

double _bearing(Geographic a, Geographic b) {
  final dx = (b.lon - a.lon) * cos(a.lat * pi / 180);
  final dy = b.lat - a.lat;
  return (atan2(dx, dy) * 180 / pi) % 360;
}

/// [count] fixes about 12 m apart, going east along the ridge and weaving
/// across its crest, so the ground under them rises and falls.
List<Geographic> _track(int count) => [
  for (var i = 0; i < count; i++)
    Geographic(
      lon: alpsLng + i * 0.012 / (_kmPerDegree * cos(alpsLat * pi / 180)),
      lat: alpsLat + 0.4 * sin(i / 8) / _kmPerDegree,
    ),
];

void runTests() {
  group('following GPS fixes over terrain', () {
    // Started by each test rather than in a setUp: on web, a failure in a
    // setUp is not reported, and the test would pass without running.
    late AlpsFixture fixture;
    late StreamController<UserLocation> locations;

    Future<void> startFixture() async {
      fixture = await AlpsFixture.start();
      addTearDown(fixture.close);
      locations = StreamController<UserLocation>.broadcast();
      addTearDown(locations.close);
    }

    Future<TestMap> pumpFollowMap(
      WidgetTester tester,
      Geographic start, {
      MapEventCallback<MapEventRenderFrame>? onRenderFrame,
    }) async {
      await startFixture();
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: CameraUpdate.position(
            center: start,
            zoom: _zoom,
            pitch: _pitch,
          ),
        ),
        children: [UserLocationLayer(locations: locations.stream)],
        onRenderFrame: onRenderFrame,
      );
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      return map;
    }

    Future<void> pumpFor(WidgetTester tester, Duration duration) async {
      final watch = Stopwatch()..start();
      while (watch.elapsed < duration) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('the camera follows 60 fixes on the ground', (tester) async {
      // The renderer's own frame clock, as in an app: the move bound below
      // relates camera events to frames rendered at the display's rate.
      final binding = IntegrationTestWidgetsFlutterBinding.instance;
      final policy = binding.framePolicy;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      addTearDown(() => binding.framePolicy = policy);
      final track = _track(60);
      final frameTimesMs = <double>[];
      var frames = 0;
      final map = await pumpFollowMap(
        tester,
        track.first,
        onRenderFrame: (event) {
          frames++;
          final stats = event.stats;
          if (stats == null) return;
          frameTimesMs.add(
            (stats.encodingTime + stats.renderingTime).inMicroseconds / 1000,
          );
        },
      );
      final movesBefore = map.events.whereType<MapEventCameraMove>().length;
      final framesBefore = frames;
      final centerErrors = <double>[];
      final groundErrors = <double>[];

      for (var i = 1; i < track.length; i++) {
        final fix = track[i];
        final bearing = _bearing(track[i - 1], fix);
        locations.add(UserLocation(position: fix, heading: bearing));
        final move = map.controller.animateCamera(
          CameraUpdate.position(center: fix, bearing: bearing),
          animation: const CameraAnimation.ease(duration: _ease),
        );
        await pumpFor(tester, _fixInterval);
        expect(
          await map.pumpFuture(move, reason: 'the move to fix $i'),
          CameraAnimationResult.completed,
          reason: 'fix $i',
        );

        final camera = map.controller.getCamera();
        final centerError = _meters(camera.center, fix);
        centerErrors.add(centerError);
        expect(centerError, lessThan(_centerToleranceM), reason: 'fix $i');

        final drawn = await map.pumpFuture(
          map.controller.toScreenLocationOnTerrain(fix),
          reason: 'projecting fix $i',
        );
        expect(drawn, isNotNull, reason: 'no ground under fix $i');
        expect(drawn!.occluded, isFalse, reason: 'fix $i');
        final groundError = (drawn.offset - map.center).distance;
        groundErrors.add(groundError);
        expect(groundError, lessThan(_groundTolerancePx), reason: 'fix $i');
      }

      expect(map.events.whereType<MapEventError>(), isEmpty);

      // At most one camera event per frame the map rendered. A tile that
      // arrives can advance the camera between frames, so a few more.
      final moves =
          map.events.whereType<MapEventCameraMove>().length - movesBefore;
      final rendered = frames - framesBefore;
      expect(moves, lessThanOrEqualTo(rendered * 1.1 + 2));

      frameTimesMs.sort();
      debugPrint(
        'follow: center error max '
        '${centerErrors.reduce(max).toStringAsFixed(3)} m, ground error max '
        '${groundErrors.reduce(max).toStringAsFixed(2)} px, $moves moves '
        'over $rendered frames, frame CPU median '
        '${frameTimesMs[frameTimesMs.length ~/ 2].toStringAsFixed(2)} ms, '
        'p95 ${frameTimesMs[frameTimesMs.length * 95 ~/ 100].toStringAsFixed(2)} ms',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('a pan ends the follow animation', (tester) async {
      final track = _track(2);
      final map = await pumpFollowMap(tester, track.first);
      final since = map.events.length;
      final far = Geographic(lon: track.first.lon + 0.03, lat: track.first.lat);

      final move = map.controller.animateCamera(
        CameraUpdate.position(center: far),
        animation: const CameraAnimation.ease(duration: Duration(seconds: 5)),
      );
      await pumpFor(tester, const Duration(milliseconds: 300));
      await tester.dragFrom(map.toGlobal(map.center), const Offset(-120, 0));

      expect(
        await map.pumpFuture(move, reason: 'the interrupted move'),
        CameraAnimationResult.cancelled,
      );
      await map.waitForEvent<MapEventCameraMoveEnd>(since: since);

      // The animation stays stopped: nothing moves the camera towards it.
      final stopped = map.controller.getCamera();
      await pumpFor(tester, const Duration(seconds: 1));
      final after = map.controller.getCamera();
      expect(_meters(stopped.center, after.center), lessThan(1));
      expect(_meters(after.center, far), greaterThan(100));
      expect(map.events.whereType<MapEventError>(), isEmpty);
    });
  });
}
