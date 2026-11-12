import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/browser.dart';
import 'shared/still_png.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

const _ground = [255, 0, 0, 255];
const _background = [0, 0, 255, 255];

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

  /// Whether the style and its raster layer have keys that the style spec
  /// doesn't know.
  bool unknownKeys = false;

  /// Whether the style has a source, which no layer draws, whose TileJSON
  /// is missing.
  bool unusedSource = false;

  /// Whether every raster tile fails with 500 Internal Server Error.
  bool failRaster = false;

  /// Holds the answers to `?held` requests for the style until it completes.
  final styleHeld = Completer<void>();
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
    } else if (path == '/missing.json') {
      return null;
    } else if (path.startsWith('/raster/') && failRaster) {
      return _failure;
    }
    return path.startsWith('/dem/') ? _dem : _raster;
  }

  /// The answer of a request that fails with 500 Internal Server Error.
  static const _failure = #failure;

  Future<Object?> _respond(String url) async =>
      switch (await _answerAfterHold(Uri.parse(url))) {
        _failure => HttpStatus.internalServerError,
        final answer => answer,
      };

  Future<Object?> _answerAfterHold(Uri uri) async {
    if (uri.query == 'held') await styleHeld.future;
    return _answer(uri.path);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    switch (await _answerAfterHold(request.uri)) {
      case final String json:
        response.write(json);
      case final Uint8List png:
        response
          ..headers.contentType = ContentType('image', 'png')
          ..add(png);
      case _failure:
        response.statusCode = HttpStatus.internalServerError;
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  String get style => jsonEncode({
    'version': 8,
    if (unknownKeys) 'nonsense': true,
    'sources': {
      if (unusedSource)
        'unused': {'type': 'raster', 'url': '$_url/missing.json'},
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
      {
        'id': 'ground',
        'type': 'raster',
        'source': 'ground',
        if (unknownKeys) 'nonsense': true,
      },
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
      expect((await render(centerAltitude: 0)).colorAt(64, 64), _background);
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

    testWidgets('terrain over a server with tiles missing draws as over '
        'all tiles', (tester) async {
      // A server of the synthetic DEM, which has only zoom 10 tiles. In the
      // browser the app's own server answers, so its tiles take the routing
      // of raster-dem tiles over http.
      final alps = await AlpsFixture.start();
      addTearDown(alps.close);
      // The browser keeps 250 entries, which the app's own scripts fill.
      clearResourceTimings();
      Future<StillPixels> renderAlps({required int maxzoom}) async {
        final style = alps.style();
        final sources = style['sources']! as Map<String, Object?>;
        final dem = {...sources['alps']! as Map<String, Object?>};
        dem['maxzoom'] = maxzoom;
        style['sources'] = {
          'alps': dem,
          // Relief to compare, from a source of its own.
          'shade': dem,
        };
        style['layers'] = [
          ...style['layers']! as List<Object?>,
          {'id': 'shade', 'type': 'hillshade', 'source': 'shade'},
        ];
        return decodeStill(
          await renderer.render(
            style: MapStyle.json(jsonEncode(style)),
            size: _size,
            camera: alpsCamera,
            terrain: const Terrain(sourceId: 'alps'),
            timeout: const Duration(seconds: 20),
          ),
        );
      }

      final all = await renderAlps(maxzoom: alpsDemZoom);
      // Zoom 11 is missing: each tile is drawn from its zoom 10 parent.
      final missing = await renderAlps(maxzoom: alpsDemZoom + 1);
      expect(missing.differenceFrom(all), lessThan(0.01));
      if (kIsWeb) {
        // The missing tiles were asked of the server.
        final requested = resourcesUnder(
          Uri.base.resolve('assets/assets/terrain/alps/').toString(),
        );
        expect(
          requested.where((url) => url.contains('/alps/${alpsDemZoom + 1}/')),
          isNotEmpty,
          reason: 'requested: $requested',
        );
      }
    });

    testWidgets('a steep camera without a sky shows the background above '
        'the ground', (tester) async {
      final image = await decodeStill(
        await renderer.render(
          style: MapStyle.url(server.styleUrl),
          size: _size,
          camera: const CameraUpdate.position(
            center: Geographic(lon: 86.925, lat: 27.988),
            zoom: 13.5,
            pitch: 85,
          ),
          terrain: _terrain,
          timeout: const Duration(seconds: 20),
        ),
      );
      expect(image.colorAt(64, 1), _background);
      expect(image.colorAt(64, 127), _ground);
    });

    testWidgets('a style with keys the spec lacks still draws', (tester) async {
      server.unknownKeys = true;
      expect((await render()).colorAt(64, 64), _ground);
    });

    testWidgets('a source whose TileJSON fails fails the image', (
      tester,
    ) async {
      server.unusedSource = true;
      await expectLater(render(), throwsA(isA<StillImageException>()));
    });

    testWidgets('a tile that fails fails the image', (tester) async {
      server.failRaster = true;
      await expectLater(render(), throwsA(isA<StillImageException>()));
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

    testWidgets('the timeout counts from when a request starts', (
      tester,
    ) async {
      // In the browser, the second request waits for the first.
      final held = renderer.render(
        style: MapStyle.url('${server.styleUrl}?held'),
        size: _size,
        camera: _everest,
        terrain: _terrain,
      );
      final next = renderer.render(
        style: MapStyle.url(server.styleUrl),
        size: _size,
        camera: _everest,
        terrain: _terrain,
        timeout: const Duration(seconds: 5),
      );
      await Future<void>.delayed(const Duration(seconds: 6));
      server.styleHeld.complete();
      expect((await decodeStill(await held)).colorAt(64, 64), _ground);
      expect((await decodeStill(await next)).colorAt(64, 64), _ground);
    });

    testWidgets('dispose fails a request that waits for its turn', (
      tester,
    ) async {
      final held = renderer.render(
        style: MapStyle.url('${server.styleUrl}?held'),
        size: _size,
        camera: _everest,
      );
      final next = renderer.render(
        style: MapStyle.url(server.styleUrl),
        size: _size,
        camera: _everest,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      renderer.dispose();
      await expectLater(held, throwsA(isA<StillImageException>()));
      if (kIsWeb) {
        await expectLater(next, throwsA(isA<StillImageException>()));
      } else {
        // Only the browser queues requests: elsewhere the second one may
        // have finished before the dispose.
        await next.then<void>((_) {}, onError: (Object _) {});
      }
      server.styleHeld.complete();
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
