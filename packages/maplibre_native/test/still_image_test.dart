import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/still_image.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

const _center = Geographic(lon: 86.925, lat: 27.988);
const _camera = CameraUpdate.position(center: _center, zoom: 13.5, pitch: 50);
const _size = ui.Size(64, 64);
const _background = [0, 0, 255, 255];
const _ground = [255, 0, 0, 255];

Future<Uint8List> _encodePng(int size, List<int> rgba) {
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels.setRange(i, i + 4, rgba);
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    size,
    size,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future.then((image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
}

/// The color of the center of a PNG.
Future<List<int>> _center_(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData();
  final x = frame.image.width ~/ 2;
  final y = frame.image.height ~/ 2;
  final offset = (y * frame.image.width + x) * 4;
  final color = data!.buffer.asUint8List().sublist(offset, offset + 4);
  frame.image.dispose();
  codec.dispose();
  return color;
}

/// A loopback server of a plateau 5400 m high and a red raster over it.
class _Server {
  _Server._(this._http, this._dem, this._raster) {
    _http.listen((request) async {
      final path = request.uri.path;
      if (path.startsWith('/hang')) {
        if (!_stillPending.isCompleted) _stillPending.complete();
        return;
      }
      if (path.startsWith('/missing')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(path.startsWith('/dem') ? _dem : _raster);
      await request.response.close();
    });
  }

  static Future<_Server> start() async {
    // 5400 m in Terrarium: 5400 + 32768 = 149 * 256 + 24.
    final dem = await _encodePng(256, const [149, 24, 0, 255]);
    final raster = await _encodePng(256, _ground);
    return _Server._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      dem,
      raster,
    );
  }

  final HttpServer _http;
  final Uint8List _dem;
  final Uint8List _raster;
  final _stillPending = Completer<void>();

  /// Completes once a style that [hangingTileStyle] gives has loaded and its
  /// still waits for a tile that the server never answers.
  Future<void> get stillPending => _stillPending.future;

  String get _url => 'http://127.0.0.1:${_http.port}';

  MapStyle terrainStyle() => MapStyle.json(
    jsonEncode({
      'version': 8,
      'sources': {
        'dem': {
          'type': 'raster-dem',
          'tiles': ['$_url/dem/{z}/{x}/{y}.png'],
          'tileSize': 256,
          'encoding': 'terrarium',
          'maxzoom': 13,
        },
        'ground': {
          'type': 'raster',
          'tiles': ['$_url/raster/{z}/{x}/{y}.png'],
          'tileSize': 256,
        },
      },
      'layers': [
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {'id': 'ground', 'type': 'raster', 'source': 'ground'},
      ],
    }),
  );

  /// A style whose document the server doesn't have.
  MapStyle missingStyle() => MapStyle.url('$_url/missing/style.json');

  /// A style that loads, and whose only tile source never answers, so its
  /// still stays pending inside `requestStillImage`.
  MapStyle hangingTileStyle() => MapStyle.json(
    jsonEncode({
      'version': 8,
      'sources': {
        'ground': {
          'type': 'raster',
          'tiles': ['$_url/hang-tile/{z}/{x}/{y}.png'],
          'tileSize': 256,
        },
      },
      'layers': [
        {'id': 'ground', 'type': 'raster', 'source': 'ground'},
      ],
    }),
  );

  /// A style whose document never answers.
  MapStyle hangingStyle() => MapStyle.url('$_url/hang/style.json');

  Future<void> close() => _http.close(force: true);
}

final _flat = MapStyle.json(
  jsonEncode({
    'version': 8,
    'sources': <String, Object>{},
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#0000ff'},
      },
    ],
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The shared database, in a directory of this test.
  final directory = Directory.systemTemp.createTempSync('still_image_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
  tearDownAll(() => directory.deleteSync(recursive: true));

  late _Server server;
  late StillImageRendererNative renderer;

  setUp(() async {
    server = await _Server.start();
    renderer = await StillImageRendererNative.create();
  });

  tearDown(() async {
    renderer.dispose();
    await server.close();
  });

  test('renders PNG bytes of the given size and pixel ratio', () async {
    final png = await renderer.render(
      style: _flat,
      size: _size,
      camera: _camera,
      pixelRatio: 2,
    );
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 128);
    expect(frame.image.height, 128);
    frame.image.dispose();
    codec.dispose();
    expect(await _center_(png), _background);
  });

  test('terrain on ground high above the camera draws the ground', () async {
    final png = await renderer.render(
      style: server.terrainStyle(),
      size: _size,
      camera: _camera,
      terrain: const Terrain(sourceId: 'dem'),
    );
    expect(await _center_(png), _ground);
    // The frame that finds the ground, and the frame drawn from it.
    expect(renderer.debugLastFrameCount, greaterThanOrEqualTo(2));
  });

  test('a still without terrain renders once', () async {
    await renderer.render(style: _flat, size: _size, camera: _camera);
    expect(renderer.debugLastFrameCount, 1);
  });

  test('a given center height replaces the clamp', () async {
    final under = await renderer.render(
      style: server.terrainStyle(),
      size: _size,
      camera: _camera,
      terrain: const Terrain(sourceId: 'dem'),
      centerAltitude: 0,
    );
    expect(await _center_(under), _background);

    final above = await renderer.render(
      style: server.terrainStyle(),
      size: _size,
      camera: _camera,
      terrain: const Terrain(sourceId: 'dem'),
      centerAltitude: 5400,
    );
    expect(await _center_(above), _ground);
  });

  test('a style that is not JSON is an error', () async {
    await expectLater(
      renderer.render(
        style: const MapStyle.json('not json'),
        size: _size,
        camera: _camera,
      ),
      throwsA(isA<StillImageException>()),
    );
  });

  test('a style that fails to load is an error', () async {
    await expectLater(
      renderer.render(
        style: server.missingStyle(),
        size: _size,
        camera: _camera,
      ),
      throwsA(isA<StillImageException>()),
    );
  });

  test('a terrain on a source the style lacks is an error', () async {
    await expectLater(
      renderer.render(
        style: _flat,
        size: _size,
        camera: _camera,
        terrain: const Terrain(sourceId: 'nope'),
      ),
      throwsA(isA<StillImageException>()),
    );
  });

  test('a size outside the limits is an error', () async {
    await expectLater(
      renderer.render(style: _flat, size: ui.Size.zero, camera: _camera),
      throwsArgumentError,
    );
  });

  test('a style that never answers times out', () async {
    await expectLater(
      renderer.render(
        style: server.hangingStyle(),
        size: _size,
        camera: _camera,
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // The renderer still works afterwards.
    await renderer.render(style: _flat, size: _size, camera: _camera);
  });

  test('concurrent requests each finish', () async {
    final pngs = await Future.wait([
      for (var i = 0; i < 4; i++)
        renderer.render(style: _flat, size: _size, camera: _camera),
    ]);
    for (final png in pngs) {
      expect(await _center_(png), _background);
    }
  });

  test('dispose fails a still that waits for its tiles', () async {
    final running = renderer.render(
      style: server.hangingTileStyle(),
      size: _size,
      camera: _camera,
    );
    await server.stillPending;
    renderer.dispose();
    await expectLater(running, throwsA(isA<StillImageException>()));
  });

  test('a given center height without a terrain draws normally', () async {
    final png = await renderer.render(
      style: _flat,
      size: _size,
      camera: _camera,
      centerAltitude: 100,
    );
    expect(await _center_(png), _background);
    expect(renderer.debugLastFrameCount, 1);
  });

  test('dispose fails a running request and later ones', () async {
    final running = renderer.render(
      style: server.hangingStyle(),
      size: _size,
      camera: _camera,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    renderer.dispose();
    await expectLater(running, throwsA(isA<StillImageException>()));
    await expectLater(
      renderer.render(style: _flat, size: _size, camera: _camera),
      throwsA(isA<StillImageException>()),
    );
  });
}
