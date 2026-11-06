import 'dart:math';

import 'package:maplibre/maplibre.dart';

/// The radius of the sphere of Web Mercator, in meters.
const earthRadius = 6378137;

/// The highest latitude that Web Mercator shows, rounded down to the 7
/// decimals that the GeoJSON carries.
const maxLatitude = 85.0511287;

/// The vertices of the accuracy circle. At 64, a circle 500 px wide on
/// screen strays at most 0.6 px from round.
const accuracyVertices = 64;

/// A point on the sphere, with its sines and cosines, from which points at a
/// bearing and distance are found.
class _Origin {
  _Origin(this.lon, double lat)
    : _sinLat = sin(lat * pi / 180),
      _cosLat = cos(lat * pi / 180);

  final double lon;
  final double _sinLat;
  final double _cosLat;

  /// Writes the point [distance] meters away at [bearing] degrees from
  /// north, as `lon,lat`, to [out]. Its longitude stays within 180° of
  /// [lon], unwrapped, so a ring around a point near the antimeridian stays
  /// in one piece; the map wraps it. Its latitude is clamped to what Web
  /// Mercator shows.
  void write(StringBuffer out, double bearing, double distance) {
    final angle = distance / earthRadius;
    final sinAngle = sin(angle);
    final cosAngle = cos(angle);
    final theta = bearing * pi / 180;
    final sinLat2 = (_sinLat * cosAngle + _cosLat * sinAngle * cos(theta))
        .clamp(-1.0, 1.0);
    final lat2 = asin(sinLat2);
    final dLon = atan2(
      sin(theta) * sinAngle * _cosLat,
      cosAngle - _sinLat * sinLat2,
    );
    writePosition(
      out,
      lon + dLon * 180 / pi,
      (lat2 * 180 / pi).clamp(-maxLatitude, maxLatitude),
    );
  }
}

/// Writes `[lon,lat]` with 7 decimals, about 1 cm.
void writePosition(StringBuffer out, double lon, double lat) {
  out
    ..write('[')
    ..write(_fixed(lon))
    ..write(',')
    ..write(_fixed(lat))
    ..write(']');
}

String _fixed(double value) {
  // Trailing zeros cost bytes the map parses for nothing.
  var text = value.toStringAsFixed(7);
  if (text.contains('.')) {
    var end = text.length;
    while (text.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    if (text.codeUnitAt(end - 1) == 0x2E) end--;
    text = text.substring(0, end);
  }
  return text == '-0' ? '0' : text;
}

/// The GeoJSON feature collection that a `UserLocationLayer` shows for
/// [location]: the accuracy circle (kind `accuracy`), the point of the
/// heading cone (kind `heading`, with the heading `h` from 0 to 360) and the
/// dot (kind `dot`).
///
/// The circle is left out when [showAccuracy] is false or the accuracy is
/// unknown or not positive, and the cone when the heading is unknown or
/// [showHeading] is false. The location's latitude is clamped to what Web
/// Mercator shows.
String userLocationGeoJson(
  UserLocation location, {
  required bool showAccuracy,
  required bool showHeading,
}) {
  final position = location.position;
  final lon = position.lon;
  final lat = position.lat.clamp(-maxLatitude, maxLatitude);
  final origin = _Origin(lon, lat);
  final out = StringBuffer('{"type":"FeatureCollection","features":[');
  var first = true;
  void startFeature(String kind, String geometryType, [double? heading]) {
    if (!first) out.write(',');
    first = false;
    out
      ..write('{"type":"Feature","properties":{"k":"')
      ..write(kind)
      ..write('"');
    if (heading != null) {
      out
        ..write(',"h":')
        ..write(_fixed(heading));
    }
    out
      ..write('},"geometry":{"type":"')
      ..write(geometryType)
      ..write('","coordinates":');
  }

  final accuracy = location.accuracy;
  if (showAccuracy && accuracy != null && accuracy > 0) {
    startFeature('accuracy', 'Polygon');
    out.write('[[');
    for (var i = 0; i <= accuracyVertices; i++) {
      if (i > 0) out.write(',');
      // The last vertex closes the ring on the first.
      origin.write(
        out,
        360.0 * (i % accuracyVertices) / accuracyVertices,
        accuracy,
      );
    }
    out.write(']]}}');
  }

  final heading = location.heading;
  if (showHeading && heading != null && heading.isFinite) {
    startFeature('heading', 'Point', heading % 360);
    writePosition(out, lon, lat);
    out.write('}}');
  }

  startFeature('dot', 'Point');
  writePosition(out, lon, lat);
  out.write('}}]}');
  return out.toString();
}

/// The difference between the headings [a] and [b] in degrees, from 0 to
/// 180, across north.
double headingDifference(double a, double b) {
  final difference = (a - b).abs() % 360;
  return difference > 180 ? 360 - difference : difference;
}
