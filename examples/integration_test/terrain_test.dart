import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

/// One 64x64 Terrarium tile, a hill 1000 m high at its center over 0 m. It
/// is the tile of every zoom and position.
const _demAsset = 'assets/terrain/dem.png';

const _terrain = Terrain(sourceId: 'dem', exaggeration: 1.25);

/// Serves the fixture DEM and styles that use it without the network. On
/// native, a loopback server serves them, which counts the DEM requests. In
/// the browser, which has no server, the DEM is an asset of the app and a
/// style is a data URL.
class _Fixture {
  _Fixture._(this._server, this._dem) {
    _server?.listen(_serve);
  }

  static Future<_Fixture> start() async {
    if (kIsWeb) return _Fixture._(null, null);
    final dem = (await rootBundle.load(_demAsset)).buffer.asUint8List();
    return _Fixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      dem,
    );
  }

  final HttpServer? _server;
  final Uint8List? _dem;
  final _styles = <String>[];

  /// The DEM tiles that the server served; always 0 on web.
  int demRequests = 0;

  String get _origin => 'http://127.0.0.1:${_server!.port}';

  /// The URL of the DEM tile.
  String get demTile => kIsWeb
      ? Uri.base.resolve('assets/$_demAsset').toString()
      : '$_origin/dem.png';

  /// A style with the raster DEM source [demId] and a background of
  /// [color].
  Map<String, Object?> style({
    String color = '#dddddd',
    String demId = 'dem',
  }) => {
    'version': 8,
    'sources': {
      demId: {
        'type': 'raster-dem',
        'tiles': [demTile],
        'tileSize': 256,
        'encoding': 'terrarium',
        'maxzoom': 2,
      },
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': color},
      },
    ],
  };

  /// A URL of [style], which the map has to load before it can parse it.
  MapStyle styleUrl(Map<String, Object?> style) {
    final json = jsonEncode(style);
    if (kIsWeb) {
      return MapStyle.url(
        Uri.dataFromString(json, mimeType: 'application/json').toString(),
      );
    }
    _styles.add(json);
    return MapStyle.url('$_origin/style/${_styles.length - 1}.json');
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/dem.png') {
      demRequests++;
      response.headers.contentType = ContentType('image', 'png');
      response.add(_dem!);
    } else if (RegExp(r'^/style/(\d+)\.json$').firstMatch(path)
        case final match?) {
      response.headers.contentType = ContentType.json;
      response.write(_styles[int.parse(match[1]!)]);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() async => _server?.close(force: true);
}

MapOptions _options(MapStyle style) =>
    MapOptions(style: style, initCamera: const CameraUpdate.position(zoom: 4));

void runTests() {
  group('terrain', () {
    late _Fixture fixture;
    setUp(() async => fixture = await _Fixture.start());
    tearDown(() async => fixture.close());

    Future<TestMap> pumpTerrainMap(WidgetTester tester) => pumpMap(
      tester,
      options: _options(MapStyle.json(jsonEncode(fixture.style()))),
    );

    testWidgets('setTerrain sets the terrain that terrain reads back', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      expect(map.style.terrain, isNull);

      await map.style.setTerrain(_terrain);
      await tester.pump();
      expect(map.style.terrain, _terrain);
      // A raster DEM source loads its tiles only once something uses it.
      if (!kIsWeb) {
        await map.pumpUntil(
          () => fixture.demRequests > 0,
          reason: () => 'the terrain never loaded the DEM',
        );
      }
      await map.waitForLatestFrame();
    });

    testWidgets('setTerrain(null) removes the terrain', (tester) async {
      final map = await pumpTerrainMap(tester);
      await map.style.setTerrain(_terrain);
      await map.style.setTerrain(null);
      await tester.pump();
      expect(map.style.terrain, isNull);
    });

    testWidgets('a terrain set while a style loads applies once it loaded', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final oldStyle = map.style;
      final since = map.styleLoads;
      // Only the new style has the source of the terrain.
      await map.setOptions(
        _options(
          fixture.styleUrl(fixture.style(color: '#bbddff', demId: 'dem-new')),
        ),
      );
      // The new style is still loading: it comes from a URL.
      const terrain = Terrain(sourceId: 'dem-new', exaggeration: 1.25);
      final applied = oldStyle.setTerrain(terrain);
      await map.waitForStyleLoad(since: since);
      await map.pumpFuture(applied, reason: 'setTerrain never completed');
      await tester.pump();
      expect(map.style, isNot(same(oldStyle)));
      expect(map.style.terrain, terrain);
    });

    testWidgets('a new style drops the terrain', (tester) async {
      final map = await pumpTerrainMap(tester);
      await map.style.setTerrain(_terrain);
      final since = map.styleLoads;
      await map.setOptions(
        _options(MapStyle.json(jsonEncode(fixture.style(color: '#bbddff')))),
      );
      await map.waitForStyleLoad(since: since);
      await tester.pump();
      expect(map.style.terrain, isNull);
    });

    testWidgets('a terrain on a source the style lacks', (tester) async {
      final map = await pumpTerrainMap(tester);
      await expectLater(
        map.style.setTerrain(const Terrain(sourceId: 'not-in-style')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('missing'),
          ),
        ),
      );
      expect(map.style.terrain, isNull);
    });

    testWidgets('setGlobalState drives global-state expressions', (
      tester,
    ) async {
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(
            jsonEncode({
              'version': 8,
              'state': {
                'scrub_i': {'default': -1},
              },
              'sources': {
                'points': {
                  'type': 'geojson',
                  'data': {
                    'type': 'FeatureCollection',
                    'features': [
                      for (var i = 0; i < 100; i++)
                        {
                          'type': 'Feature',
                          'properties': {'i': i},
                          'geometry': {
                            'type': 'Point',
                            'coordinates': [0, 0],
                          },
                        },
                    ],
                  },
                },
              },
              'layers': [
                {
                  'id': 'points',
                  'type': 'circle',
                  'source': 'points',
                  'filter': [
                    '==',
                    ['get', 'i'],
                    ['global-state', 'scrub_i'],
                  ],
                  'paint': {'circle-radius': 10},
                },
              ],
            }),
          ),
          initCamera: const CameraUpdate.position(zoom: 4),
        ),
      );
      bool only(List<RenderedFeature> features, int i) =>
          features.length == 1 && features.single.properties['i'] == i;

      await map.style.setGlobalState('scrub_i', 42);
      var features = await map.waitForFeatures(
        map.center,
        (features) => only(features, 42),
        layerIds: ['points'],
      );
      expect(features.single.properties['i'], 42);

      await map.style.setGlobalState('scrub_i', 7);
      features = await map.waitForFeatures(
        map.center,
        (features) => only(features, 7),
        layerIds: ['points'],
      );
      expect(features.single.properties['i'], 7);
    });
  });
}
