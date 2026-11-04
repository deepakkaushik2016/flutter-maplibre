import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maplibre/maplibre.dart';

import 'alps_dem.dart';
import 'browser.dart';
import 'test_map.dart';

export 'alps_dem.dart';

/// The exaggeration of the terrain in the terrain camera tests, the app's.
const alpsExaggeration = 1.25;

/// The camera of the terrain camera tests: on the crest of the synthetic
/// ridge (see `alps_dem.dart`), looking north along it at zoom 13.
const alpsCamera = CameraUpdate.position(
  center: Geographic(lon: alpsLng, lat: alpsLat),
  zoom: 13,
  pitch: 60,
);

/// Serves the vendored tiles of the synthetic DEM without the network. On
/// native, a loopback server serves them and counts the requests. In the
/// browser, which has no server, they are assets of the app, whose requests
/// the browser's resource timing counts.
class AlpsFixture {
  AlpsFixture._(this._server) {
    _server?.listen(_serve);
  }

  static Future<AlpsFixture> start() async => AlpsFixture._(
    kIsWeb ? null : await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer? _server;
  var _requests = 0;

  static String _asset(int x, int y) =>
      'assets/terrain/alps/$alpsDemZoom/$x/$y.png';

  String get _tiles => kIsWeb
      ? Uri.base.resolve('assets/assets/terrain/alps/').toString()
      : 'http://127.0.0.1:${_server!.port}/';

  /// The requests for DEM tiles that exist.
  int get demRequests {
    if (!kIsWeb) return _requests;
    final (:x, :y) = alpsDemTiles;
    var requests = 0;
    for (var tileX = x.$1; tileX <= x.$2; tileX++) {
      for (var tileY = y.$1; tileY <= y.$2; tileY++) {
        requests += resourceRequests(
          Uri.base.resolve('assets/${_asset(tileX, tileY)}').toString(),
        );
      }
    }
    return requests;
  }

  /// The DEM source `alps`, over a background.
  Map<String, Object?> style() => {
    'version': 8,
    'sources': {
      'alps': {
        'type': 'raster-dem',
        'tiles': ['$_tiles{z}/{x}/{y}.png'],
        'tileSize': 256,
        'encoding': 'terrarium',
        'minzoom': alpsDemZoom,
        'maxzoom': alpsDemZoom,
      },
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#dddddd'},
      },
    ],
  };

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final match = RegExp(r'^/(\d+)/(\d+)/(\d+)\.png$')
        .firstMatch(request.uri.path);
    final (:x, :y) = alpsDemTiles;
    final tileX = int.tryParse(match?[2] ?? '') ?? -1;
    final tileY = int.tryParse(match?[3] ?? '') ?? -1;
    if (match?[1] == '$alpsDemZoom' &&
        tileX >= x.$1 &&
        tileX <= x.$2 &&
        tileY >= y.$1 &&
        tileY <= y.$2) {
      _requests++;
      final bytes = await rootBundle.load(_asset(tileX, tileY));
      response.headers.contentType = ContentType('image', 'png');
      response.add(bytes.buffer.asUint8List());
    } else {
      // Beyond the fixture: no ground there.
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() async => _server?.close(force: true);

  /// Waits until the map has loaded DEM tiles and its view of the ground
  /// stopped changing, as when the camera's center settles on the terrain:
  /// until the ground at the screen's center when the wait starts stays
  /// within 0.5 px on screen for [frames] pumped frames in a row.
  Future<void> waitUntilSettled(
    TestMap map,
    GroundView ground, {
    int frames = 10,
  }) async {
    await map.pumpUntil(
      () => demRequests > 0,
      reason: () => 'the terrain never loaded the DEM',
    );
    final point = ground.groundAt(map.center);
    var last = ground.toScreen(point);
    var stable = 0;
    await map.pumpUntil(() {
      final now = ground.toScreen(point);
      stable = (now - last).distance < 0.5 ? stable + 1 : 0;
      last = now;
      return stable >= frames;
    }, reason: () => 'the ground at $point kept moving, last at $last');
  }
}

/// Screen locations of the synthetic ground, with its heights drawn
/// [exaggeration] times.
///
/// In the browser, maplibre-gl-js projects onto the terrain itself. MapLibre
/// Native's projection is at sea level (see `.agents/decisions.md`), so on
/// native this rebuilds the camera from it and casts rays onto
/// [alpsHeight]: the eye lies on the line of sight through the screen's
/// center, whose length the sea-level scale across that center gives.
class GroundView {
  GroundView(this.map, {this.exaggeration = alpsExaggeration});

