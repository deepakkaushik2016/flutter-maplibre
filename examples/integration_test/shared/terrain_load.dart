import 'dart:async';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:maplibre/maplibre.dart';

import 'alps_dem.dart';

/// A style of the terrain soak and performance tests: [style] with a
/// hillshade of its raster DEM source [demId] and a trail over the ridge, so
/// each frame draws what a trail map draws over its terrain.
Map<String, Object?> trailStyle(
  Map<String, Object?> style, {
  String demId = 'alps',
}) => {
  ...style,
  'sources': {
    ...(style['sources']! as Map<String, Object?>),
    'trail': {'type': 'geojson', 'data': _trail},
  },
  'layers': [
    ...(style['layers']! as List<Object?>),
    {'id': 'hillshade', 'type': 'hillshade', 'source': demId},
    {
      'id': 'trail',
      'type': 'line',
      'source': 'trail',
      'paint': {'line-color': '#d02020', 'line-width': 4},
    },
  ],
};

/// A trail from the southern valley over the crest, along [scrubPath].
final Map<String, Object?> _trail = {
  'type': 'Feature',
  'properties': <String, Object?>{},
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      for (final point in scrubPath(points: 64)) [point.lon, point.lat],
    ],
  },
};

/// The middle of the trail of [trailStyle], where a scrub looks at it.
const trailCenter = Geographic(lon: alpsLng, lat: alpsLat - 0.03);

/// [points] positions of a scrub along the trail of [trailStyle], 8 km
/// from the southern valley over the crest at [alpsLng]. The trail stays
/// on one DEM tile (y 359 at [alpsDemZoom]), whose northern edge runs 1.6 km
/// north of the crest: after a flight, MapLibre Native's elevations within
/// half a DEM pixel of a tile edge can be 15 m off, as if the tile's border
/// were no longer filled from its neighbour.
List<Geographic> scrubPath({int points = 300}) => [
  for (var i = 0; i < points; i++)
    Geographic(
      lon: alpsLng + 0.01 * sin(i / (points - 1) * 2 * pi),
      lat: trailCenter.lat - 0.036 + 0.072 * i / (points - 1),
    ),
];

/// A camera position of a flight over the synthetic ridge.
typedef Waypoint = ({double eastKm, double northKm, double bearing});

/// The waypoints of a flight: along the crest, down into the valleys and
/// back, turning all the way round.
const List<Waypoint> _waypoints = [
  (eastKm: 0, northKm: 0, bearing: 0),
  (eastKm: 6, northKm: 0, bearing: 45),
  (eastKm: 12, northKm: -3, bearing: 90),
  (eastKm: 6, northKm: -6, bearing: 135),
  (eastKm: 0, northKm: -3, bearing: 180),
  (eastKm: -6, northKm: 0, bearing: 225),
  (eastKm: -12, northKm: 3, bearing: 270),
  (eastKm: -6, northKm: 6, bearing: 315),
];

const double _kmPerDegree = 6371.0088 * pi / 180;

/// Flies [controller] over the synthetic ridge at [pitch] and zoom 13, one
/// leg of [leg] after another, until [stop] completes. Each leg is a camera
/// animation of the engine, so the map renders every frame of the flight
/// with no work per frame in Dart.
Future<void> flyOverRidge(
  MapController controller, {
  required double pitch,
  required Future<void> stop,
  Duration leg = const Duration(seconds: 5),
}) async {
  var stopped = false;
  unawaited(stop.whenComplete(() => stopped = true));
  for (var i = 1; !stopped; i++) {
    final waypoint = _waypoints[i % _waypoints.length];
    await controller.animateCamera(
      CameraUpdate.position(
        center: Geographic(
          lon:
              alpsLng +
              waypoint.eastKm / (_kmPerDegree * cos(alpsLat * pi / 180)),
          lat: alpsLat + waypoint.northKm / _kmPerDegree,
        ),
        zoom: 13,
        bearing: waypoint.bearing,
        pitch: pitch,
      ),
      animation: CameraAnimation.fly(duration: leg),
    );
  }
}

/// Records how often the map's image changes on screen, and Flutter's own
/// frame timings, while [recording].
///
/// The map renders on the engine's own thread, at its own rate, and Flutter
/// shows its newest frame in the next Flutter frame. Flutter can draw
/// frames that show no new map image, so its frame timings alone do not
/// tell how smooth the map is. `MapController.camera` follows the map frame
/// that Flutter shows, so the Flutter frames whose camera changed are the
/// ones that showed a new map frame, and the time between their vsyncs is
/// the map's frame time on screen. Meaningful while the camera moves in
/// every map frame, as during [flyOverRidge].
class MapFrameRecorder {
  MapFrameRecorder(this.controller) {
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  final MapController controller;

  /// Whether frames are recorded.
  bool recording = false;

  final _mapFrameMs = <double>[];
  final _flutterFrameMs = <double>[];
  Duration? _lastMapFrame;
  CameraPosition? _lastCamera;
  var _disposed = false;

  /// The time between consecutive new map images on screen, in ms.
  List<double> get mapFrameMs => List.unmodifiable(_mapFrameMs);

  /// The total time of each Flutter frame, from vsync to the end of its
  /// rasterization, in ms.
  List<double> get flutterFrameMs => List.unmodifiable(_flutterFrameMs);

  /// Starts a new recording, forgetting earlier frames.
  void start() {
    _mapFrameMs.clear();
    _flutterFrameMs.clear();
    _lastMapFrame = null;
    _lastCamera = controller.camera;
    recording = true;
  }

  void _onFrame(Duration _) {
    if (_disposed || !recording) return;
    final camera = controller.camera;
    if (camera == _lastCamera) return;
    _lastCamera = camera;
    final vsync = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (_lastMapFrame case final last?) {
      _mapFrameMs.add((vsync - last).inMicroseconds / 1000);
    }
    _lastMapFrame = vsync;
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_disposed || !recording) return;
    for (final timing in timings) {
      _flutterFrameMs.add(timing.totalSpan.inMicroseconds / 1000);
    }
  }

  /// Stops recording for good. A persistent frame callback cannot be
  /// removed, so it stays and does nothing.
  void dispose() {
    _disposed = true;
    recording = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }
}

/// The median, 95th percentile and maximum of some durations in ms.
class DurationStats {
  factory DurationStats.of(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return const DurationStats._(0, double.nan, 0, 0);
    double rank(double p) => sorted[(p * sorted.length).ceil() - 1];
    return DurationStats._(sorted.length, rank(0.5), rank(0.95), sorted.last);
  }

  const DurationStats._(this.count, this.median, this.p95, this.max);

  final int count;
  final double median;
  final double p95;
  final double max;

  /// Frames per second at the median frame time.
  double get medianFps => 1000 / median;

  Map<String, Object> toJson() => {
    'count': count,
    'median_ms': _round(median),
    'p95_ms': _round(p95),
    'max_ms': _round(max),
  };

  @override
  String toString() =>
      'n=$count median=${median.toStringAsFixed(2)} ms '
      '(${medianFps.toStringAsFixed(1)} fps) '
      'p95=${p95.toStringAsFixed(2)} ms max=${max.toStringAsFixed(2)} ms';
}

double _round(double value) => (value * 100).roundToDouble() / 100;
