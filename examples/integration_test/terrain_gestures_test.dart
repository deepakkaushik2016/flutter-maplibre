import 'dart:convert';
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
const _tolerance = 8.0;

/// How far in logical pixels the engine's own cast onto the terrain may be
/// from [GroundView], well below [_tolerance], so the oracle's error cannot
/// hide drift.
const _oracleTolerance = 2.5;

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

void runTests() {
  group('terrain gestures', () {
    late AlpsFixture fixture;
    setUp(() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
    });
    tearDown(() async => fixture.close());

    /// A map over the synthetic ridge with its terrain, once the camera
    /// settled on it.
    Future<(TestMap, GroundView)> pumpTerrainMap(
      WidgetTester tester, {
      bool centerClampedToGround = true,
    }) async {
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: alpsCamera,
          centerClampedToGround: centerClampedToGround,
        ),
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

    testWidgets(
      'a drag keeps the grabbed ground under the finger',
      (tester) async {
        final (map, ground) = await pumpTerrainMap(tester);
        // Past the touch slop, so the map follows the finger from there on.
        final gesture = await tester.startGesture(
          map.toGlobal(map.center + const Offset(30, 0)),
        );
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await fixture.waitUntilSettled(map, ground);
        final from = map.center;
        final grabbed = ground.groundAt(from);
        // The engine's own cast onto the terrain finds the ground there too.
        await showOnGround(map, groundAround(ground, from), from);

        // MapLibre Native's pan over a terrain drifts about 0.5 px per move
        // whatever its length (.agents/decisions.md, Known gaps), so a
        // finger's 40 moves would end about 20 px off. Raise this to 40
        // moves of 5 px once engine Task 15 fixes that.
        const step = Offset(-20, 0);
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(step);
          await tester.pump(const Duration(milliseconds: 16));
        }
        final to = from + step * 10;
        await fixture.waitUntilSettled(map, ground);
        final held = (ground.toScreen(grabbed) - to).distance;
        // Lifted at rest, so it does not fling.
        await gesture.up();
        await fixture.waitUntilSettled(map, ground);
        final released = (ground.toScreen(grabbed) - to).distance;
        debugPrint(
          'drag drift: ${held.toStringAsFixed(1)} px held, '
          '${released.toStringAsFixed(1)} px released',
        );
        expect(held, lessThanOrEqualTo(_tolerance));
        expect(released, lessThanOrEqualTo(_tolerance));
        // Where GroundView puts the grabbed ground, the engine finds it.
        final shown = ground.toScreen(grabbed);
        await showOnGround(map, groundAround(ground, shown), shown);
      },
      // maplibre-gl-js moves the camera over terrain itself; this package
      // anchors gestures only on native (see .agents/decisions.md).
      skip: kIsWeb,
    );

    testWidgets('a double tap zoom keeps the tapped ground in place', (
      tester,
    ) async {
      final (map, ground) = await pumpTerrainMap(tester);
      // Nearer than the center, on the lower slope of the ridge.
      final tapped = map.center + const Offset(0, 150);
      final point = ground.groundAt(tapped);
      final zoom = map.controller.getCamera().zoom;
      await tester.tapAt(map.toGlobal(tapped));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(map.toGlobal(tapped));
      await map.waitForCamera((camera) => camera.zoom > zoom + 0.5);
      await fixture.waitUntilSettled(map, ground);
      final drift = (ground.toScreen(point) - tapped).distance;
      debugPrint('double tap drift: ${drift.toStringAsFixed(1)} px');
      expect(drift, lessThanOrEqualTo(_tolerance));
    }, skip: kIsWeb);

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
