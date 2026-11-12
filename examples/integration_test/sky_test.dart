import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/browser.dart';
import 'shared/still_png.dart';
import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

/// Looking north along the synthetic ridge, steep enough that the top of
/// the screen is above the sky's gradient to the horizon color: at pitch 70
/// the top of the screen is sky, but of the horizon's white.
const _camera = CameraUpdate.position(
  center: Geographic(lon: alpsLng, lat: alpsLat),
  zoom: 13,
  pitch: 80,
);

const _terrain = Terrain(sourceId: 'alps', exaggeration: alpsExaggeration);

/// A blue sky over the fog of the True Earth outdoor style.
const _blueSky = Sky(
  skyColor: ui.Color(0xFF0000FF),
  fogColor: ui.Color(0xFFC6D4E0),
  fogGroundBlend: 0.35,
);

/// The background of the ground, dark so that the light fog shows on it.
const _ground = [0x30, 0x30, 0x30];

/// How far in logical pixels below the first ground on screen the fog is
/// read: distant ground, where the fog is thickest.
const _belowHorizon = 5.0;

/// How far in logical pixels below the top edge the sky is read.
const _top = 2.0;

bool _isBlue(List<int> pixel) => pixel[2] > 200 && pixel[0] < 60;

bool _near(List<int> pixel, List<int> rgb, {int tolerance = 8}) =>
    Iterable<int>.generate(3)
        .every((i) => (pixel[i] - rgb[i]).abs() <= tolerance);

/// Whether [pixel] is what the top of the map shows without a sky: the
/// style's [background] color on native. On web the canvas stays clear
/// above the horizon of a terrain.
bool _noSky(List<int> pixel, List<int> background) =>
    kIsWeb ? pixel[3] == 0 : _near(pixel, background);

var _frames = 0;

/// The RGBA color at [point], in logical pixels of the map, of the frame on
/// screen.
Future<List<int>> _pixelAt(TestMap map, Offset point) async {
  if (kIsWeb) {
    // maplibre-gl-js draws into a DOM element that Flutter can't read. Any
    // change to the style renders.
    final frame = await readMapFrame(
      () => unawaited(map.style.setGlobalState('frame', _frames++)),
    );
    final x = (point.dx * frame.scale).round();
    final y = (point.dy * frame.scale).round();
    final offset = (y * frame.width + x) * 4;
    return frame.rgba.sublist(offset, offset + 4);
  }
  final tester = map.tester;
  final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
  // The root layer scales by the device pixel ratio, so the image is in
  // physical pixels.
  final physical =
      (tester.getTopLeft(map.finder) + point) * tester.view.devicePixelRatio;
  final bytes = await tester.runAsync(() async {
    final image = await layer.toImage(physical & const ui.Size(1, 1));
    final data = await image.toByteData();
    image.dispose();
    return data!;
  });
  return bytes!.buffer.asUint8List().toList();
}

/// The point [_belowHorizon] below the topmost ground of the terrain in
/// the map's center column.
Future<Offset> _distantGround(TestMap map) async {
  final x = map.size.width / 2;
  // The top of the screen is sky and its center is ground.
  var sky = 0.0;
  var ground = map.center.dy;
  while (ground - sky > 1) {
    final middle = (sky + ground) / 2;
    if (await map.controller.toLngLatOnTerrain(Offset(x, middle)) == null) {
      sky = middle;
    } else {
      ground = middle;
    }
  }
  return Offset(x, ground + _belowHorizon);
}

/// Waits until the pixel at the point that [at] finds shows a color that
/// [matches], which a sky's transition takes a few frames to reach.
Future<List<int>> _waitForPixel(
  TestMap map,
  String what,
  Future<Offset> Function(TestMap map) at,
  bool Function(List<int> pixel) matches,
) async {
  final deadline = DateTime.now().add(defaultTimeout);
  var point = await at(map);
  var pixel = await _pixelAt(map, point);
  while (!matches(pixel)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The map never showed $what at $point, last: $pixel');
    }
    await map.tester.pump(const Duration(milliseconds: 100));
    point = await at(map);
    pixel = await _pixelAt(map, point);
  }
  return pixel;
}

/// Waits until the top center of the map shows a color that [matches].
Future<List<int>> _waitForTop(
  TestMap map,
  String what,
  bool Function(List<int> pixel) matches,
) => _waitForPixel(
  map,
  what,
  (map) async => Offset(map.size.width / 2, _top),
  matches,
);

/// Waits until the distant ground shows [ground] without fog.
///
/// Not on web: gl-js fades the fog out above the ground that the terrain
/// queries find (its DEM tiles), over flat ground farther out, which no
/// query locates.
Future<void> _waitForNoFog(TestMap map, List<int> ground) async {
  if (kIsWeb) return;
  await _waitForPixel(
    map,
    'ground without fog',
    _distantGround,
    (pixel) => _near(pixel, ground),
  );
}

