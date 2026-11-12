import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/browser.dart';
import 'shared/still_png.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

const _ground = [255, 0, 0, 255];
const _background = [0, 0, 255, 255];

/// What a camera under the terrain shows: the style's background. On web,
/// where the background is drawn onto the terrain, the image stays clear.
const List<int> _underground = kIsWeb ? [0, 0, 0, 0] : _background;

/// A flank of Everest: the camera's center at sea level would be under it.
const _everest = CameraUpdate.position(
  center: Geographic(lon: 86.925, lat: 27.988),
  zoom: 13.5,
  pitch: 50,
);

const _terrain = Terrain(sourceId: 'dem');
const _size = ui.Size(128, 128);

Future<Uint8List> _tile(List<int> rgba) async {
  const size = 256;
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels.setRange(i, i + 4, rgba);
  }
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    size,
    size,
    ui.PixelFormat.rgba8888,
    decoded.complete,
  );
  final image = await decoded.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A loopback server of ground 5400 m high with a red raster over it. In the
/// browser, which has no server, a custom maplibre-gl-js protocol answers
/// the same paths.
class _Server {
  _Server._(this._http, this._dem, this._raster) {
    _http?.listen(_serve);
    if (kIsWeb) addFixtureProtocol(_scheme, _respond);
  }

  static Future<_Server> start() async => _Server._(
    kIsWeb ? null : await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    // 5400 m in Terrarium: 5400 + 32768 = 149 * 256 + 24.
    await _tile(const [149, 24, 0, 255]),
    await _tile(_ground),
  );

  static const _scheme = 'still-fixture';

  final HttpServer? _http;
  final Uint8List _dem;
  final Uint8List _raster;

  /// Whether the DEM has no tiles at its highest zoom, as a sparse tileset.
  bool sparse = false;
  int styleRequests = 0;

  /// The requests for sprites and glyphs that reached the server.
  int styleAssetRequests = 0;

  /// A style path no other server shares, so that no cached style of a
  /// server with the same recycled loopback port can answer for this one.
  final _stylePath = '/style-${_nextId++}-${Random().nextInt(0x7fffffff)}.json';
  static int _nextId = 0;

  String get _url =>
      kIsWeb ? '$_scheme://fixture' : 'http://127.0.0.1:${_http!.port}';
  String get styleUrl => '$_url$_stylePath';

  /// The answer to a request for [path]: the style's JSON, a PNG, or null
  /// for 404 Not Found.
  Object? _answer(String path) {
    if (path == _stylePath) {
      styleRequests++;
      return style;
    } else if (path.startsWith('/sprites/') || path.startsWith('/glyphs/')) {
      styleAssetRequests++;
      return null;
    } else if (path.startsWith('/dem/13/') && sparse) {
      return null;
    }
    return path.startsWith('/dem/') ? _dem : _raster;
  }

