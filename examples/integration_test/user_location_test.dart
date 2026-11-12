import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/browser.dart';
import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

/// A dot color that nothing else on the fixture's gray map has.
const _dotColor = Color(0xFFFF00FF);

/// A cone color that nothing else on the fixture's gray map has.
const _coneColor = Color(0xFF00C000);

/// An accuracy color that nothing else on the fixture's gray map has.
const _accuracyColor = Color(0xFF00FFFF);

/// How far in logical pixels the drawn dot may be from where the terrain
/// puts its location.
const _tolerance = 2.0;

void runTests() {
  group('UserLocationLayer on terrain', () {
    // Started by each test rather than in a setUp: on web, a failure in a
    // setUp is not reported, and the test would pass without running.
    late AlpsFixture fixture;
    late StreamController<UserLocation> locations;

    Future<void> startFixture() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
      // Locations close first, then the fixture.
      addTearDown(fixture.close);
      locations = StreamController<UserLocation>.broadcast();
      addTearDown(locations.close);
    }

    MapOptions options({Map<String, Object?>? style}) => MapOptions(
      style: MapStyle.json(jsonEncode(style ?? fixture.style())),
      initCamera: alpsCamera,
    );

    /// A pitched map over the synthetic ridge with its terrain and a user
    /// location layer, once the camera settled on the ground.
    Future<TestMap> pumpTerrainMap(
      WidgetTester tester, {
      UserLocationStyle style = const UserLocationStyle(
        showAccuracy: false,
        showHeading: false,
      ),
      UserLocationTracking tracking = UserLocationTracking.none,
    }) async {
      await startFixture();
      final map = await pumpMap(
        tester,
        options: options(),
        children: [
          UserLocationLayer(
            locations: locations.stream,
            color: _dotColor,
            style: style,
            tracking: tracking,
          ),
        ],
      );
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      return map;
    }

    /// The ground drawn at [point], which the engine finds.
    Future<Geographic> groundAt(TestMap map, Offset point) async {
      final ground = await map.pumpFuture(
        map.controller.toLngLatOnTerrain(point),
        reason: 'casting $point onto the terrain',
      );
      expect(ground, isNotNull, reason: 'no ground at $point');
      return ground!;
    }

    /// Where the terrain draws [point].
    Future<Offset> onTerrain(TestMap map, Geographic point) async {
      final location = await map.pumpFuture(
        map.controller.toScreenLocationOnTerrain(point),
        reason: 'projecting $point from the terrain',
      );
      expect(location, isNotNull, reason: 'no ground under $point');
      expect(location!.occluded, isFalse);
      return location.offset;
    }

    testWidgets('draws the dot where the terrain puts the location', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      // Ground well below the camera's center, which sits on the ridge, and
      // to one side: kilometres from its sea-level screen location.
      for (final point in [
        map.center + const Offset(-60, 120),
        map.center + const Offset(90, -60),
      ]) {
        final location = await groundAt(map, point);
        locations.add(UserLocation(position: location));
        final expected = await onTerrain(map, location);
        final seaLevel = map.controller.toScreenLocation(location);
        debugPrint(
          'location $location: on terrain $expected, at sea level $seaLevel',
        );
        final found = await findDot(map, expected);
        debugPrint('dot drawn at $found');
        expect(
          (found - expected).distance,
          lessThan(_tolerance),
          reason: 'drawn at $found, the terrain puts it at $expected',
        );
      }
    });

    testWidgets('drapes the accuracy circle around the dot', (tester) async {
      final map = await pumpTerrainMap(
        tester,
        style: const UserLocationStyle(
          showHeading: false,
          accuracyColor: _accuracyColor,
          accuracyOpacity: 1,
          accuracyOutlineOpacity: 1,
        ),
      );
      final location = await groundAt(map, map.center + const Offset(0, 80));
      locations.add(UserLocation(position: location, accuracy: 400));
      final dot = await onTerrain(map, location);
      // 400 m at zoom 13 is about 30 px; the dot covers its middle.
      final circle = await findPixels(map, dot, _isAccuracy, minimum: 500);
      final east = await onTerrain(map, _east(location, 400));
      debugPrint(
        'accuracy circle centered at $circle, dot at $dot, its east edge '
        'at $east',
      );
      expect((circle - dot).distance, lessThan(8));
      // It reaches 400 m east on the ground, not further.
      final edge = (east - dot).distance;
      expect(
        await _pixels(
          map,
          east - (east - dot) / edge * 3,
          _isAccuracy,
          1,
          radius: 2,
        ),
        isNotNull,
        reason: 'no circle just inside its edge',
      );
      expect(
        await _pixels(
          map,
          east + (east - dot) / edge * 4,
          _isAccuracy,
          1,
          radius: 1.5,
        ),
        isNull,
        reason: 'circle beyond its edge',
      );
    });

    testWidgets('points the cone along the heading as the map turns', (
      tester,
    ) async {
      final map = await pumpTerrainMap(
        tester,
        style: const UserLocationStyle(
          showAccuracy: false,
          headingColor: _coneColor,
          headingOpacity: 1,
        ),
      );
      final location = await groundAt(map, map.center + const Offset(0, 80));
      // East.
      locations.add(UserLocation(position: location, heading: 90));
      await map.pumpUntil(
        () => map.style.layers[UserLocationLayer.headingLayerId] != null,
        reason: () => 'the cone never got its layer',
      );
      for (final bearing in [0.0, 120.0, 250.0]) {
        await map.controller.moveCamera(
          CameraUpdate.position(bearing: bearing),
        );
        await map.waitForLatestFrame();
        final apex = await onTerrain(map, location);
        // On screen, the heading's way is the way of the ground east of
        // the location, wherever the map turns.
        final east = await onTerrain(map, _east(location, 60));
        final along = east - apex;
        final cone = await findPixels(map, apex, _isCone, minimum: 100);
        final towards = cone - apex;
        final angle = (towards.direction - along.direction) * 180 / pi;
        debugPrint(
          'bearing $bearing: east on screen $along, cone towards $towards',
        );
        expect(
          (angle + 540) % 360 - 180,
          inInclusiveRange(-8, 8),
          reason: 'bearing $bearing: the cone points $angle° off east',
        );
      }
      // Turned from north on the ground by the heading, on every platform.
      final layer = map.style.layers[UserLocationLayer.headingLayerId]!
          .toJson();
      expect(layer['type'], 'symbol');
      final layout = layer['layout']! as Map;
      expect(layout['icon-rotate'], ['get', 'h']);
      expect(layout['icon-rotation-alignment'], 'map');
      expect(layout['icon-pitch-alignment'], 'map');
    });

    testWidgets('keeps the cone as long on screen at every zoom', (
      tester,
    ) async {
      final map = await pumpTerrainMap(
        tester,
        style: const UserLocationStyle(
          showAccuracy: false,
          headingColor: _coneColor,
          headingOpacity: 1,
        ),
      );
      final location = await groundAt(map, map.center + const Offset(0, 80));
      locations.add(UserLocation(position: location, heading: 0));
      final lengths = <double, double>{};
      for (final zoom in [10.0, 12.5, 15.0, 17.5, 20.0]) {
        await map.controller.moveCamera(
          CameraUpdate.position(center: location, zoom: zoom, pitch: 0),
        );
        await map.waitForLatestFrame();
        final apex = await onTerrain(map, location);
        // A sector's centroid lies 2/3 of its radius out (sin 30° / 30° ·
        // 2/3 for the 60° cone, scaled by the fade); its distance follows
        // the length.
        final cone = await findPixels(map, apex, _isCone, minimum: 100);
        lengths[zoom] = (cone - apex).distance;
      }
      debugPrint('cone centroid distance by zoom: $lengths');
      final first = lengths.values.first;
      for (final MapEntry(key: zoom, value: length) in lengths.entries) {
        expect(length, closeTo(first, 1), reason: 'at zoom $zoom');
        expect(length, greaterThan(10), reason: 'at zoom $zoom');
      }
    });

    testWidgets('updates its source for locations, never for the camera', (
      tester,
    ) async {
      final map = await pumpTerrainMap(
        tester,
        style: const UserLocationStyle(),
      );
      final location = await groundAt(map, map.center + const Offset(0, 80));
      locations.add(
        UserLocation(position: location, accuracy: 30, heading: 45),
      );
      await map.waitForFeatures(
        await onTerrain(map, location),
        (features) => features.isNotEmpty,
        layerIds: [UserLocationLayer.dotLayerId],
      );
      Source source() => map.style.sources[UserLocationLayer.sourceId]!;
      // Each update replaces the source object.
      var current = source();
      var updates = 0;
      void count() {
        if (identical(source(), current)) return;
        current = source();
        updates++;
      }

      unawaited(
        map.controller.animateCamera(
          CameraUpdate.position(
            center: _east(location, 300),
            zoom: 15,
            bearing: 140,
            pitch: 40,
          ),
          animation: const CameraAnimation.fly(duration: Duration(seconds: 2)),
        ),
      );
      var frames = 0;
      final shown = <CameraPosition>{};
      await map.pumpUntil(() {
        count();
        frames++;
        if (map.controller.camera case final camera?) shown.add(camera);
        return (map.controller.camera?.zoom ?? 0) > 14.999 &&
            (map.controller.camera!.bearing - 140).abs() < 0.01;
      }, reason: () => 'the camera never arrived');
      debugPrint('$frames frames, ${shown.length} cameras shown');
      expect(shown.length, greaterThan(5));
      expect(updates, 0);
      // The probe sees updates: a new location is one.
      locations.add(UserLocation(position: location, accuracy: 40));
      await tester.pump();
      count();
      expect(updates, 1);
    });

    testWidgets('shows again once a new style has loaded', (tester) async {
      final map = await pumpTerrainMap(tester);
      final location = await groundAt(map, map.center + const Offset(40, 80));
      locations.add(UserLocation(position: location));
      await findDot(map, await onTerrain(map, location));
      final loads = map.styleLoads;
      final style = fixture.style();
      ((style['layers']! as List).single as Map)['paint'] = {
        'background-color': '#cccccc',
      };
      await map.setOptions(options(style: style));
      await map.pumpUntil(
        () => map.styleLoads > loads,
        reason: () => 'the new style never loaded',
      );
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      expect(map.style.layers[UserLocationLayer.dotLayerId], isNotNull);
      final expected = await onTerrain(map, location);
      final found = await findDot(map, expected);
      expect((found - expected).distance, lessThan(_tolerance));
    });

    testWidgets('takes locations while a new style loads, without errors', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final location = await groundAt(map, map.center + const Offset(40, 80));
      locations.add(UserLocation(position: location, heading: 0));
      await findDot(map, await onTerrain(map, location));
      final reported = <FlutterErrorDetails>[];
      final onError = FlutterError.onError;
      FlutterError.onError = reported.add;
      try {
        final loads = map.styleLoads;
        final style = fixture.style();
        ((style['layers']! as List).single as Map)['paint'] = {
          'background-color': '#cccccc',
        };
        // A compass turns while the style loads: every location is new.
        var heading = 0.0;
        void turn() => locations.add(
          UserLocation(position: location, heading: heading += 5),
        );
        map.setOptionsNow(options(style: style));
        turn();
        await map.pumpUntil(() {
          turn();
          return map.styleLoads > loads;
        }, reason: () => 'the new style never loaded');
        for (var i = 0; i < 5; i++) {
          turn();
          await tester.pump(const Duration(milliseconds: 40));
        }
        await map.style.setTerrain(_terrain);
        await fixture.waitUntilSettled(map, GroundView(map));
        final expected = await onTerrain(map, location);
        final found = await findDot(map, expected);
        expect((found - expected).distance, lessThan(_tolerance));
      } finally {
        FlutterError.onError = onError;
      }
      expect(reported.map((details) => details.exceptionAsString()), isEmpty);
    });

    testWidgets('tracking keeps the camera on the location on the ground', (
      tester,
    ) async {
      final map = await pumpTerrainMap(
        tester,
        tracking: UserLocationTracking.positionAndHeading,
      );
      final location = await groundAt(map, map.center + const Offset(50, 100));
      locations.add(UserLocation(position: location, heading: 30));
      final camera = await map.waitForCamera(
        (camera) =>
            _meters(camera.center, location) < 0.5 &&
            (camera.bearing - 30).abs() < 0.01,
      );
      // It stays there: the clamp to the ground does not pull it away.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final settled = map.controller.getCamera();
      debugPrint('tracked to $camera, settled at $settled');
      expect(_meters(settled.center, location), lessThan(0.5));
      expect(await onTerrain(map, location), _near(map.center, 1));
    });
  });
}

