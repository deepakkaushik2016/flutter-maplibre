/// Terrain over a sparse raster-dem tileset on the web.
///
/// A sparse tileset has its finer zooms only where it needs them, and answers
/// every tile it does not have with an empty response: `204 No Content`, or a
/// 404. The tile is then drawn from its nearest ancestor with data, overzoomed,
/// as on the other platforms.
///
/// maplibre-gl-js does that for a 404, but not for a 204. It takes a raster-dem
/// tile that loaded empty as loaded with data (`Tile.hasData`), so it never
/// looks for the tile's parents. The terrain gets its heights only from the
/// one parent that gl-js always adds for a terrain tile, and from a z5
/// ancestor. Over a tileset with z13-14 only in some boxes, one empty zoom
/// works (z13, drawn from z12). Two empty zooms (z14 and z13, at map zoom 15
/// and over) draw the terrain from z5.
///
/// So raster-dem tiles load through the [sparseDemProtocol] protocol. It
/// fetches the tile as gl-js would, and answers an empty response with a 404
/// error, which gl-js takes quietly (no `error` event) and covers with the
/// nearest loaded ancestor, as it does a missing tile. It remembers which
/// tiles were empty, so they are not fetched again when the view comes back
/// to them, for as long as their response's `Cache-Control` or `Expires`
/// allows, and for the session when it had neither.
///
/// This file uses no Flutter API, so it also runs in a page of its own (the
/// headless browser tests of the terrain fixture).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The name of the protocol that raster-dem tiles load through.
const sparseDemProtocol = 'sparse-dem';
const _prefix = '$sparseDemProtocol://';

/// The raster-dem tile URL templates of a map's sources, by source id, so
/// that [route] can tell a raster-dem tile's URL from another tile's.
class RasterDemTiles {
  final _patterns = <String, List<RegExp>>{};

  /// Takes the tile URL templates of the source [id] when it is a raster-dem
  /// source, and forgets the source's templates otherwise.
  ///
  /// Only http and https templates are taken: a tile of another protocol
  /// (`pmtiles://`, say) loads through that protocol, as before.
  void setSource(String id, String? type, Iterable<String> templates) {
    final patterns = [
      if (type == 'raster-dem')
        for (final template in templates)
          if (template.startsWith('http://') || template.startsWith('https://'))
            _pattern(template),
    ];
    if (patterns.isEmpty) {
      _patterns.remove(id);
    } else {
      _patterns[id] = patterns;
    }
  }

  /// Takes the templates of the gl-js source [source] (`map.getSource(id)`),
  /// which holds them once its TileJSON has loaded.
  void setJsSource(String id, JSObject? source) {
    final tiles = source?.getProperty<JSAny?>('tiles'.toJS);
    setSource(id, source?.getProperty<JSString?>('type'.toJS)?.toDart, [
      if (tiles != null && tiles.isA<JSArray>())
        for (final tile in (tiles as JSArray<JSAny?>).toDart)
          if (tile != null && tile.isA<JSString>()) (tile as JSString).toDart,
    ]);
  }

  /// The URL that gl-js loads [url] from: through [sparseDemProtocol] when
  /// it is a tile of a raster-dem source, otherwise null (unchanged).
  String? route(String url, String? resourceType) {
    if (resourceType != 'Tile' || _patterns.isEmpty) return null;
    for (final patterns in _patterns.values) {
      for (final pattern in patterns) {
        if (pattern.hasMatch(url)) return '$_prefix$url';
      }
    }
    return null;
  }

  /// A gl-js `transformRequest` that applies [network], a map's own
  /// transform (such as `MapLibreNetwork`'s URL and headers), and then
  /// [route]: a raster-dem tile goes through [sparseDemProtocol] to the URL
  /// that [network] made of it, with its headers. A tile matches its
  /// source's template as gl-js made the URL, before [network].
  JSObject? transformRequest(
    String url,
    String? resourceType, [
    JSObject? Function(String url, String? resourceType)? network,
  ]) {
    final request = network?.call(url, resourceType);
    if (route(url, resourceType) == null) return request;
    final target = request?.getProperty<JSString?>('url'.toJS)?.toDart ?? url;
    return (request ?? JSObject())
      ..setProperty('url'.toJS, '$_prefix$target'.toJS);
  }

