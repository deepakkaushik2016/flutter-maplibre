import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Where the map camera goes: to a position, or to a camera that fits
/// bounds, points or a geometry into the map.
///
/// [MapController.moveCamera], [MapController.animateCamera],
/// [MapController.cameraFor] and [MapOptions.initCamera] take it.
///
/// ```dart
/// controller.moveCamera(const CameraUpdate.position(zoom: 12));
/// controller.animateCamera(CameraUpdate.bounds(bounds));
/// controller.moveCamera(
///   CameraUpdate.fromEye(trailPoint, bearing: 40, pitch: 100, aboveTerrain: 2),
/// );
/// ```
///
/// {@category Basic}
@immutable
sealed class CameraUpdate {
  const CameraUpdate();

  /// Sets the given fields of the camera. A null field keeps its current
  /// value, or MapLibre's default when the map starts.
  const factory CameraUpdate.position({
    Geographic? center,
    double? zoom,
    double? bearing,
    double? pitch,
    double? roll,
    EdgeInsets? padding,
    Offset? anchor,
  }) = CameraUpdatePosition;

  /// Fits [bounds] into the map, inset by [padding].
  const factory CameraUpdate.bounds(
    GeoBox bounds, {
    EdgeInsets padding,
    double? bearing,
    double? pitch,
    double? maxZoom,
  }) = CameraUpdateBounds;

  /// Fits all [points] into the map, inset by [padding].
  const factory CameraUpdate.points(
    List<Geographic> points, {
    EdgeInsets padding,
    double? bearing,
    double? pitch,
    double? maxZoom,
  }) = CameraUpdatePoints;

  /// Fits [geometry] into the map, inset by [padding].
  const factory CameraUpdate.geometry(
    Geometry geometry, {
    EdgeInsets padding,
    double? bearing,
    double? pitch,
    double? maxZoom,
  }) = CameraUpdateGeometry;

  /// Places the camera itself at [eye], looking towards [bearing] at
  /// [pitch], for example to see what a person standing on a trail sees.
  ///
  /// The eye is [altitude] meters above sea level, or [aboveTerrain] meters
  /// above the terrain as the map draws it, with its exaggeration. Pass
  /// exactly one of them, or this throws an [ArgumentError].
  ///
  /// A [pitch] over 90 degrees looks above the horizon; the map shows it up
  /// to its [MapOptions.maxPitch], and a steeper or flatter [pitch] is
  /// limited to [MapOptions.minPitch] and [MapOptions.maxPitch] with the
  /// eye kept in place. The roll and padding of the camera stay as they
  /// are. [MapController.animateCamera] moves the eye along a straight line
  /// and turns it on the way, also for [CameraAnimation.fly].
  ///
  /// While the camera stays at the eye, the map's center is not clamped to
  /// the ground, whatever [MapOptions.centerClampedToGround] says. A later
  /// camera update that is not from an eye brings it back, and so does a
  /// gesture that starts at a pitch under 90 degrees, both with the camera
  /// kept in place.
  ///
  /// With [aboveTerrain], [MapController.moveCamera],
  /// [MapController.animateCamera] and [MapController.cameraFor] fail with a
  /// [TerrainElevationUnavailableException] when the map has no terrain or
  /// no height of it at [eye] yet, and the camera doesn't move.
  ///
  /// Only supported on web, and only for maps and still images with
  /// [altitude]. Elsewhere, moving the camera to it fails with an
  /// [UnsupportedError].
  factory CameraUpdate.fromEye(
    Geographic eye, {
    required double bearing,
    required double pitch,
    double? altitude,
    double? aboveTerrain,
  }) = CameraUpdateEye;
}

/// A [CameraUpdate] that sets fields of the camera, see
/// [CameraUpdate.position].
///
/// {@category Basic}
final class CameraUpdatePosition extends CameraUpdate {
  /// Creates a [CameraUpdate] that sets fields of the camera.
  const CameraUpdatePosition({
    this.center,
    this.zoom,
    this.bearing,
    this.pitch,
    this.roll,
    this.padding,
    this.anchor,
  });

