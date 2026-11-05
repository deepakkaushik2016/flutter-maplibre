import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

/// One 64x64 Terrarium tile, a hill 1000 m high at its center over 0 m. It
/// is the tile of every zoom and position.
const _demAsset = 'assets/terrain/dem.png';

const _terrain = Terrain(sourceId: 'dem', exaggeration: 1.25);

/// Serves the fixture DEM and styles that use it without the network. On
/// native, a loopback server serves them, which counts the DEM requests. In
/// the browser, which has no server, the DEM is an asset of the app, whose
/// requests the browser's resource timing counts, and a style comes from a
/// custom maplibre-gl-js protocol.
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
  final _styles = <String?>[];

  /// Style responses wait for this until [releaseStyles].
  Completer<void> _held = Completer<void>()..complete();

  /// Holds the responses of styles until [releaseStyles], so a map loads
  /// them only then.
  void holdStyles() => _held = Completer<void>();

  /// Lets held style responses go out.
  void releaseStyles() {
    if (!_held.isCompleted) _held.complete();
  }

  var _demRequests = 0;

  /// The requests for the DEM tile.
  int get demRequests => kIsWeb ? resourceRequests(demTile) : _demRequests;

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

  /// A URL of [style], which the map has to load before it can parse it,
  /// or of no style, which fails to load, if [style] is null.
  MapStyle styleUrl(Map<String, Object?>? style) =>
      MapStyle.url(jsonUrl(style));

  /// A URL of [json], held like a style, which fails to load if [json] is
  /// null.
  String jsonUrl(Object? json) {
    _styles.add(json == null ? null : jsonEncode(json));
    final path = 'style/${_styles.length - 1}.json';
    if (kIsWeb) {
      // maplibre-gl-js has loaded: the map that gets this URL exists.
      addJsonProtocol('fixture', (url) async {
        await _held.future;
        final match = RegExp(r'style/(\d+)\.json$').firstMatch(url)!;
        return _styles[int.parse(match[1]!)] ??
            (throw StateError('No style at $url'));
      });
      return 'fixture://$path';
    }
    return '$_origin/$path';
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/dem.png') {
      _demRequests++;
      response.headers.contentType = ContentType('image', 'png');
      response.add(_dem!);
    } else if (RegExp(r'^/style/(\d+)\.json$').firstMatch(path)
        case final match?) {
      await _held.future;
      if (_styles[int.parse(match[1]!)] case final style?) {
        response.headers.contentType = ContentType.json;
        response.write(style);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
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
    setUp(() async {
      clearResourceTimings();
      fixture = await _Fixture.start();
    });
    tearDown(() async {
      fixture.releaseStyles();
      await fixture.close();
    });

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
      await map.pumpUntil(
        () => fixture.demRequests > 0,
        reason: () => 'the terrain never loaded the DEM',
      );
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
      fixture.holdStyles();
      // Only the new style has the source of the terrain.
      await map.setOptions(
        _options(
          fixture.styleUrl(fixture.style(color: '#bbddff', demId: 'dem-new')),
        ),
      );
      const terrain = Terrain(sourceId: 'dem-new', exaggeration: 1.25);
      final applied = oldStyle.setTerrain(terrain);
      // The new style loads only now.
      await tester.pump(const Duration(milliseconds: 200));
      expect(map.styleLoads, since);
      fixture.releaseStyles();
      await map.waitForStyleLoad(since: since);
      await map.pumpFuture(applied, reason: 'setTerrain never completed');
      await tester.pump();
      expect(map.style, isNot(same(oldStyle)));
      expect(map.style.terrain, terrain);
    });

    testWidgets('a terrain set during an unchanged style reload applies', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      // The same style in other JSON text: gl-js finds nothing to change and
      // fires no style.load.
      await map.setOptions(
        _options(MapStyle.json('${jsonEncode(fixture.style())}\n')),
      );
      await map.pumpFuture(
        map.style.setTerrain(_terrain),
        reason: 'setTerrain never completed',
      );
      await map.pumpUntil(
        () => map.style.terrain == _terrain,
        reason: () => 'the terrain is ${map.style.terrain}',
      );
    });

    testWidgets('a swap to the same style before the first load completes', (
      tester,
    ) async {
      // On web the fixture's protocol needs maplibre-gl-js, which the first
      // map loads.
      await pumpTerrainMap(tester);
      await tester.pumpWidget(const SizedBox());

      fixture.holdStyles();
      // The map loads only once the GeoJSON of this style arrives, after the
      // style itself has loaded.
      final json = jsonEncode({
        ...fixture.style(),
        'sources': {
          ...fixture.style()['sources']! as Map<String, Object?>,
          'held': {
            'type': 'geojson',
            'data': fixture.jsonUrl({
              'type': 'FeatureCollection',
              'features': <Object?>[],
            }),
          },
        },
      });
      var created = false;
      StyleController? loaded;
      MapApp app(String json) => MapApp(
        options: _options(MapStyle.json(json)),
        onMapCreated: (_) => created = true,
        // The latest style: native loads the swapped style again.
        onStyleLoaded: (style) => loaded = style,
      );
      Future<void> pumpUntil(bool Function() condition, String reason) async {
        final deadline = DateTime.now().add(defaultTimeout);
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $reason');
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await tester.pumpWidget(app(json));
      await pumpUntil(() => created, 'the map was never created');
      await tester.pump(const Duration(milliseconds: 300));
      // gl-js hands a style out only once its sources loaded; MapLibre
      // Native does once it parsed the style.
      if (kIsWeb) expect(loaded, isNull);
      // The same style in other JSON text, while the first is loading.
      await tester.pumpWidget(app('$json\n'));
      fixture.releaseStyles();
      await pumpUntil(() => loaded != null, 'the style never loaded');
      await loaded!.setTerrain(_terrain);
      await pumpUntil(
        () => loaded!.terrain == _terrain,
        'the terrain is ${loaded!.terrain}',
      );
    });

    testWidgets('a style that fails to load does not hold setTerrain', (
      tester,
    ) async {
      final map = await pumpTerrainMap(tester);
      final oldStyle = map.style;
      fixture.holdStyles();
      await map.setOptions(_options(fixture.styleUrl(null)));
      final failed = oldStyle.setTerrain(_terrain);
      fixture.releaseStyles();
      Object? error;
      await map.pumpFuture(
        failed.catchError((Object e) => error = e),
        reason: 'setTerrain never completed',
      );
      expect(error, isA<StateError>());
      // Later calls are not held. With no style loaded, MapLibre Native
      // rejects them, as it does every style edit; maplibre-gl-js takes them.
      await map.pumpFuture(
        map.style.setTerrain(null).then((_) {}, onError: (Object _) {}),
        reason: 'a later setTerrain never completed',
      );
    });

    testWidgets('a load that ended before a newer style was set keeps no '
        'terrain set for the newer one', (tester) async {
      final map = await pumpTerrainMap(tester);
      fixture.holdStyles();
      // In one turn of the event loop: a style that MapLibre Native parses,
      // and so loads, as soon as it runs the call, and then a style that
      // waits for its document. The first load's end reaches Dart only once
      // the second style is the latest.
      map
        ..setOptionsNow(
          _options(MapStyle.json(jsonEncode(fixture.style(color: '#ffddbb')))),
        )
        ..setOptionsNow(
          _options(fixture.styleUrl(fixture.style(color: '#bbddff'))),
        );
      var applied = false;
      final applying = map.style.setTerrain(_terrain);
      unawaited(
        applying.then((_) => applied = true, onError: (_) => applied = true),
      );
      final since = map.styleLoads;
      // The first style's events arrive meanwhile.
      await tester.pump(const Duration(milliseconds: 300));
      expect(applied, isFalse, reason: 'the newer style has not loaded');
      fixture.releaseStyles();
      await map.waitForStyleLoad(since: since);
      await map.pumpFuture(applying, reason: 'setTerrain never completed');
      await tester.pump();
      expect(map.style.terrain, _terrain);
    });

    testWidgets('reads the terrain of a style document', (tester) async {
      for (final (json, terrain) in [
        (
          {'source': 'dem', 'exaggeration': 1.5},
          const Terrain(sourceId: 'dem', exaggeration: 1.5),
        ),
        ({'source': 'dem'}, const Terrain(sourceId: 'dem')),
      ]) {
        final map = await pumpMap(
          tester,
          options: _options(
            MapStyle.json(jsonEncode({...fixture.style(), 'terrain': json})),
          ),
        );
        expect(map.style.terrain, terrain);
        expect(map.style.terrain!.exaggeration, terrain.exaggeration);
        // Show the next map in a new widget, as a new map.
        await tester.pumpWidget(const SizedBox());
      }
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

    testWidgets('a terrain on a source without heights', (tester) async {
      final map = await pumpTerrainMap(tester);
      await map.style.sources.add(
        GeoJsonSource.data(id: 'points', data: featureCollection(const [])),
      );
      await expectLater(
        map.style.setTerrain(const Terrain(sourceId: 'points')),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('"geojson"'), contains('raster-dem')),
          ),
        ),
      );
      expect(map.style.terrain, isNull);
    });

    testWidgets('setGlobalState takes doubles, strings, bools and null', (
      tester,
    ) async {
      Map<String, Object?> point(String kind, Object value) => {
        'type': 'Feature',
        'properties': {'kind': kind, 'value': value},
        'geometry': {
          'type': 'Point',
          'coordinates': [0, 0],
        },
      };
      Map<String, Object?> layer(String kind) => {
        'id': kind,
        'type': 'circle',
        'source': 'points',
        'filter': [
          'all',
          [
            '==',
            ['get', 'kind'],
            kind,
          ],
          [
            '==',
            ['get', 'value'],
            ['global-state', kind],
          ],
        ],
        'paint': {'circle-radius': 10},
      };
      final map = await pumpMap(
        tester,
        options: _options(
          MapStyle.json(
            jsonEncode({
              'version': 8,
              'state': {
                'number': {'default': 0},
                'text': {'default': ''},
                'flag': {'default': false},
                'reset': {'default': 'default'},
              },
              'sources': {
                'points': {
                  'type': 'geojson',
                  'data': {
                    'type': 'FeatureCollection',
                    'features': [
                      point('number', 2.5),
                      point('text', 'a'),
                      point('flag', true),
                      point('reset', 'default'),
                      point('reset', 'set'),
                    ],
                  },
                },
              },
              'layers': [
                for (final kind in ['number', 'text', 'flag', 'reset'])
                  layer(kind),
              ],
            }),
          ),
        ),
      );
      Future<Object?> shown(String kind) async {
        final features = await map.waitForFeatures(
          map.center,
          (features) => features.length == 1,
          layerIds: [kind],
        );
        return features.single.properties['value'];
      }

      await map.style.setGlobalState('number', 2.5);
      expect(await shown('number'), 2.5);
      await map.style.setGlobalState('text', 'a');
      expect(await shown('text'), 'a');
      await map.style.setGlobalState('flag', true);
      expect(await shown('flag'), true);

      expect(await shown('reset'), 'default');
      await map.style.setGlobalState('reset', 'set');
      await map.waitForFeatures(
        map.center,
        (features) =>
            features.length == 1 &&
            features.single.properties['value'] == 'set',
        layerIds: ['reset'],
      );
      // null resets the property to the default of the style's state.
      await map.style.setGlobalState('reset', null);
      await map.waitForFeatures(
        map.center,
        (features) =>
            features.length == 1 &&
            features.single.properties['value'] == 'default',
        layerIds: ['reset'],
      );
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

  group('terrain elevation', () {
    late AlpsFixture fixture;
    setUp(() async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
    });
    tearDown(() async => fixture.close());

    /// A map at the Alps camera over the synthetic ridge, with its terrain
    /// drawn [exaggeration] times once the camera settled on it, or without
    /// a terrain if [exaggeration] is null.
    Future<TestMap> pumpAlpsMap(
      WidgetTester tester, {
      double? exaggeration,
    }) async {
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: alpsCamera,
        ),
      );
      if (exaggeration != null) {
        await map.style.setTerrain(
          Terrain(sourceId: 'alps', exaggeration: exaggeration),
        );
        await fixture.waitUntilSettled(
          map,
          GroundView(map, exaggeration: exaggeration),
        );
      }
      return map;
    }

    for (final exaggeration in const [1.0, 1.5]) {
      testWidgets('reads the drawn height at exaggeration $exaggeration', (
        tester,
      ) async {
        final map = await pumpAlpsMap(tester, exaggeration: exaggeration);
        for (final MapEntry(key: name, value: point) in _groundPoints.entries) {
          final drawn = _drawnHeight(point, exaggeration);
          final measured = await map.controller.queryTerrainElevation(point);
          debugPrint(
            'elevation of the $name at $exaggeration: $measured m, '
            'drawn ${drawn.toStringAsFixed(2)} m',
          );
          expect(measured, isNotNull, reason: 'the $name');
          expect(measured, closeTo(drawn, 2), reason: 'the $name');
        }
      });
    }

    testWidgets('is null without a terrain', (tester) async {
      final map = await pumpAlpsMap(tester);
      final ridge = _groundPoints['ridge']!;
      expect(await map.controller.queryTerrainElevation(ridge), isNull);

      await map.style.setTerrain(const Terrain(sourceId: 'alps'));
      await fixture.waitUntilSettled(map, GroundView(map, exaggeration: 1));
      expect(await map.controller.queryTerrainElevation(ridge), isNotNull);

      await map.style.setTerrain(null);
      await map.waitForLatestFrame();
      expect(await map.controller.queryTerrainElevation(ridge), isNull);
    });

    testWidgets('is null where no DEM tile has loaded', (tester) async {
      final map = await pumpAlpsMap(tester, exaggeration: 1);
      for (final point in const [
        // East of the vendored tiles, whose server answers 404 there.
        Geographic(lon: alpsLng + 0.8, lat: alpsLat),
        // Far from them.
        Geographic(lon: 0, lat: 0),
      ]) {
        expect(
          await map.controller.queryTerrainElevation(point),
          isNull,
          reason: '$point',
        );
      }
    });

    testWidgets('reads a loaded DEM tile out of view', (tester) async {
      final map = await pumpAlpsMap(tester, exaggeration: 1);
      // On the slope 5 km behind the camera, in the DEM tile under it.
      const point = Geographic(lon: alpsLng, lat: alpsLat - 5 / _kmPerDegree);
      final measured = await map.controller.queryTerrainElevation(point);
      final drawn = _drawnHeight(point, 1);
      debugPrint(
        'elevation 5 km behind the camera: $measured m, '
        'drawn ${drawn.toStringAsFixed(2)} m',
      );
      expect(measured, closeTo(drawn, 2));
    });

    testWidgets('completes before the first frame', (tester) async {
      final style = {
        ...fixture.style(),
        'terrain': {'source': 'alps'},
      };
      final query = Completer<Future<double?>>();
      await tester.pumpWidget(
        MapApp(
          options: MapOptions(
            style: MapStyle.json(jsonEncode(style)),
            initCamera: alpsCamera,
          ),
          onMapCreated: (controller) => query.complete(
            controller.queryTerrainElevation(_groundPoints['ridge']!),
          ),
        ),
      );
      final deadline = DateTime.now().add(defaultTimeout);
      while (!query.isCompleted) {
        if (DateTime.now().isAfter(deadline)) fail('the map was not created');
        await tester.pump(const Duration(milliseconds: 50));
      }
      var done = false;
      double? measured;
      unawaited(
        query.future.then((elevation) async {
          measured = await elevation;
          done = true;
        }),
      );
      final until = DateTime.now().add(defaultTimeout);
      while (!done) {
        if (DateTime.now().isAfter(until)) fail('the query never completed');
        await tester.pump(const Duration(milliseconds: 50));
      }
      debugPrint('elevation before the first frame: $measured');
      expect(measured, anyOf(isNull, closeTo(alpsSummit, 2)));
    });
  });
}

/// Kilometers per degree of latitude on the sphere of `alps_dem.dart`.
const double _kmPerDegree = 6371.0088 * pi / 180;

/// The height in meters that the map draws at [point] of the synthetic
/// ridge, with [exaggeration]. The fixture's tiles hold each DEM pixel's
/// height at the pixel's centre, where every platform draws it.
double _drawnHeight(Geographic point, double exaggeration) =>
    alpsHeight(point.lat, point.lon) * exaggeration;

/// Points of the synthetic ridge ahead of the Alps camera, which looks north.
const Map<String, Geographic> _groundPoints = {
  'ridge': Geographic(lon: alpsLng, lat: alpsLat),
  'slope': Geographic(lon: alpsLng + 0.01, lat: alpsLat + 3 / _kmPerDegree),
  'valley floor': Geographic(
    lon: alpsLng - 0.01,
    lat: alpsLat + 12 / _kmPerDegree,
  ),
};
