import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
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

/// How far in logical pixels the grabbed ground may end up from the finger.
const _tolerance = 2.0;

/// How far in logical pixels the engine's own cast onto the terrain may be
/// from [GroundView], below [_tolerance], so the oracle's error cannot hide
/// drift. Measured: within 1 px.
const _oracleTolerance = 1.5;

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

void runTests() {
  group('terrain gestures', () {
    late AlpsFixture fixture;
    setUp(() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
    });
    tearDown(() async => fixture.close());

    /// The options of a map at the Alps camera over the synthetic ridge.
    MapOptions terrainOptions({bool centerClampedToGround = true}) =>
        MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: alpsCamera,
          centerClampedToGround: centerClampedToGround,
        );

    /// A map over the synthetic ridge with its terrain, once the camera
    /// settled on it.
    Future<(TestMap, GroundView)> pumpTerrainMap(
      WidgetTester tester, {
      bool centerClampedToGround = true,
    }) async {
      final map = await pumpMap(
        tester,
        options: terrainOptions(centerClampedToGround: centerClampedToGround),
      );
      await map.style.setTerrain(_terrain);
      final ground = GroundView(map);
      await fixture.waitUntilSettled(map, ground);
      return (map, ground);
    }

    /// Shows [polygon] on the ground and waits until a feature query at
    /// [point], which casts onto the terrain, finds it.
    Future<void> showOnGround(
      TestMap map,
      List<Geographic> polygon,
      Offset point, {
      Duration timeout = defaultTimeout,
    }) async {
      final data = featureCollection([
        Feature(geometry: Polygon.from([polygon])),
      ]);
      if (map.style.sources['marker'] == null) {
        await map.style.sources.add(
          GeoJsonSource.data(id: 'marker', data: data),
        );
        await map.style.layers.add(
          FillStyleLayer(
            id: 'marker',
            sourceId: 'marker',
            color: const .literal(Color(0xFFFF0000)),
          ),
        );
      } else {
        await map.style.sources.updateGeoJsonData('marker', data);
      }
      await map.waitForFeatures(
        point,
        (features) => features.isNotEmpty,
        layerIds: ['marker'],
        timeout: timeout,
      );
    }

    /// The ground [_oracleTolerance] pixels around [point], as a polygon.
    List<Geographic> groundAround(GroundView ground, Offset point) => [
      for (final offset in const [
        Offset(_oracleTolerance, 0),
        Offset(0, _oracleTolerance),
        Offset(-_oracleTolerance, 0),
        Offset(0, -_oracleTolerance),
        Offset(_oracleTolerance, 0),
      ])
        ground.groundAt(point + offset),
    ];

    testWidgets('GroundView finds the ground that the map draws', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      // Over the screen: the center, both sides, near and far.
      for (final offset in const [
        Offset.zero,
        Offset(-120, 0),
        Offset(120, 60),
        Offset(0, 200),
        Offset(0, -150),
      ]) {
        final point = map.center + offset;
        await showOnGround(map, groundAround(ground, point), point);
      }
    });

    testWidgets('the camera center is on the ground by default', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      final camera = map.controller.camera!;
      final shown = ground.toScreen(camera.center);
      debugPrint(
        'camera center on screen: $shown, screen center ${map.center}',
      );
      expect((shown - map.center).distance, lessThan(2));
    });

    testWidgets('the app can leave the camera center off the ground', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(
        tester,
        centerClampedToGround: false,
      );
      final camera = map.controller.camera!;
      final shown = ground.toScreen(camera.center);
      debugPrint('unclamped camera center on screen: $shown');
      // At sea level under the ridge, far behind the ground on screen.
      expect((shown - map.center).distance, greaterThan(100));
    });

    testWidgets('the clamp turns on and off on a running map', (tester) async {
      final (map, ground) = await pumpTerrainMap(
        tester,
        centerClampedToGround: false,
      );
      double offGround() =>
          (ground.toScreen(map.controller.camera!.center) - map.center)
              .distance;
      expect(offGround(), greaterThan(100));
      // Over lower ground, 2.8 km south of the crest, and back. On web the
      // clamp applies from the next camera change on, so each change of the
      // option is followed by a move.
      const slope = Geographic(lon: alpsLng, lat: alpsLat - 0.025);
      const crest = Geographic(lon: alpsLng, lat: alpsLat);
      Future<void> moveTo(Geographic center) async {
        await map.controller.moveCamera(CameraUpdate.position(center: center));
        await map.waitForLatestFrame();
        await fixture.waitUntilSettled(map, ground);
      }

      await map.setOptions(terrainOptions());
      await moveTo(slope);
      expect(offGround(), lessThan(2));

      await map.setOptions(terrainOptions(centerClampedToGround: false));
      // The center keeps the slope's height.
      await moveTo(crest);
      debugPrint('center after a move unclamped: ${offGround()} px off');
      expect(offGround(), greaterThan(20));
    });

    /// How far the ground at [grabbed] is drawn from [finger], and that the
    /// engine's own cast onto the terrain finds it where [GroundView] puts it.
    Future<double> drift(
      TestMap map,
      GroundView ground,
      Geographic grabbed,
      Offset finger,
    ) async {
      final shown = ground.toScreen(grabbed);
      await showOnGround(map, groundAround(ground, shown), shown);
      return (shown - finger).distance;
    }

    /// Expects the camera's center on the ground it looks at, as the clamp
    /// keeps it.
    void expectCenterOnGround(TestMap map, GroundView ground) {
      final shown = ground.toScreen(map.controller.camera!.center);
      final off = (shown - map.center).distance;
      debugPrint('camera center ${off.toStringAsFixed(2)} px off its ground');
      expect(off, lessThan(_tolerance));
    }

    // Grabs above, at and below the center's height, and drags along the
    // crest, down the view, and across it.
    for (final (name, start, step) in const [
      ('at the center along the crest', Offset.zero, Offset(-5, 0)),
      ('on the near slope up the view', Offset(-60, 150), Offset(2, -4)),
      ('on the far side across the view', Offset(80, -120), Offset(-4, 3)),
    ]) {
      testWidgets(
        'a 40-move drag $name keeps the grabbed ground under the finger',
        (tester) async {
          final (map, ground) = await pumpTerrainMap(tester);
          final from = map.center + start;
          // Past the touch slop, so the map follows the finger from there on.
          final finger = await tester.startGesture(
            map.toGlobal(from + const Offset(30, 0)),
          );
          await finger.moveBy(const Offset(-30, 0));
          await tester.pump(const Duration(milliseconds: 16));
          await fixture.waitUntilSettled(map, ground);
          final grabbed = ground.groundAt(from);
          await showOnGround(map, groundAround(ground, from), from);

          // A real finger reports a move every frame: 40 for 200 px.
          for (var i = 0; i < 40; i++) {
            await finger.moveBy(step);
            await tester.pump(const Duration(milliseconds: 16));
          }
          final to = from + step * 40;
          await fixture.waitUntilSettled(map, ground);
          final held = await drift(map, ground, grabbed, to);
          // Lifted at rest, so it does not fling.
          await finger.up();
          await fixture.waitUntilSettled(map, ground);
          final released = await drift(map, ground, grabbed, to);
          debugPrint(
            'drag $name: ${held.toStringAsFixed(2)} px held, '
            '${released.toStringAsFixed(2)} px released',
          );
          expect(held, lessThanOrEqualTo(_tolerance));
          expect(released, lessThanOrEqualTo(_tolerance));
          expectCenterOnGround(map, ground);
        },
        // maplibre-gl-js moves the camera over terrain itself; this package
        // anchors gestures only on native (see .agents/decisions.md).
        skip: kIsWeb,
      );
    }

    testWidgets('a pinch that pans keeps the ground under its focal point', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      final focal = map.center + const Offset(0, 100);
      final a = await tester.startGesture(
        map.toGlobal(focal - const Offset(40, 0)),
      );
      final b = await tester.startGesture(
        map.toGlobal(focal + const Offset(40, 0)),
      );
      // Past the scale slop, keeping the focal point.
      await a.moveBy(const Offset(-25, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await b.moveBy(const Offset(25, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await fixture.waitUntilSettled(map, ground);
      final grabbed = ground.groundAt(focal);
      await showOnGround(map, groundAround(ground, focal), focal);

      // Spread, twist and move together: about 1.7 zoom levels, about 50
      // degrees, and 40 px left and 60 px up.
      const pan = Offset(-2, -3);
      for (var i = 0; i < 20; i++) {
        await a.moveBy(pan + const Offset(-3, 7));
        await tester.pump(const Duration(milliseconds: 16));
        await b.moveBy(pan + const Offset(3, -7));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final to = focal + pan * 20;
      await fixture.waitUntilSettled(map, ground);
      final held = await drift(map, ground, grabbed, to);
      await a.up();
      await b.up();
      await fixture.waitUntilSettled(map, ground);
      final released = await drift(map, ground, grabbed, to);
      final camera = map.controller.getCamera();
      debugPrint(
        'pinch: ${held.toStringAsFixed(2)} px held, '
        '${released.toStringAsFixed(2)} px released, at zoom '
        '${camera.zoom.toStringAsFixed(2)}, bearing '
        '${camera.bearing.toStringAsFixed(1)}',
      );
      expect(camera.zoom, greaterThan(13.5));
      expect(held, lessThanOrEqualTo(_tolerance));
      expect(released, lessThanOrEqualTo(_tolerance));
      expectCenterOnGround(map, ground);
    }, skip: kIsWeb);

    /// Taps twice at [point], 50 ms apart.
    Future<void> doubleTap(
      WidgetTester tester,
      TestMap map,
      Offset point,
    ) async {
      await tester.tapAt(map.toGlobal(point));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(map.toGlobal(point));
    }

    // Nearer than the center, on the lower slope of the ridge.
    Offset tapPoint(TestMap map) => map.center + const Offset(0, 150);

    testWidgets('a double tap zoom keeps the tapped ground in place', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      final tapped = tapPoint(map);
      final point = ground.groundAt(tapped);
      final zoom = map.controller.getCamera().zoom;
      await doubleTap(tester, map, tapped);
      await map.waitForCamera((camera) => camera.zoom > zoom + 0.99);
      await fixture.waitUntilSettled(map, ground);
      final moved = await drift(map, ground, point, tapped);
      debugPrint('double tap drift: ${moved.toStringAsFixed(2)} px');
      expect(moved, lessThanOrEqualTo(_tolerance));
      expectCenterOnGround(map, ground);
    }, skip: kIsWeb);

    testWidgets('double taps during a double tap zoom keep the ground', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      final tapped = tapPoint(map);
      final point = ground.groundAt(tapped);
      final zoom = map.controller.getCamera().zoom;
      await doubleTap(tester, map, tapped);
      // The second zoom starts while the first one's 300 ms run.
      await tester.pump(const Duration(milliseconds: 100));
      await doubleTap(tester, map, tapped);
      // The second zoom starts from where the first one got to, a part of a
      // level that depends on the device's frame rate: a delta replacing an
      // animated one starts where that animation left the camera.
      await map.waitForCamera((camera) => camera.zoom > zoom + 1.1);
      await fixture.waitUntilSettled(map, ground);
      final moved = await drift(map, ground, point, tapped);
      debugPrint('two double taps drift: ${moved.toStringAsFixed(2)} px');
      expect(moved, lessThanOrEqualTo(_tolerance));
      expectCenterOnGround(map, ground);
    }, skip: kIsWeb);

    testWidgets('wheel zooms keep the ground under the pointer', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      final pointed = tapPoint(map);
      final point = ground.groundAt(pointed);
      final zoom = map.controller.getCamera().zoom;
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(map.toGlobal(pointed)));
      // Five notches a frame apart, each an immediate zoom of 0.2 levels.
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -90)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await map.waitForCamera((camera) => camera.zoom > zoom + 0.9);
      await fixture.waitUntilSettled(map, ground);
      debugPrint(
        'wheel zoom: ${map.controller.getCamera().zoom - zoom} levels',
      );
      final moved = await drift(map, ground, point, pointed);
      debugPrint('wheel zoom drift: ${moved.toStringAsFixed(2)} px');
      expect(moved, lessThanOrEqualTo(_tolerance));
      expectCenterOnGround(map, ground);
    }, skip: kIsWeb);

    /// Screen points over the ground: the center, both sides, near and far.
    const groundPoints = [
      Offset.zero,
      Offset(-120, 0),
      Offset(120, 60),
      Offset(0, 200),
      Offset(0, -150),
    ];

    testWidgets('toLngLatOnTerrain finds the ground that the map draws', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      for (final offset in groundPoints) {
        final point = map.center + offset;
        final found = await map.controller.toLngLatOnTerrain(point);
        expect(found, isNotNull, reason: '$point');
        final error = (ground.toScreen(found!) - point).distance;
        final seaLevel = map.controller.toLngLat(point);
        debugPrint(
          'toLngLatOnTerrain($point): ${error.toStringAsFixed(2)} px off, '
          '${_meters(found, seaLevel).round()} m from toLngLat',
        );
        expect(error, lessThan(1));
        // toLngLat is at sea level on native, far behind the ground.
        if (!kIsWeb) expect(_meters(found, seaLevel), greaterThan(500));
      }
    });

    testWidgets('toScreenLocationOnTerrain draws the ground at its point', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      for (final offset in groundPoints) {
        final point = map.center + offset;
        final location = await map.controller.toScreenLocationOnTerrain(
          ground.groundAt(point),
        );
        debugPrint('toScreenLocationOnTerrain at $point: $location');
        expect(location, isNotNull, reason: '$point');
        expect((location!.offset - point).distance, lessThan(1));
        expect(location.occluded, isFalse);
      }
    });

    testWidgets('toScreenLocationOnTerrain sees a ridge hide the ground', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      // From 5 km south of the crest, looking north over it: the slope 3 km
      // north of the crest is behind it, and the valley floor 8 km north
      // shows over it.
      await map.controller.moveCamera(
        const CameraUpdate.position(
          center: Geographic(lon: alpsLng, lat: alpsLat - 5 / _kmPerDegree),
          zoom: 12,
        ),
      );
      await map.waitForLatestFrame();
      await fixture.waitUntilSettled(map, ground);
      final screen = Offset.zero & map.size;
      for (final (north, hidden) in const [(0, false), (3, true), (8, false)]) {
        final point = Geographic(
          lon: alpsLng,
          lat: alpsLat + north / _kmPerDegree,
        );
        final location = await map.controller.toScreenLocationOnTerrain(point);
        debugPrint('$north km north of the crest: $location');
        expect(location, isNotNull, reason: '$north km');
        expect(screen.contains(location!.offset), isTrue, reason: '$north km');
        expect(location.occluded, hidden, reason: '$north km');
      }
    });

    testWidgets('the terrain conversions find nothing without DEM tiles', (
      tester,
    ) async {
      final (map, _) = await pumpTerrainMap(tester);
      for (final point in const [
        // East of the vendored tiles, whose server answers 404 there.
        Geographic(lon: alpsLng + 0.8, lat: alpsLat),
        // Far from them.
        Geographic(lon: 0, lat: 0),
      ]) {
        expect(
          await map.controller.toScreenLocationOnTerrain(point),
          isNull,
          reason: '$point',
        );
      }
    });

    testWidgets('the terrain conversions are the plain ones without one', (
      tester,
    ) async {
      final map = await pumpMap(tester, options: terrainOptions());
      await map.waitForLatestFrame();
      for (final offset in groundPoints) {
        final point = map.center + offset;
        final lngLat = map.controller.toLngLat(point);
        final found = await map.controller.toLngLatOnTerrain(point);
        expect(found, isNotNull, reason: '$point');
        expect(_meters(found!, lngLat), lessThan(1), reason: '$point');
        final location = await map.controller.toScreenLocationOnTerrain(lngLat);
        expect(location, isNotNull, reason: '$point');
        expect((location!.offset - point).distance, lessThan(0.1));
        expect(location.occluded, isFalse);
      }
    });

    testWidgets('setTerrainLoadMode completes', (tester) async {
      final (map, ground) = await pumpTerrainMap(tester);
      for (final mode in TerrainLoadMode.values.reversed) {
        await map.pumpFuture(
          map.controller.setTerrainLoadMode(mode),
          reason: 'setTerrainLoadMode($mode) never completed',
        );
      }
      await fixture.waitUntilSettled(map, ground);
    });
  });
}

/// Kilometers per degree of latitude on the sphere of `alps_dem.dart`.
const double _kmPerDegree = 6371.0088 * pi / 180;

/// The distance in meters between [a] and [b], on a plane at their
/// latitude, which is close enough for the few kilometers of the fixture.
double _meters(Geographic a, Geographic b) {
  final north = (a.lat - b.lat) * _kmPerDegree * 1000;
  final east = (a.lon - b.lon) * _kmPerDegree * 1000 * cos(a.lat * pi / 180);
  return sqrt(north * north + east * east);
}
