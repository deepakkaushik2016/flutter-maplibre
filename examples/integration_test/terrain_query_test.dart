import 'dart:convert';
import 'dart:math';

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

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

/// Kilometers per degree of latitude on the sphere of `alps_dem.dart`.
const double _kmPerDegree = 6371.0088 * pi / 180;

/// A point [north] and [east] kilometers from the crest under the camera.
Geographic _fromCrest(double north, double east) => Geographic(
  lon: alpsLng + east / (_kmPerDegree * cos(alpsLat * pi / 180)),
  lat: alpsLat + north / _kmPerDegree,
);

/// 100 points of the ground, as a trail an app might place: a grid from
/// 8 km south of the crest, below the screen, to 10 km north of it, and 6 km
/// to each side, past the edges. Some are hidden behind the ridge.
final List<Geographic> _trail = [
  for (var row = 0; row < 10; row++)
    for (var column = 0; column < 10; column++)
      _fromCrest(-8 + row * 2, -6 + column * 12 / 9),
];

/// Whether [a] and [b] are the same answer within [tolerance] logical pixels.
bool _same(
  TerrainScreenLocation? a,
  TerrainScreenLocation? b, {
  double tolerance = 0.01,
}) {
  if (a == null || b == null) return a == b;
  return (a.offset - b.offset).distance <= tolerance &&
      a.occluded == b.occluded;
}

