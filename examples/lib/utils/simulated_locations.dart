import 'dart:async';
import 'dart:math';

import 'package:maplibre/maplibre.dart';

/// User locations of a walk around [center], for devices without a location
/// source: a loop [radius] meters wide, walked at about 1.4 m/s, with a
/// heading that looks ahead along it and wavers as a compass does, and an
/// accuracy that breathes between 5 and 25 meters.
///
/// It reports [rate] locations a second, as a compass reports its heading.
Stream<UserLocation> simulatedLocations({
  required Geographic center,
  double radius = 150,
  int rate = 10,
}) {
  const metersPerDegree = 111320.0;
  final lap = 2 * pi * radius / 1.4;
  return Stream.periodic(Duration(milliseconds: 1000 ~/ rate), (tick) {
    final seconds = tick / rate;
    final angle = 2 * pi * seconds / lap;
    final position = Geographic(
      lon:
          center.lon +
          radius * sin(angle) / (metersPerDegree * cos(center.lat * pi / 180)),
      lat: center.lat + radius * cos(angle) / metersPerDegree,
    );
    // Clockwise, so the walk heads 90° right of the way out from the center.
    final heading = (angle * 180 / pi + 90 + 12 * sin(seconds * 1.7)) % 360;
    return UserLocation(
      position: position,
      accuracy: 15 + 10 * sin(seconds / 4),
      heading: heading,
      timestamp: DateTime.now(),
    );
  });
}