  /// A tile URL template as a pattern that matches the URLs gl-js makes of
  /// it: `{z}`, `{x}`, `{y}` are numbers, and any other placeholder
  /// (`{ratio}`, `{quadkey}`, `{bbox-epsg-3857}`, `{prefix}`) is any text.
  static RegExp _pattern(String template) {
    final pattern = StringBuffer('^');
    var rest = template;
    final placeholder = RegExp(r'\{[^}]*\}');
    while (true) {
      final match = placeholder.firstMatch(rest);
      if (match == null) break;
      pattern
        ..write(RegExp.escape(rest.substring(0, match.start)))
        ..write(switch (match[0]) {
          '{z}' || '{x}' || '{y}' => r'\d+',
          _ => '.*?',
        });
      rest = rest.substring(match.end);
    }
    pattern
      ..write(RegExp.escape(rest))
      ..write(r'$');
    return RegExp(pattern.toString());
  }
}

/// The tile URLs that answered empty, with when that answer expires (null:
/// it holds for the session).
///
/// Bounded: past [maxEntries] it starts over, which costs at most one more
/// request per tile. An entry is a URL and a date, a few hundred bytes, so
/// some 1 MB at most.
class KnownEmptyTiles {
  /// The most URLs held.
  static const maxEntries = 4096;

  final _entries = <String, DateTime?>{};

  /// How many URLs are held.
  int get length => _entries.length;

  /// Whether [url] answered empty, and that answer still holds at [now].
  bool contains(String url, DateTime now) {
    if (!_entries.containsKey(url)) return false;
    final expires = _entries[url];
    if (expires != null && !expires.isAfter(now)) {
      _entries.remove(url);
      return false;
    }
    return true;
  }

  /// Records that [url] answered empty, with the response's [cacheControl]
  /// and [expires] headers. A response that may not be reused
  /// (`no-store`, `no-cache`, `max-age=0`) expires at once.
  void add(String url, DateTime now, {String? cacheControl, String? expires}) {
    final until = expiry(now, cacheControl: cacheControl, expires: expires);
    if (_entries.length >= maxEntries && !_entries.containsKey(url)) {
      _entries.clear();
    }
    _entries[url] = until;
  }

  /// When a response with the [cacheControl] and [expires] headers expires:
  /// null when it says nothing (it holds for the session), [now] when it may
  /// not be reused.
  static DateTime? expiry(
    DateTime now, {
    String? cacheControl,
    String? expires,
  }) {
    if (cacheControl != null) {
      final directives = cacheControl
          .toLowerCase()
          .split(',')
          .map((d) => d.trim());
      if (directives.contains('no-store') || directives.contains('no-cache')) {
        return now;
      }
      for (final directive in directives) {
        if (directive.startsWith('max-age=')) {
          final seconds = int.tryParse(directive.substring(8).trim());
          if (seconds != null) return now.add(Duration(seconds: seconds));
        }
      }
    }
    if (expires != null) {
      final date = _parseHttpDate(expires);
      // An invalid date ("0", say) means already expired.
      return date ?? now;
    }
    return null;
  }

