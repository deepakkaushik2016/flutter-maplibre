@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_web/src/sparse_dem.dart';
import 'package:web/web.dart' as web;

@JS('eval')
external void _eval(String source);

@JS('fetched')
external JSArray<JSString> get _fetched;

/// Loads [url] through the protocol, as gl-js does; returns the resolved
/// value, or the rejection's error.
Future<({JSObject? value, JSObject? error})> _load(String url) async {
  final parameters = JSObject()..setProperty('url'.toJS, url.toJS);
  try {
    final value = await sparseDemLoad(parameters, web.AbortController()).toDart;
    return (value: value as JSObject?, error: null);
  } on Object catch (error) {
    return (value: null, error: error as JSObject);
  }
}

int? _status(JSObject? error) =>
    error?.getProperty<JSNumber?>('status'.toJS)?.toDartInt;

void main() {
  group('RasterDemTiles', () {
    test('routes the tiles of a raster-dem source through the protocol', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [
          'https://tiles.example.com/terrain/{z}/{x}/{y}.png?key=a.b',
        ]);
      expect(
        tiles.route(
          'https://tiles.example.com/terrain/13/4328/2897.png?key=a.b',
          'Tile',
        ),
        'sparse-dem://https://tiles.example.com/terrain/13/4328/2897.png?key=a.b',
      );
      // Not another URL, nor the TileJSON or another kind of request.
      expect(
        tiles.route(
          'https://tiles.example.com/terrain/13/4328/2897.png?key=aXb',
          'Tile',
        ),
        isNull,
      );
      expect(
        tiles.route('https://tiles.example.com/other/13/1/2.png', 'Tile'),
        isNull,
      );
      expect(
        tiles.route(
          'https://tiles.example.com/terrain/13/4328/2897.png?key=a.b',
          'Source',
        ),
        isNull,
      );
      final transformed = tiles.transformRequest(
        'https://tiles.example.com/terrain/1/0/0.png?key=a.b',
        'Tile',
      );
      expect(
        transformed?.getProperty<JSString>('url'.toJS).toDart,
        'sparse-dem://https://tiles.example.com/terrain/1/0/0.png?key=a.b',
      );
      expect(tiles.transformRequest('https://x.org/a.png', 'Tile'), isNull);
    });

    test("routes the URL and headers of the map's own transform", () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [
          'https://tiles.example.com/terrain/{z}/{x}/{y}.png',
        ]);
      final headers = JSObject()..setProperty('X-Key'.toJS, 'k'.toJS);
      JSObject? network(String url, String? resourceType) => JSObject()
        ..setProperty('url'.toJS, '$url?signed'.toJS)
        ..setProperty('headers'.toJS, headers);
      // A tile matches its template before the transform, and loads from the
      // transformed URL with its headers.
      final tile = tiles.transformRequest(
        'https://tiles.example.com/terrain/1/0/0.png',
        'Tile',
        network,
      );
      expect(
        tile?.getProperty<JSString>('url'.toJS).toDart,
        'sparse-dem://https://tiles.example.com/terrain/1/0/0.png?signed',
      );
      expect(tile?.getProperty<JSObject>('headers'.toJS), same(headers));
      // Other requests get the transform alone.
      final other = tiles.transformRequest(
        'https://x.org/a.png',
        'Tile',
        network,
      );
      expect(
        other?.getProperty<JSString>('url'.toJS).toDart,
        'https://x.org/a.png?signed',
      );
    });

    test('matches the other placeholders of a template', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [
          'https://{prefix}.example.com/{z}/{x}/{y}{ratio}.webp',
        ]);
      expect(
        tiles.route('https://ab.example.com/14/3/4@2x.webp', 'Tile'),
        isNotNull,
      );
      expect(
        tiles.route('https://ab.example.com/14/a/4@2x.webp', 'Tile'),
        isNull,
      );
    });

    test('leaves other sources and protocols alone', () {
      final tiles = RasterDemTiles()
        ..setSource('imagery', 'raster', ['https://example.com/{z}/{x}/{y}'])
        ..setSource('pm', 'raster-dem', [
          'pmtiles://example.com/a/{z}/{x}/{y}',
        ]);
      expect(tiles.route('https://example.com/1/0/0', 'Tile'), isNull);
      expect(tiles.route('pmtiles://example.com/a/1/0/0', 'Tile'), isNull);

      // A source that is no longer raster-dem is forgotten.
      tiles
        ..setSource('terrain', 'raster-dem', [
          'https://example.com/{z}/{x}/{y}',
        ])
        ..setSource('terrain', 'raster', ['https://example.com/{z}/{x}/{y}']);
      expect(tiles.route('https://example.com/1/0/0', 'Tile'), isNull);
    });
  });

  group('RasterDemTiles follows the sources', () {
    const template = 'https://example.com/dem/{z}/{x}/{y}.png';
    const tile = 'https://example.com/dem/13/1/2.png';
    final now = DateTime.utc(2026, 11, 6);

    test('forgets the empty tiles when a source changes or goes', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [template]);
      knownEmptyTiles
        ..clear()
        ..add(tile, now);
      // The same templates again (a repeated metadata event): kept.
      tiles.setSource('terrain', 'raster-dem', [template]);
      expect(knownEmptyTiles.length, 1);
      // Another tileset under the same id: forgotten.
      tiles.setSource('terrain', 'raster-dem', [
        'https://example.com/dem-v2/{z}/{x}/{y}.png',
      ]);
      expect(knownEmptyTiles.length, 0);
      expect(tiles.route(tile, 'Tile'), isNull);

      knownEmptyTiles.add(tile, now);
      tiles.removeSource('terrain');
      expect(knownEmptyTiles.length, 0);
      expect(tiles.sourceIds, isEmpty);
    });

    test('routes only live raster-dem sources after a style change', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [template])
        ..setSource('gone', 'raster-dem', ['https://other.com/{z}/{x}/{y}']);
      // The new style has `terrain` as a raster source of the same URLs,
      // and no `gone`.
      final raster = JSObject()
        ..setProperty('type'.toJS, 'raster'.toJS)
        ..setProperty('tiles'.toJS, [template.toJS].toJS);
      tiles.refresh((id) => id == 'terrain' ? raster : null);
      expect(tiles.route(tile, 'Tile'), isNull);
      expect(tiles.route('https://other.com/1/0/0', 'Tile'), isNull);
      expect(tiles.sourceIds, isEmpty);
    });

    test('resolves relative templates against the TileJSON', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [
          '{z}/{x}/{y}.png',
        ], base: 'https://example.com/dem/tiles.json');
      expect(tiles.route(tile, 'Tile'), isNotNull);
      final jsSource = JSObject()
        ..setProperty('type'.toJS, 'raster-dem'.toJS)
        ..setProperty('url'.toJS, 'https://example.com/a/tiles.json'.toJS)
        ..setProperty('tiles'.toJS, ['/dem/{z}/{x}/{y}.png'.toJS].toJS);
      tiles.setJsSource('other', jsSource);
      expect(tiles.route(tile, 'Tile'), isNotNull);
    });

    test('a placeholder other than z, x, y stays within a path segment', () {
      final tiles = RasterDemTiles()
        ..setSource('terrain', 'raster-dem', [
          'https://example.com/{prefix}/{z}/{x}/{y}.png',
        ]);
      expect(
        tiles.route('https://example.com/ab/1/0/0.png', 'Tile'),
        isNotNull,
      );
      expect(
        tiles.route('https://example.com/ab/cd/1/0/0.png', 'Tile'),
        isNull,
      );
    });
  });

  group('KnownEmptyTiles', () {
    final now = DateTime.utc(2026, 11, 6, 12);

    test('reads how long an empty answer holds from its headers', () {
      expect(KnownEmptyTiles.expiry(now), isNull);
      expect(
        KnownEmptyTiles.expiry(now, cacheControl: 'public, max-age=3600'),
        now.add(const Duration(hours: 1)),
      );
      expect(KnownEmptyTiles.expiry(now, cacheControl: 'no-store'), now);
      expect(KnownEmptyTiles.expiry(now, cacheControl: 'no-cache'), now);
      expect(
        KnownEmptyTiles.expiry(now, expires: 'Fri, 06 Nov 2026 13:30:00 GMT'),
        DateTime.utc(2026, 11, 6, 13, 30),
      );
      // max-age wins over Expires; an invalid Expires has expired.
      expect(
        KnownEmptyTiles.expiry(
          now,
          cacheControl: 'max-age=60',
          expires: 'Fri, 06 Nov 2026 13:30:00 GMT',
        ),
        now.add(const Duration(minutes: 1)),
      );
      expect(KnownEmptyTiles.expiry(now, expires: '0'), now);
    });

    test('drops the expired answers first at its cap', () {
      final tiles = KnownEmptyTiles()..add('kept', now);
      for (var i = 0; tiles.length < KnownEmptyTiles.maxEntries; i++) {
        tiles.add('t$i', now, cacheControl: 'max-age=60');
      }
      tiles.add('new', now.add(const Duration(minutes: 2)));
      expect(
        tiles.contains('kept', now.add(const Duration(minutes: 2))),
        isTrue,
      );
      expect(tiles.length, 2);
    });

    test('holds an answer until it expires, and stays bounded', () {
      final tiles = KnownEmptyTiles()
        ..add('a', now)
        ..add('b', now, cacheControl: 'max-age=60')
        ..add('c', now, cacheControl: 'max-age=0');
      expect(tiles.contains('a', now.add(const Duration(days: 1))), isTrue);
      expect(tiles.contains('b', now.add(const Duration(seconds: 59))), isTrue);
      expect(
        tiles.contains('b', now.add(const Duration(seconds: 60))),
        isFalse,
      );
      expect(tiles.contains('c', now), isFalse);
      for (var i = 0; i < 3 * KnownEmptyTiles.maxEntries; i++) {
        tiles.add('t$i', now);
        expect(tiles.length, lessThanOrEqualTo(KnownEmptyTiles.maxEntries));
      }
    });
  });

  group('sparseDemLoad', () {
    setUp(() {
      // A server whose tiles answer by their path: /204, /204-no-store, /404,
      // /500 and /data, which has a body. It records what was fetched.
      _eval('''
        globalThis.fetched = [];
        globalThis.fetch = async (url) => {
          fetched.push(String(url));
          const path = new URL(String(url)).pathname;
          if (path.startsWith('/204-no-store')) {
            return new Response(null, {status: 204, headers: {'Cache-Control': 'no-store'}});
          }
          if (path.startsWith('/204')) return new Response(null, {status: 204});
          if (path.startsWith('/404')) return new Response('', {status: 404});
          if (path.startsWith('/500')) return new Response('', {status: 500});
          return new Response(new Uint8Array([137, 80, 78, 71]),
              {status: 200, headers: {'Cache-Control': 'max-age=60'}});
        };
      ''');
    });

    test('answers an empty tile with a 404, once from the network', () async {
      const url = 'https://example.com/204/13/1/1.png';
      final first = await _load('sparse-dem://$url');
      expect(_status(first.error), 404);
      final second = await _load('sparse-dem://$url');
      expect(_status(second.error), 404);
      expect(_fetched.toDart.map((u) => u.toDart), [url]);

      const notFound = 'https://example.com/404/13/1/2.png';
      expect(_status((await _load('sparse-dem://$notFound')).error), 404);
      expect(_status((await _load('sparse-dem://$notFound')).error), 404);
      expect(_fetched.length, 2);
    });

    test('asks again for an empty tile that may not be reused', () async {
      const url = 'https://example.com/204-no-store/13/1/1.png';
      await _load('sparse-dem://$url');
      await _load('sparse-dem://$url');
      expect(_fetched.length, 2);
    });

    test('passes a tile with data through, with its headers', () async {
      final loaded = await _load('sparse-dem://https://example.com/data/1.png');
      expect(loaded.error, isNull);
      final data = loaded.value!.getProperty<JSArrayBuffer>('data'.toJS);
      expect(data.toDart.lengthInBytes, 4);
      expect(
        loaded.value!.getProperty<JSString?>('cacheControl'.toJS)?.toDart,
        'max-age=60',
      );
    });

    test('reports another failure as it is', () async {
      final failed = await _load('sparse-dem://https://example.com/500/1.png');
      expect(_status(failed.error), 500);
      await _load('sparse-dem://https://example.com/500/1.png');
      expect(_fetched.length, 2);
    });

    test('asks each map for a frame after an empty tile', () async {
      var frames = 0;
      void listener() => frames++;
      emptyTileListeners.add(listener);
      addTearDown(() => emptyTileListeners.remove(listener));
      await _load('sparse-dem://https://example.com/204/14/1/1.png');
      await Future<void>.delayed(Duration.zero);
      expect(frames, 1);
      await _load('sparse-dem://https://example.com/data/2.png');
      await Future<void>.delayed(Duration.zero);
      expect(frames, 1);
    });
  });
}