void runTests() {
  group('terrain queries', () {
    late AlpsFixture fixture;

    /// A map with its terrain from 5 km south of the crest of the synthetic
    /// ridge, looking north over it, once the camera settled: the slope 3 km
    /// north of the crest is behind it, the valley floor beyond shows.
    Future<TestMap> pumpTerrainMap(WidgetTester tester) async {
      // On web the fixture counts DEM requests in the browser's resource
      // timings, whose buffer earlier tests fill.
      clearResourceTimings();
      fixture = await AlpsFixture.start();
      addTearDown(fixture.close);
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: CameraUpdate.position(
            center: _fromCrest(-5, 0),
            zoom: 12,
            pitch: 60,
          ),
        ),
      );
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      return map;
    }

    /// The answers of one toScreenLocationOnTerrain call after another.
    Future<List<TerrainScreenLocation?>> oneByOne(
      TestMap map,
      List<Geographic> points,
    ) async => [
      for (final point in points)
        await map.controller.toScreenLocationOnTerrain(point),
    ];

    /// Checks that [actual] answers each of [points] as [expected] does.
    void expectSame(
      List<Geographic> points,
      List<TerrainScreenLocation?> actual,
      List<TerrainScreenLocation?> expected, {
      double tolerance = 0.01,
    }) {
      expect(actual, hasLength(expected.length));
      for (var i = 0; i < expected.length; i++) {
        expect(
          _same(actual[i], expected[i], tolerance: tolerance),
          isTrue,
          reason: '${points[i]}: ${actual[i]}, one by one ${expected[i]}',
        );
      }
    }

    /// Checks the premise of a comparison: [answers] hold points in view and,
    /// but on web, points off screen and behind the ridge.
    void expectMixed(TestMap map, List<TerrainScreenLocation?> answers) {
      final screen = Offset.zero & map.size;
      final found = answers.nonNulls.toList();
      final shown = found.where((a) => screen.contains(a.offset));
      debugPrint(
        '${found.length} of ${answers.length} found, ${shown.length} on '
        'screen, ${found.where((a) => a.occluded).length} hidden',
      );
      expect(shown.where((a) => !a.occluded), isNotEmpty);
      // Web only estimates what hides a point, and projects a point behind
      // the camera onto the screen, so the grid has neither there.
      if (!kIsWeb) {
        expect(found.where((a) => !screen.contains(a.offset)), isNotEmpty);
        expect(found.where((a) => a.occluded), isNotEmpty);
      }
    }

    testWidgets('concurrent toScreenLocationOnTerrain calls each answer', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final expected = await oneByOne(map, _trail);
      expectMixed(map, expected);
      final concurrent = await Future.wait([
        for (final point in _trail)
          map.controller.toScreenLocationOnTerrain(point),
      ]);
      expectSame(_trail, concurrent, expected);
    });

    testWidgets('concurrent toLngLatOnTerrain calls each answer', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final points = [
        for (var row = 0; row < 10; row++)
          for (var column = 0; column < 10; column++)
            Offset(
              map.size.width * (column + 0.5) / 10,
              map.size.height * (row + 0.5) / 10,
            ),
      ];
      final expected = [
        for (final point in points)
          await map.controller.toLngLatOnTerrain(point),
      ];
      expect(expected.nonNulls, isNotEmpty);
      final concurrent = await Future.wait([
        for (final point in points) map.controller.toLngLatOnTerrain(point),
      ]);
      for (var i = 0; i < points.length; i++) {
        final a = concurrent[i];
        final b = expected[i];
        expect(
          a == null || b == null
              ? a == b
              : (a.lon - b.lon).abs() < 1e-9 && (a.lat - b.lat).abs() < 1e-9,
          isTrue,
          reason: '${points[i]}: $a, one by one $b',
        );
      }
    });

    testWidgets('toScreenLocationsOnTerrain answers as each point does', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final expected = await oneByOne(map, _trail);
      expectMixed(map, expected);
      final batch = await map.controller.toScreenLocationsOnTerrain(_trail);
      expectSame(_trail, batch, expected);
    });

    testWidgets('toScreenLocationsOnTerrain answers an empty list', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      expect(
        await map.controller.toScreenLocationsOnTerrain(const []),
        isEmpty,
      );
    });

    testWidgets('toScreenLocationsOnTerrain keeps the order of its points', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      // Visible, behind the ridge, the valley over it, off the DEM tiles,
      // far from them, and the visible one again.
      final points = [
        _fromCrest(0, 0),
        _fromCrest(3, 0),
        _fromCrest(8, 0),
        const Geographic(lon: alpsLng + 0.8, lat: alpsLat),
        const Geographic(lon: 0, lat: 0),
        _fromCrest(0, 0),
      ];
      final batch = await map.controller.toScreenLocationsOnTerrain(points);
      final expected = await oneByOne(map, points);
      expectSame(points, batch, expected);
      expect(batch[3], isNull);
      expect(batch[4], isNull);
      expect(batch[0], isNotNull);
      expect(_same(batch[0], batch[5]), isTrue);
    });

    testWidgets('toScreenLocationsOnTerrain answers a 5000-point trail', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final trail = [
        for (var i = 0; i < 5000; i++)
          _fromCrest(-8 + 18 * i / 4999, 5 * sin(i / 300)),
      ];
      final watch = Stopwatch()..start();
      final batch = await map.controller.toScreenLocationsOnTerrain(trail);
      debugPrint('5000 points in ${watch.elapsedMilliseconds} ms');
      final expected = await Future.wait([
        for (final point in trail)
          map.controller.toScreenLocationOnTerrain(point),
      ]);
      expect(expected.nonNulls, isNotEmpty);
      expectSame(trail, batch, expected);
    });

    testWidgets('toScreenLocationsOnTerrain answers null for bad points', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final good = [_fromCrest(0, 0), _fromCrest(8, 0), _fromCrest(-2, 1)];
      // A bad first point, a NaN latitude, a NaN longitude and an infinite
      // one, which Geographic turns into NaN, among the good ones.
      final points = [
        const Geographic(lon: alpsLng, lat: double.nan),
        good[0],
        const Geographic(lon: alpsLng, lat: double.nan),
        good[1],
        const Geographic(lon: double.nan, lat: alpsLat),
        const Geographic(lon: double.infinity, lat: alpsLat),
        good[2],
      ];
      final batch = await map.controller.toScreenLocationsOnTerrain(points);
      final expected = await oneByOne(map, good);
      expect(batch, hasLength(points.length));
      for (final i in const [0, 2, 4, 5]) {
        expect(batch[i], isNull, reason: '${points[i]}');
      }
      expectSame(good, [batch[1], batch[3], batch[6]], expected);
      expect(batch[1], isNotNull);
    });

    testWidgets('toScreenLocationsOnTerrain is the plain one without one', (
      tester,
    ) async {
      // On web the fixture counts DEM requests in the browser's resource
      // timings, whose buffer earlier tests fill.
      clearResourceTimings();
      fixture = await AlpsFixture.start();
      addTearDown(fixture.close);
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: alpsCamera,
        ),
      );
      await map.waitForLatestFrame();
      final points = [
        for (final offset in const [Offset(-120, 0), Offset(0, 200)])
          map.controller.toLngLat(map.center + offset),
      ];
      final batch = await map.controller.toScreenLocationsOnTerrain(points);
      for (var i = 0; i < points.length; i++) {
        expect(batch[i], isNotNull);
        final plain = map.controller.toScreenLocation(points[i]);
        expect((batch[i]!.offset - plain).distance, lessThan(0.1));
        expect(batch[i]!.occluded, isFalse);
      }
    });
  });
}