  static const _months = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  /// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the form HTTP sends.
  static DateTime? _parseHttpDate(String value) {
    final match = RegExp(
      r'^\s*\w{3},\s*(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT\s*$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;
    final month = _months.indexOf(match[2]!.toLowerCase());
    if (month < 0) return null;
    return DateTime.utc(
      int.parse(match[3]!),
      month + 1,
      int.parse(match[1]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
  }
}

/// The empty tiles that [sparseDemLoad] has seen, for every map of the page:
/// the protocol is global in gl-js.
final knownEmptyTiles = KnownEmptyTiles();

/// Called after [sparseDemLoad] answered a tile with a 404, once gl-js has
/// taken the answer: each map adds one that asks it for a frame.
///
/// gl-js covers a tile that failed with a 404 in its tile update, but draws
/// no frame for it, and the map fires `idle` only at the end of a frame. When
/// the empty tile was the last one the map waited for, the map never fired
/// `idle` until something else moved it.
final emptyTileListeners = <void Function()>{};

void _notFoundAnswered() {
  if (emptyTileListeners.isEmpty) return;
  // After gl-js's own handling of the rejection, which runs in microtasks.
  Timer.run(() {
    for (final listener in emptyTileListeners.toList()) {
      listener();
    }
  });
}

/// The [sparseDemProtocol] protocol's load function, as gl-js calls it:
/// `(requestParameters, abortController) => Promise<{data, cacheControl,
/// expires}>`.
JSPromise<JSAny?> sparseDemLoad(
  JSObject requestParameters,
  web.AbortController abortController,
) => JSPromise<JSAny?>(
  (JSFunction resolve, JSFunction reject) {
    _load(requestParameters, abortController).then(
      (result) => switch (result) {
        _Loaded(:final value) => resolve.callAsFunction(null, value),
        _Failed(:final error, :final empty) => () {
          reject.callAsFunction(null, error);
          if (empty) _notFoundAnswered();
        }(),
      },
      // The fetch failed or was aborted (gl-js then ignores the answer).
      onError: (Object error) => reject.callAsFunction(null, _error(error)),
    );
  }.toJS,
);

/// What [_load] answers gl-js with.
sealed class _Result {}

final class _Loaded extends _Result {
  _Loaded(this.value);
  final JSObject value;
}

final class _Failed extends _Result {
  _Failed(this.error, {this.empty = false});
  final JSObject error;

  /// Whether the tile is empty: [error] is the 404 that stands for that.
  final bool empty;
}

Future<_Result> _load(
  JSObject requestParameters,
  web.AbortController abortController,
) async {
  final routed = requestParameters.getProperty<JSString>('url'.toJS).toDart;
  final url = routed.startsWith(_prefix)
      ? routed.substring(_prefix.length)
      : routed;
  if (knownEmptyTiles.contains(url, DateTime.now())) {
    return _Failed(_notFound(url), empty: true);
  }

  final init = web.RequestInit(signal: abortController.signal);
  final headers = requestParameters.getProperty<JSAny?>('headers'.toJS);
  if (headers != null) init.headers = headers as web.HeadersInit;
  final credentials = requestParameters.getProperty<JSString?>(
    'credentials'.toJS,
  );
  if (credentials != null) init.credentials = credentials.toDart;
  final response = await web.window.fetch(url.toJS, init).toDart;
  final cacheControl = response.headers.get('Cache-Control');
  final expires = response.headers.get('Expires');

  // A 204 has no body, so it is empty below.
  if (response.status == 404) {
    knownEmptyTiles.add(
      url,
      DateTime.now(),
      cacheControl: cacheControl,
      expires: expires,
    );
    return _Failed(_notFound(url), empty: true);
  }
  if (!response.ok) {
    return _Failed(_ajaxError(response.status, response.statusText, url));
  }
  final data = await response.arrayBuffer().toDart;
  if (data.toDart.lengthInBytes == 0) {
    knownEmptyTiles.add(
      url,
      DateTime.now(),
      cacheControl: cacheControl,
      expires: expires,
    );
    return _Failed(_notFound(url), empty: true);
  }
  final result = JSObject()..setProperty('data'.toJS, data);
  if (cacheControl != null) {
    result.setProperty('cacheControl'.toJS, cacheControl.toJS);
  }
  if (expires != null) result.setProperty('expires'.toJS, expires.toJS);
  return _Loaded(result);
}

/// The error gl-js takes as a missing tile: one with status 404.
JSObject _notFound(String url) => _ajaxError(404, 'Not Found', url);

/// A gl-js `AJAXError`, or an `Error` with the same fields where gl-js does
/// not export the class.
JSObject _ajaxError(int status, String statusText, String url) {
  final maplibregl = globalContext.getProperty<JSObject?>('maplibregl'.toJS);
  final constructor = maplibregl?.getProperty<JSFunction?>('AJAXError'.toJS);
  if (constructor != null) {
    return constructor.callAsConstructor<JSObject>(
      status.toJS,
      statusText.toJS,
      url.toJS,
      web.Blob(),
    );
  }
  return _error('AJAXError: $statusText ($status): $url')
    ..setProperty('status'.toJS, status.toJS)
    ..setProperty('statusText'.toJS, statusText.toJS)
    ..setProperty('url'.toJS, url.toJS);
}

JSObject _error(Object error) => globalContext
    .getProperty<JSFunction>('Error'.toJS)
    .callAsConstructor<JSObject>(error.toString().toJS);
