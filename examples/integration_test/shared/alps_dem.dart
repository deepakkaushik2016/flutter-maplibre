/// The synthetic DEM of the 3D terrain tests: an east-west ridge through
/// the "Alps" camera position, whose heights a formula gives, so tests can
/// assert the ground that the map draws.
///
/// The ridge's crest runs along latitude [alpsLat] and is 2300 m high at
/// [alpsLng], every 12 km to the east and west of it, and 2070 m between.
/// The ground falls off north and south of the crest (a Gaussian of 4 km)
/// to a valley floor of 575 m, which it reaches about 10 km away.
///
/// `tool/alps_dem.dart` draws the vendored Terrarium tiles of this DEM:
/// the zoom [alpsDemZoom] tiles [alpsDemTiles], in whole meters, as
/// MapLibre reads DEM heights.
library;

import 'dart:math';

/// The latitude of the camera of the terrain tests, on the crest.
const alpsLat = 47.265;

/// The longitude of the camera of the terrain tests, on the highest point of
/// the crest.
const alpsLng = 11.404;

/// The height of the valley floor, in meters.
const alpsValleyFloor = 575.0;

/// The height of the crest at [alpsLat], [alpsLng], in meters.
const alpsSummit = 2300.0;

/// The zoom of the vendored DEM tiles, which is the DEM source's minimum and
/// maximum zoom.
const alpsDemZoom = 10;

/// The x and y ranges of the vendored DEM tiles at [alpsDemZoom], first and
/// last included. They cover about 20 km south to 50 km north of the crest,
/// and 38 km west to 41 km east of [alpsLng].
const ({(int, int) x, (int, int) y}) alpsDemTiles = (
  x: (543, 545),
  y: (357, 359),
);

const double _kmPerDegree = 6371.0088 * pi / 180;

/// The height of the synthetic ground at [lat], [lng] in meters, without
/// the terrain's exaggeration.
double alpsHeight(double lat, double lng) {
  final northKm = (lat - alpsLat) * _kmPerDegree;
  final eastKm = (lng - alpsLng) * _kmPerDegree * cos(alpsLat * pi / 180);
  final ridge = exp(-pow(northKm / 4, 2));
  final crest = 0.9 + 0.1 * cos(2 * pi * eastKm / 12);
  return alpsValleyFloor + (alpsSummit - alpsValleyFloor) * ridge * crest;
}

/// The latitude and longitude of the point [px], [py] of the tile [x], [y]
/// at [zoom], where 0 is the tile's west or north edge and 1 its east or
/// south edge.
({double lat, double lng}) tilePointLatLng(
  int zoom,
  int x,
  int y,
  double px,
  double py,
) {
  final tiles = 1 << zoom;
  final lng = (x + px) / tiles * 360 - 180;
  final mercatorY = pi * (1 - 2 * (y + py) / tiles);
  final lat = atan((exp(mercatorY) - exp(-mercatorY)) / 2) * 180 / pi;
  return (lat: lat, lng: lng);
}