  Future<Object?> _respond(String url) async => _answer(Uri.parse(url).path);

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    switch (_answer(request.uri.path)) {
      case final String json:
        response.write(json);
      case final Uint8List png:
        response
          ..headers.contentType = ContentType('image', 'png')
          ..add(png);
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  String get style => jsonEncode({
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
  });

  /// A style with a sprite that nothing has cached.
  MapStyle spriteStyle() => MapStyle.json(
    jsonEncode({
      'version': 8,
      'sprite': '$_url/sprites/missing',
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

  /// A style with a label whose glyph range nothing has cached.
  MapStyle glyphStyle() => MapStyle.json(
    jsonEncode({
      'version': 8,
      'glyphs': '$_url/glyphs/{fontstack}/{range}.pbf',
      'sources': {
        'label': {
          'type': 'geojson',
          'data': {
            'type': 'Feature',
            'properties': <String, Object>{},
            'geometry': {
              'type': 'Point',
              'coordinates': [86.925, 27.988],
            },
          },
        },
      },
      'layers': [
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'label',
          'type': 'symbol',
          'source': 'label',
          'layout': {
            'text-field': 'A',
            'text-font': ['Noto Sans Regular'],
          },
        },
      ],
    }),
  );

  Future<void> close() async => _http?.close(force: true);
}

void runTests() {
  // Outside the group: on web, a failure in a setUp is not reported.
  testWidgets('StillImageRenderer is supported', (tester) async {
    expect(StillImageRenderer.isSupported, isTrue);
    (await StillImageRenderer.createInstance()).dispose();
  });

  group('StillImageRenderer', () {
    late _Server server;
    late StillImageRenderer renderer;

    setUp(() async {
      // Loads maplibre-gl-js on web, which the server's protocol needs.
      renderer = await StillImageRenderer.createInstance();
      server = await _Server.start();
    });

    tearDown(() async {
      MapLibreNetwork.reset();
      renderer.dispose();
      await server.close();
    });

    Future<StillPixels> render({double? centerAltitude}) async => decodeStill(
      await renderer.render(
        style: MapStyle.url(server.styleUrl),
        size: _size,
        camera: _everest,
        terrain: _terrain,
        centerAltitude: centerAltitude,
        timeout: const Duration(seconds: 20),
      ),
    );

    testWidgets('draws ground high above the camera, at any size', (
      tester,
    ) async {
      final image = await render();
      expect(image.width, 128);
      expect(image.colorAt(64, 64), _ground);
    });

    testWidgets('a center height the caller gives replaces the clamp', (
      tester,
    ) async {
      expect((await render(centerAltitude: 0)).colorAt(64, 64), _underground);
      expect((await render(centerAltitude: 5400)).colorAt(64, 64), _ground);
    });

    testWidgets('terrain over a sparse DEM draws as over a dense one', (
      tester,
    ) async {
      final dense = await render();
      server.sparse = true;
      // Another region, so nothing of the dense DEM comes from the cache.
      final sparse = await decodeStill(
        await renderer.render(
          style: MapStyle.url(server.styleUrl),
          size: _size,
          camera: const CameraUpdate.position(
            center: Geographic(lon: 86.725, lat: 27.788),
            zoom: 13.5,
            pitch: 50,
          ),
          terrain: _terrain,
          timeout: const Duration(seconds: 20),
        ),
      );
      expect(sparse.colorAt(64, 64), _ground);
      expect(sparse.differenceFrom(dense), lessThan(0.01));
    });

    testWidgets('a style missing offline fails instead of hanging', (
      tester,
    ) async {
      MapLibreNetwork.status = NetworkStatus.offline;
      await expectLater(
        renderer.render(
          style: MapStyle.url('${server.styleUrl}?never-cached'),
          size: _size,
          camera: _everest,
          timeout: const Duration(seconds: 20),
        ),
        throwsA(isA<StillImageException>()),
      );
      expect(server.styleRequests, 0);
    }, skip: _offlineSkip);

    testWidgets('a sprite missing offline fails instead of hanging', (
      tester,
    ) async {
      MapLibreNetwork.status = NetworkStatus.offline;
      await expectLater(
        renderer.render(
          style: server.spriteStyle(),
          size: _size,
          camera: _everest,
          timeout: const Duration(seconds: 20),
        ),
        throwsA(isA<StillImageException>()),
      );
      expect(server.styleAssetRequests, 0);
    }, skip: _offlineSkip);

    testWidgets('a glyph range missing offline fails instead of hanging', (
      tester,
    ) async {
      MapLibreNetwork.status = NetworkStatus.offline;
      await expectLater(
        renderer.render(
          style: server.glyphStyle(),
          size: _size,
          camera: _everest,
          timeout: const Duration(seconds: 20),
        ),
        throwsA(isA<StillImageException>()),
      );
      expect(server.styleAssetRequests, 0);
    }, skip: _offlineSkip);

    testWidgets('overlapping requests each finish', (tester) async {
      // In the browser, at most one image's map lives at a time.
      var maps = 0;
      final count = kIsWeb
          ? Timer.periodic(const Duration(milliseconds: 1), (_) {
              maps = max(maps, countElements('.maplibre-still-image'));
            })
          : null;
      final images = await Future.wait([for (var i = 0; i < 3; i++) render()]);
      count?.cancel();
      for (final image in images) {
        expect(image.colorAt(64, 64), _ground);
      }
      if (kIsWeb) {
        expect(maps, 1);
        expect(countElements('.maplibre-still-image'), 0);
      }
    });

    testWidgets('dispose during a request fails it', (tester) async {
      final running = renderer.render(
        style: MapStyle.url(server.styleUrl),
        size: _size,
        camera: _everest,
        terrain: _terrain,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      renderer.dispose();
      await expectLater(running, throwsA(isA<StillImageException>()));
    });
  });
}

/// The network status does nothing on web, where the browser decides when a
/// request reaches the network.
const bool _offlineSkip = kIsWeb;