/// The point [meters] east of [point].
Geographic _east(Geographic point, double meters) => Geographic(
  lon: point.lon + meters / (111320 * cos(point.lat * pi / 180)),
  lat: point.lat,
);

double _meters(Geographic a, Geographic b) {
  final dx = (a.lon - b.lon) * 111320 * cos(a.lat * pi / 180);
  final dy = (a.lat - b.lat) * 111320;
  return sqrt(dx * dx + dy * dy);
}

Matcher _near(Offset expected, double distance) => predicate<Offset>(
  (offset) => (offset - expected).distance < distance,
  'within $distance px of $expected',
);

/// Waits until the map draws the dot near [expected], and returns the
/// center of its pixels.
Future<Offset> findDot(TestMap map, Offset expected) =>
    findPixels(map, expected, _isDot);

var _frames = 0;

bool _isDot(int r, int g, int b) => r > 200 && b > 200 && g < 90;

bool _isCone(int r, int g, int b) => g > r + 40 && g > b + 40;

bool _isAccuracy(int r, int g, int b) => r < 60 && g > 200 && b > 200;

/// Waits until the frame on screen has at least [minimum] pixels that
/// [matches] within 60 logical pixels of [around], in the same place in two
/// frames in a row, and returns their center.
Future<Offset> findPixels(
  TestMap map,
  Offset around,
  bool Function(int r, int g, int b) matches, {
  int minimum = 20,
}) async {
  final deadline = DateTime.now().add(defaultTimeout);
  Offset? last;
  while (true) {
    await map.tester.pump(const Duration(milliseconds: 50));
    final found = await map.pumpFuture(
      _pixels(map, around, matches, minimum),
      reason: 'reading the frame',
    );
    if (found != null && last != null && (found - last).distance < 0.25) {
      return found;
    }
    last = found;
    if (DateTime.now().isAfter(deadline)) {
      fail('Nothing drawn near $around, last at $last');
    }
  }
}

