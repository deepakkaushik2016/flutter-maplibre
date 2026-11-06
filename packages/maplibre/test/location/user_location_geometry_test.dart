import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre/src/location/user_location_geometry.dart';

typedef _Position = ({double lon, double lat});

/// The features of [location] as the layer shows them.
List<Map<String, Object?>> _features(
  UserLocation location, {
  bool showAccuracy = true,
  bool showHeading = true,
}) {
  final json = jsonDecode(
    userLocationGeoJson(
      location,
      showAccuracy: showAccuracy,
      showHeading: showHeading,
    ),
  ) as Map<String, Object?>;
  return [
    for (final feature in json['features']! as List<Object?>)
      feature! as Map<String, Object?>,
  ];
}

String _kind(Map<String, Object?> feature) =>
    (feature['properties']! as Map)['k'] as String;

List<_Position> _ring(Map<String, Object?> feature) {
  final geometry = feature['geometry']! as Map;
  expect(geometry['type'], 'Polygon');
  final rings = geometry['coordinates'] as List;
  expect(rings, hasLength(1));
  return [
    for (final position in rings.single as List)
      (
        lon: ((position as List)[0] as num).toDouble(),
        lat: (position[1] as num).toDouble(),
      ),
  ];
}

/// The great-circle distance in meters, on the sphere of the geometry.
double _distance(_Position a, _Position b) {
  final lat1 = a.lat * pi / 180;
  final lat2 = b.lat * pi / 180;
  final dLat = lat2 - lat1;
  final dLon = (b.lon - a.lon) * pi / 180;
  final h =
      pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2);
  return 2 * earthRadius * asin(sqrt(h));
}

/// The initial bearing from [a] to [b] in degrees, 0 to 360.
double _bearing(_Position a, _Position b) {
  final lat1 = a.lat * pi / 180;
  final lat2 = b.lat * pi / 180;
  final dLon = (b.lon - a.lon) * pi / 180;
  final y = sin(dLon) * cos(lat2);
  final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

void main() {
  group('userLocationGeoJson', () {
    test('draws the accuracy, the cone and the dot', () {
      final features = _features(
        const UserLocation(
          position: Geographic(lon: 11, lat: 47),
          accuracy: 20,
          heading: 90,
        ),
      );
      expect(features.map(_kind), ['accuracy', 'heading', 'dot']);
      expect((features[1]['geometry']! as Map)['coordinates'], [11, 47]);
      expect((features.last['geometry']! as Map)['coordinates'], [11, 47]);
    });

    test('leaves out an unknown accuracy and heading', () {
      expect(
        _features(const UserLocation(position: Geographic(lon: 11, lat: 47)))
            .map(_kind),
        ['dot'],
      );
      expect(
        _features(
          const UserLocation(
            position: Geographic(lon: 11, lat: 47),
            accuracy: 0,
          ),
        ).map(_kind),
        ['dot'],
      );
    });

    test('leaves out what the style hides', () {
      expect(
        _features(
          const UserLocation(
            position: Geographic(lon: 11, lat: 47),
            accuracy: 20,
            heading: 0,
          ),
          showAccuracy: false,
          showHeading: false,
        ).map(_kind),
        ['dot'],
      );
    });

    test('draws the accuracy as a closed geodesic circle', () {
      const center = (lon: 11.0, lat: 47.0);
      final ring = _ring(
        _features(
          const UserLocation(
            position: Geographic(lon: 11, lat: 47),
            accuracy: 2500,
          ),
        ).first,
      );
      expect(ring, hasLength(accuracyVertices + 1));
      expect(ring.last, ring.first);
      for (final (index, vertex) in ring.indexed) {
        expect(_distance(center, vertex), closeTo(2500, 0.05));
        if (index < accuracyVertices) {
          expect(
            _bearing(center, vertex),
            closeTo(360.0 * index / accuracyVertices, 1e-3),
          );
        }
      }
    });

    test('keeps a circle across the antimeridian in one piece', () {
      const center = (lon: 179.99, lat: -16.0);
      final ring = _ring(
        _features(
          const UserLocation(
            position: Geographic(lon: 179.99, lat: -16),
            accuracy: 5000,
          ),
        ).first,
      );
      // Unwrapped past 180 rather than jumping to -180, which the map wraps.
      expect(ring.map((vertex) => vertex.lon).reduce(max), greaterThan(180));
      for (final vertex in ring) {
        expect((vertex.lon - center.lon).abs(), lessThan(0.1));
        expect(_distance(center, vertex), closeTo(5000, 0.1));
      }
      // And the same from the west.
      final west = _ring(
        _features(
          const UserLocation(
            position: Geographic(lon: -179.99, lat: -16),
            accuracy: 5000,
          ),
        ).first,
      );
      expect(west.map((vertex) => vertex.lon).reduce(min), lessThan(-180));
      for (final vertex in west) {
        expect((vertex.lon + 179.99).abs(), lessThan(0.1));
      }
    });

    test('clamps near the poles to what Web Mercator shows', () {
      for (final lat in [89.99, -89.99, 85.05]) {
        final features = _features(
          UserLocation(
            position: Geographic(lon: 0, lat: lat),
            accuracy: 50000,
            heading: 0,
          ),
        );
        final dot = (features.last['geometry']! as Map)['coordinates'] as List;
        expect((dot[1] as num).abs(), lessThanOrEqualTo(maxLatitude));
        for (final feature in features.where(
          (feature) => _kind(feature) == 'accuracy',
        )) {
          for (final vertex in _ring(feature)) {
            expect(vertex.lat.abs(), lessThanOrEqualTo(maxLatitude));
            expect(vertex.lon.isFinite, isTrue);
          }
        }
      }
    });

    test('turns the cone by the heading, from 0 to 360', () {
      for (final (heading, expected) in [
        (0.0, 0),
        (90.25, 90.25),
        (365.0, 5),
        (-10.0, 350),
        (720.0, 0),
      ]) {
        final cone = _features(
          UserLocation(
            position: const Geographic(lon: 11, lat: 47),
            heading: heading,
          ),
        ).singleWhere((feature) => _kind(feature) == 'heading');
        expect((cone['properties']! as Map)['h'], expected);
        expect((cone['geometry']! as Map)['type'], 'Point');
      }
    });
  });

  group('headingDifference', () {
    test('measures across north', () {
      expect(headingDifference(359, 1), 2);
      expect(headingDifference(1, 359), 2);
      expect(headingDifference(10, 190), 180);
      expect(headingDifference(-90, 270), 0);
      expect(headingDifference(720.5, 0), 0.5);
    });
  });
}