/// Whether [pixel] of the dark [_ground] is lightened by the fog's light
/// blue-gray.
bool _fogged(List<int> pixel) =>
    Iterable<int>.generate(3).every((i) => pixel[i] >= _ground[i] + 40) &&
    pixel[2] >= pixel[0];

void runTests() {
  group('sky', () {
    late AlpsFixture fixture;
    setUp(() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
    });
    tearDown(() async => fixture.close());

    /// The fixture's style with a background of [color].
    Map<String, Object?> style({String color = '#303030'}) {
      final style = fixture.style();
      final layers = style['layers']! as List<Object?>;
      style['layers'] = [
        {
          ...layers.first! as Map<String, Object?>,
          'paint': {'background-color': color},
        },
      ];
      return style;
    }

    MapOptions options(Map<String, Object?> style) => MapOptions(
      style: MapStyle.json(jsonEncode(style)),
      initCamera: _camera,
      maxPitch: 85,
    );

    /// A map at [_camera] over the synthetic ridge with its terrain.
    Future<TestMap> pumpSkyMap(WidgetTester tester) async {
      final map = await pumpMap(tester, options: options(style()));
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      return map;
    }

    /// Sets [_blueSky] and waits for its sky, and for its fog except on web
    /// (see [_waitForNoFog]).
    Future<List<int>> showBlueSky(TestMap map) async {
      await map.style.setSky(_blueSky);
      if (!kIsWeb) await _waitForPixel(map, 'fog', _distantGround, _fogged);
      return _waitForTop(map, 'the blue sky', _isBlue);
    }

    testWidgets('setSky shows the sky above the horizon and fog below', (
      tester,
    ) async {
      final map = await pumpSkyMap(tester);
      await _waitForTop(map, 'no sky', (p) => _noSky(p, _ground));
      await _waitForNoFog(map, _ground);

      await showBlueSky(map);
    });

    testWidgets('setSky(null) removes the sky and its fog', (tester) async {
      final map = await pumpSkyMap(tester);
      await showBlueSky(map);

      await map.style.setSky(null);
      await _waitForTop(map, 'no sky', (p) => _noSky(p, _ground));
      await _waitForNoFog(map, _ground);
    });

    testWidgets('a new style without a sky drops the sky and its fog', (
      tester,
    ) async {
      final map = await pumpSkyMap(tester);
      await showBlueSky(map);

      // Another background, so the style changes.
      const red = [0xcc, 0x22, 0x22];
      final loads = map.styleLoads;
      await map.setOptions(options(style(color: '#cc2222')));
      await map.waitForStyleLoad(since: loads);
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      await _waitForTop(map, 'no sky', (p) => _noSky(p, red));
      await _waitForNoFog(map, red);
    });

    testWidgets('setSky while a new style loads fails with a StateError', (
      tester,
    ) async {
      final map = await pumpSkyMap(tester);
      final outgoing = map.style;
      final loads = map.styleLoads;
      final incoming = jsonEncode(style(color: '#cc2222'));
      // On web, gl-js applies style JSON at once, as a diff, so the style
      // comes from a URL whose answer waits until the call was made.
      final answer = Completer<void>();
      if (kIsWeb) {
        addJsonProtocol('sky', (_) async {
          await answer.future;
          return incoming;
        });
      }
      map.setOptionsNow(
        MapOptions(
          style: kIsWeb
              ? const MapStyle.url('sky://style.json')
              : MapStyle.json(incoming),
          initCamera: _camera,
          maxPitch: 85,
        ),
      );
      final setting = outgoing.setSky(_blueSky);
      answer.complete();
      await expectLater(setting, throwsStateError);

      // The style that loads takes a sky.
      await map.waitForStyleLoad(since: loads);
      await map.style.setSky(_blueSky);
      await _waitForTop(map, 'the blue sky', _isBlue);
    });

    testWidgets('a still image of a style with a sky matches the map', (
      tester,
    ) async {
      final map = await pumpSkyMap(tester);
      final live = await showBlueSky(map);

      final renderer = await StillImageRenderer.createInstance();
      addTearDown(renderer.dispose);
      final pixelRatio = tester.view.devicePixelRatio;
      final still = await decodeStill(
        await renderer.render(
          style: MapStyle.json(
            jsonEncode({...style(), 'sky': _blueSky.toJson()}),
          ),
          size: map.size,
          pixelRatio: pixelRatio,
          camera: _camera,
          terrain: _terrain,
        ),
      );
      final top = still.colorAt(still.width ~/ 2, (_top * pixelRatio).round());
      expect(
        _near(top, live),
        isTrue,
        reason: 'the still image has $top, the map $live',
      );
    });
  });
}