  /// The center of the map.
  final Geographic? center;

  /// The zoom level.
  final double? zoom;

  /// The bearing in degrees, 0 is north on top.
  final double? bearing;

  /// The pitch in degrees.
  final double? pitch;

  /// The roll in degrees.
  final double? roll;

  /// The insets in logical pixels that move the center of the camera away
  /// from the center of the map, for example to keep it clear of an overlay.
  final EdgeInsets? padding;

  /// The screen location in logical pixels that stays in place while the
  /// camera zooms or rotates. Without it, the camera zooms and rotates
  /// around [center].
  final Offset? anchor;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraUpdatePosition &&
          center == other.center &&
          zoom == other.zoom &&
          bearing == other.bearing &&
          pitch == other.pitch &&
          roll == other.roll &&
          padding == other.padding &&
          anchor == other.anchor;

  @override
  int get hashCode =>
      Object.hash(center, zoom, bearing, pitch, roll, padding, anchor);

  @override
  String toString() =>
      'CameraUpdate.position(center: $center, zoom: $zoom, '
      'bearing: $bearing, pitch: $pitch, roll: $roll, padding: $padding, '
      'anchor: $anchor)';
}

/// A [CameraUpdate] that fits a target into the map: [CameraUpdateBounds],
/// [CameraUpdatePoints] or [CameraUpdateGeometry].
///
/// {@category Basic}
sealed class CameraUpdateFit extends CameraUpdate {
  const CameraUpdateFit({
    this.padding = EdgeInsets.zero,
    this.bearing,
    this.pitch,
    this.maxZoom,
  });

  /// The space in logical pixels between the target and the map's edges.
  final EdgeInsets padding;

  /// The bearing in degrees, 0 is north on top. Null keeps the current one.
  final double? bearing;

  /// The pitch in degrees. Null keeps the current one.
  final double? pitch;

  /// The highest zoom level, so that a small target is not shown too close.
  final double? maxZoom;

  /// The smallest box that contains the target.
  GeoBox get bounds;

  bool _fitEquals(CameraUpdateFit other) =>
      padding == other.padding &&
      bearing == other.bearing &&
      pitch == other.pitch &&
      maxZoom == other.maxZoom;

  String get _fitString =>
      'padding: $padding, bearing: $bearing, pitch: $pitch, '
      'maxZoom: $maxZoom';
}

/// A [CameraUpdate] that fits bounds into the map, see
/// [CameraUpdate.bounds].
///
/// {@category Basic}
final class CameraUpdateBounds extends CameraUpdateFit {
  /// Creates a [CameraUpdate] that fits [bounds] into the map.
  const CameraUpdateBounds(
    this.bounds, {
    super.padding,
    super.bearing,
    super.pitch,
    super.maxZoom,
  });

  @override
  final GeoBox bounds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraUpdateBounds &&
          bounds == other.bounds &&
          _fitEquals(other);

  @override
  int get hashCode => Object.hash(bounds, padding, bearing, pitch, maxZoom);

  @override
  String toString() => 'CameraUpdate.bounds($bounds, $_fitString)';
}

/// A [CameraUpdate] that fits points into the map, see
/// [CameraUpdate.points].
///
/// {@category Basic}
final class CameraUpdatePoints extends CameraUpdateFit {
  /// Creates a [CameraUpdate] that fits all [points] into the map.
  const CameraUpdatePoints(
    this.points, {
    super.padding,
    super.bearing,
    super.pitch,
    super.maxZoom,
  });

  /// The points that the map shows.
  final List<Geographic> points;