  final TestMap map;
  final double exaggeration;

  MapController get _controller => map.controller;

  /// Where [point] of the ground, at its height, is on the screen.
  Offset toScreen(Geographic point) {
    if (kIsWeb) return _controller.toScreenLocation(point);
    final eye = _Eye.of(map);
    final height = alpsHeight(point.lat, point.lon) * exaggeration;
    final ground = eye.local(point);
    // Where the line of sight to the point meets sea level.
    final t = eye.z / (eye.z - height);
    return _controller.toScreenLocation(
      eye.geographic(eye.position + (ground - eye.position) * t),
    );
  }

  /// The point of the ground that the screen shows at [screenLocation].
  Geographic groundAt(Offset screenLocation) {
    if (kIsWeb) return _controller.toLngLat(screenLocation);
    final eye = _Eye.of(map);
    final seaLevel = eye.local(_controller.toLngLat(screenLocation));
    // How far from the eye towards seaLevel, 0 to 1, and whether the line of
    // sight is under the ground there.
    Offset at(double t) => eye.position + (seaLevel - eye.position) * t;
    bool under(double t) {
      final point = eye.geographic(at(t));
      return eye.z * (1 - t) <= alpsHeight(point.lat, point.lon) * exaggeration;
    }

    const steps = 2000;
    var below = 1.0;
    for (var i = 1; i <= steps; i++) {
      if (under(i / steps)) {
        below = i / steps;
        break;
      }
    }
    var above = below - 1 / steps;
    for (var i = 0; i < 50; i++) {
      final middle = (above + below) / 2;
      if (under(middle)) {
        below = middle;
      } else {
        above = middle;
      }
    }
    return eye.geographic(at(below));
  }
}

/// The camera of the frame on screen, in meters east and north on a Web
/// Mercator plane scaled to the camera's latitude, as MapLibre measures the
/// camera's altitude.
class _Eye {
  _Eye._(this._scale, this.position, this.z);

  factory _Eye.of(TestMap map) {
    final controller = map.controller;
    final camera = controller.camera!;
    final scale = _earthRadius * cos(camera.center.lat * pi / 180);
    Offset local(Offset screen) =>
        _local(controller.toLngLat(map.center + screen), scale);
    final center = local(Offset.zero);
    final metersPerPixel =
        (local(const Offset(1, 0)) - local(const Offset(-1, 0))).distance / 2;
    // MapLibre's field of view puts the screen 1.5 heights from the eye
    // (util::DEFAULT_FOV). The focal length that the projection's own rows
    // give matches it within 0.02 % on iOS and Android.
    final distance = 1.5 * map.size.height.floorToDouble() * metersPerPixel;
    final ahead = local(const Offset(0, -10)) - center;
    final pitch = camera.pitch * pi / 180;
    return _Eye._(
      scale,
      center - ahead / ahead.distance * (distance * sin(pitch)),
      distance * cos(pitch),
    );
  }

  static const _earthRadius = 6378137.0;

  final double _scale;

  /// Meters east and north of the eye.
  final Offset position;

  /// The eye's height above sea level, in meters.
  final double z;

  static Offset _local(Geographic point, double scale) => Offset(
    point.lon * pi / 180 * scale,
    log(tan(pi / 4 + point.lat * pi / 360)) * scale,
  );

  Offset local(Geographic point) => _local(point, _scale);

  Geographic geographic(Offset local) => Geographic(
    lon: local.dx / _scale * 180 / pi,
    lat: (2 * atan(exp(local.dy / _scale)) - pi / 2) * 180 / pi,
  );
}
