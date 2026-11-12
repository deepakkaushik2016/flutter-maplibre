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
const _blueSky = Sky(skyColor: ui.Color(0xFF0000FF));

/// The background of [AlpsFixture.style].
const _background = [0xdd, 0xdd, 0xdd];

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

/// The RGBA color at the top center of the frame on screen.
Future<List<int>> _topCenter(TestMap map) async {
  if (kIsWeb) {
    // maplibre-gl-js draws into a DOM element that Flutter can't read. Any
    // change to the style renders.
    final frame = await readMapFrame(
      () => unawaited(map.style.setGlobalState('frame', _frames++)),
    );
    final x = frame.width ~/ 2;
    final y = (_top * frame.scale).round();
    final offset = (y * frame.width + x) * 4;
    return frame.rgba.sublist(offset, offset + 4);
  }
  final tester = map.tester;
  final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
  // The root layer scales by the device pixel ratio, so the image is in
  // physical pixels.
  final point =
      (tester.getTopLeft(map.finder) + Offset(map.size.width / 2, _top)) *
      tester.view.devicePixelRatio;
  final bytes = await tester.runAsync(() async {
    final image = await layer.toImage(point & const ui.Size(1, 1));
    final data = await image.toByteData();
    image.dispose();
    return data!;
  });
  return bytes!.buffer.asUint8List().toList();
}

/// Waits until the top center of the map shows a color that [matches],
/// which a sky's transition takes a few frames to reach.
Future<List<int>> _waitForTop(
  TestMap map,
  String what,
  bool Function(List<int> pixel) matches,
) async {
  final deadline = DateTime.now().add(defaultTimeout);
  var pixel = await _topCenter(map);
  while (!matches(pixel)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The top of the map never showed $what, last: $pixel');
    }
    await map.tester.pump(const Duration(milliseconds: 100));
    pixel = await _topCenter(map);
  }
  return pixel;
}

void runTests() {
  group('sky', () {
    late AlpsFixture fixture;
    setUp(() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
    });
    tearDown(() async => fixture.close());

    MapOptions options(Map<String, Object?> style) => MapOptions(
      style: MapStyle.json(jsonEncode(style)),
      initCamera: _camera,
      maxPitch: 85,
    );

    /// A map at [_camera] over the synthetic ridge with its terrain.
    Future<TestMap> pumpSkyMap(WidgetTester tester) async {
      final map = await pumpMap(tester, options: options(fixture.style()));
      await map.style.setTerrain(_terrain);
      await fixture.waitUntilSettled(map, GroundView(map));
      return map;
    }

    testWidgets('setSky shows the sky above the horizon', (tester) async {
      final map = await pumpSkyMap(tester);
      await _waitForTop(map, 'no sky', (p) => _noSky(p, _background));

      await map.style.setSky(_blueSky);
      await _waitForTop(map, 'the blue sky', _isBlue);
    });

    testWidgets('setSky(null) removes the sky', (tester) async {
      final map = await pumpSkyMap(tester);
      await map.style.setSky(_blueSky);
      await _waitForTop(map, 'the blue sky', _isBlue);

      await map.style.setSky(null);
      await _waitForTop(map, 'no sky', (p) => _noSky(p, _background));
    });

    testWidgets('a new style without a sky drops the sky', (tester) async {
      final map = await pumpSkyMap(tester);
      await map.style.setSky(_blueSky);
      await _waitForTop(map, 'the blue sky', _isBlue);

      // The same style with another background, so the style changes.
      const red = [0xcc, 0x22, 0x22];
      final style = fixture.style();
      final layers = style['layers']! as List<Object?>;
      style['layers'] = [
        {
          ...layers.first! as Map<String, Object?>,
          'paint': {'background-color': '#cc2222'},
        },
      ];
      final loads = map.styleLoads;
      await map.setOptions(options(style));
      await map.waitForStyleLoad(since: loads);
      await _waitForTop(map, 'no sky', (p) => _noSky(p, red));
    });

    testWidgets('a still image of a style with a sky matches the map', (
      tester,
    ) async {
      final map = await pumpSkyMap(tester);
      await map.style.setSky(_blueSky);
      final live = await _waitForTop(map, 'the blue sky', _isBlue);

      final renderer = await StillImageRenderer.createInstance();
      addTearDown(renderer.dispose);
      final pixelRatio = tester.view.devicePixelRatio;
      final still = await decodeStill(
        await renderer.render(
          style: MapStyle.json(
            jsonEncode({...fixture.style(), 'sky': _blueSky.toJson()}),
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
    }, skip: kIsWeb);
  });
}