/// The center of the pixels that [matches] within [radius] logical pixels
/// of [around] in the frame on screen, or null if there are fewer than
/// [minimum] logical pixels' worth.
Future<Offset?> _pixels(
  TestMap map,
  Offset around,
  bool Function(int r, int g, int b) matches,
  int minimum, {
  double radius = 60,
}) async {
  if (kIsWeb) {
    // maplibre-gl-js draws into a DOM element that Flutter can't read.
    // Any change to the style renders.
    final frame = await readMapFrame(
      () => unawaited(map.style.setGlobalState('frame', _frames++)),
    );
    return _centroid(
      frame.rgba,
      frame.width,
      frame.height,
      frame.scale,
      around,
      matches,
      minimum,
      radius,
    );
  }
  final tester = map.tester;
  var boundary = tester.renderObject(map.finder);
  while (!boundary.isRepaintBoundary) {
    boundary = boundary.parent!;
  }
  final box = boundary as RenderBox;
  final origin = tester.getTopLeft(map.finder) - box.localToGlobal(Offset.zero);
  final pixelRatio = tester.view.devicePixelRatio;
  final image = await (box.debugLayer! as OffsetLayer).toImage(
    Offset.zero & box.size,
    pixelRatio: pixelRatio,
  );
  try {
    final bytes = (await image.toByteData())!;
    final found = _centroid(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      image.width,
      image.height,
      pixelRatio,
      origin + around,
      matches,
      minimum,
      radius,
    );
    return found == null ? null : found - origin;
  } finally {
    image.dispose();
  }
}

/// The center, in logical pixels, of the pixels of [rgba] that [matches]
/// within [radius] logical pixels of [around], or null if there are fewer than
/// [minimum] logical pixels' worth. [rgba] holds rows of [width] pixels,
/// [scale] per logical pixel.
Offset? _centroid(
  Uint8List rgba,
  int width,
  int height,
  double scale,
  Offset around,
  bool Function(int r, int g, int b) matches,
  int minimum,
  double radius,
) {
  final center = around * scale;
  final left = max(0, (center.dx - radius * scale).floor());
  final right = min(width - 1, (center.dx + radius * scale).ceil());
  final top = max(0, (center.dy - radius * scale).floor());
  final bottom = min(height - 1, (center.dy + radius * scale).ceil());
  var sumX = 0.0;
  var sumY = 0.0;
  var count = 0;
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      final i = (y * width + x) * 4;
      if (matches(rgba[i], rgba[i + 1], rgba[i + 2])) {
        // Pixel centers.
        sumX += x + 0.5;
        sumY += y + 0.5;
        count++;
      }
    }
  }
  if (count < minimum * scale * scale) return null;
  return Offset(sumX / count, sumY / count) / scale;
}