  @override
  GeoBox get bounds {
    if (points.isEmpty) {
      throw ArgumentError.value(points, 'points', 'must not be empty');
    }
    var west = points.first.lon;
    var east = west;
    var south = points.first.lat;
    var north = south;
    for (final point in points.skip(1)) {
      if (point.lon < west) west = point.lon;
      if (point.lon > east) east = point.lon;
      if (point.lat < south) south = point.lat;
      if (point.lat > north) north = point.lat;
    }
    return GeoBox(west: west, south: south, east: east, north: north);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraUpdatePoints &&
          listEquals(points, other.points) &&
          _fitEquals(other);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(points), padding, bearing, pitch, maxZoom);

  @override
  String toString() => 'CameraUpdate.points($points, $_fitString)';
}

/// A [CameraUpdate] that fits a geometry into the map, see
/// [CameraUpdate.geometry].
///
/// {@category Basic}
final class CameraUpdateGeometry extends CameraUpdateFit {
  /// Creates a [CameraUpdate] that fits [geometry] into the map.
  const CameraUpdateGeometry(
    this.geometry, {
    super.padding,
    super.bearing,
    super.pitch,
    super.maxZoom,
  });

  /// The geometry that the map shows.
  final Geometry geometry;

  @override
  GeoBox get bounds {
    final box = geometry.bounds ?? geometry.calculateBounds();
    if (box == null) {
      throw ArgumentError.value(geometry, 'geometry', 'must not be empty');
    }
    return GeoBox(
      west: box.minX,
      south: box.minY,
      east: box.maxX,
      north: box.maxY,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraUpdateGeometry &&
          geometry == other.geometry &&
          _fitEquals(other);

  @override
  int get hashCode => Object.hash(geometry, padding, bearing, pitch, maxZoom);

  @override
  String toString() =>
      'CameraUpdate.geometry(${geometry.toText()}, $_fitString)';
}

/// A [CameraUpdate] that places the camera itself at an eye, see
/// [CameraUpdate.fromEye].
///
/// {@category Basic}
final class CameraUpdateEye extends CameraUpdate {
  /// Creates a [CameraUpdate] that places the camera at [eye].
  ///
  /// Throws an [ArgumentError] unless exactly one of [altitude] and
  /// [aboveTerrain] is given.
  CameraUpdateEye(
    this.eye, {
    required this.bearing,
    required this.pitch,
    this.altitude,
    this.aboveTerrain,
  }) {
    if ((altitude == null) == (aboveTerrain == null)) {
      throw ArgumentError(
        'Pass exactly one of altitude and aboveTerrain, '
        'not ${altitude == null ? 'neither' : 'both'}.',
      );
    }
  }

  /// Where the camera is.
  final Geographic eye;

  /// The bearing in degrees that the camera looks towards, 0 is north.
  final double bearing;

  /// The pitch in degrees, 0 looks straight down and over 90 above the
  /// horizon.
  final double pitch;

  /// The height of the eye in meters above sea level, or null if
  /// [aboveTerrain] gives it.
  final double? altitude;

  /// The height of the eye in meters above the terrain as the map draws it,
  /// or null if [altitude] gives it.
  final double? aboveTerrain;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraUpdateEye &&
          eye == other.eye &&
          bearing == other.bearing &&
          pitch == other.pitch &&
          altitude == other.altitude &&
          aboveTerrain == other.aboveTerrain;

  @override
  int get hashCode => Object.hash(eye, bearing, pitch, altitude, aboveTerrain);

  @override
  String toString() =>
      'CameraUpdate.fromEye($eye, bearing: $bearing, pitch: $pitch, '
      'altitude: $altitude, aboveTerrain: $aboveTerrain)';
}

/// The map has no height of its terrain at a point, because it has no
/// terrain or its elevation data for the point hasn't loaded yet.
///
/// [CameraUpdate.fromEye] with `aboveTerrain` fails with it.
///
/// {@category Basic}
final class TerrainElevationUnavailableException implements Exception {
  /// Creates an exception for the terrain at [point].
  const TerrainElevationUnavailableException(this.point);

  /// Where the map has no height of its terrain.
  final Geographic point;

  @override
  String toString() =>
      'TerrainElevationUnavailableException: the map has no terrain height '
      'at $point';
}
