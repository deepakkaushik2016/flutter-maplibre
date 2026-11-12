import 'package:maplibre/maplibre.dart';

/// How rough the ground of a [GalleryPlace] is.
enum TerrainClass { alpine, hilly, flat }

/// A landscape of the style gallery, with the camera of the design mockup.
class GalleryPlace {
  const GalleryPlace({
    required this.name,
    required this.center,
    required this.zoom,
    required this.pitch,
    required this.bearing,
    required this.terrainClass,
    required this.inUs,
    this.variant,
  });

  final String name;
  final Geographic center;
  final double zoom;
  final double pitch;
  final double bearing;
  final TerrainClass terrainClass;
  final bool inUs;

  /// What sets this shot apart from the place's mockup camera, such as `p70`.
  final String? variant;

  /// A name for file names, such as `mount-rainier` or `mount-rainier-p70`.
  String get slug {
    final base = name.toLowerCase().replaceAll(' ', '-');
    return variant == null ? base : '$base-$variant';
  }

  /// The same place and camera, tilted to [pitch] degrees.
  GalleryPlace atPitch(double pitch) => GalleryPlace(
    name: name,
    center: center,
    zoom: zoom,
    pitch: pitch,
    bearing: bearing,
    terrainClass: terrainClass,
    inUs: inUs,
    variant: 'p${pitch.round()}',
  );

  CameraUpdate get camera => CameraUpdate.position(
    center: center,
    zoom: zoom,
    pitch: pitch,
    bearing: bearing,
  );
}

/// The mockup cameras, at most 60° of pitch, the app's old maximum. In 3D the
/// app now tilts up to 75°.
const galleryPlaces = <GalleryPlace>[
  GalleryPlace(
    name: 'Yosemite',
    center: Geographic(lon: -119.548, lat: 37.737),
    zoom: 13.3,
    pitch: 60,
    bearing: 62,
    terrainClass: TerrainClass.alpine,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Big Sur',
    center: Geographic(lon: -121.676, lat: 36.150),
    zoom: 13.6,
    pitch: 60,
    bearing: 120,
    terrainClass: TerrainClass.hilly,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Arches',
    center: Geographic(lon: -109.505, lat: 38.740),
    zoom: 14.2,
    pitch: 60,
    bearing: 40,
    terrainClass: TerrainClass.hilly,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Everglades',
    center: Geographic(lon: -80.610, lat: 25.390),
    zoom: 14.5,
    pitch: 55,
    bearing: 0,
    terrainClass: TerrainClass.flat,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Acadia',
    center: Geographic(lon: -68.255, lat: 44.325),
    zoom: 13.6,
    pitch: 60,
    bearing: 330,
    terrainClass: TerrainClass.hilly,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Mount Rainier',
    center: Geographic(lon: -121.735, lat: 46.800),
    zoom: 13,
    pitch: 60,
    bearing: 10,
    terrainClass: TerrainClass.alpine,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Central Park',
    center: Geographic(lon: -73.968, lat: 40.778),
    zoom: 14.6,
    pitch: 55,
    bearing: 20,
    terrainClass: TerrainClass.flat,
    inUs: true,
  ),
  GalleryPlace(
    name: 'Zermatt',
    center: Geographic(lon: 7.70, lat: 46),
    zoom: 12.6,
    pitch: 60,
    bearing: 250,
    terrainClass: TerrainClass.alpine,
    inUs: false,
  ),
];

/// The pitch of the extra True Earth shots. On a phone the sky shows from about
/// 69°, and the fog fades in from 60° to 70°, so neither shows at 60°.
const galleryHighPitch = 70.0;

/// The True Earth shots: every place at its mockup camera, then every place
/// again at [galleryHighPitch].
final galleryTrueEarthPlaces = <GalleryPlace>[
  ...galleryPlaces,
  for (final place in galleryPlaces) place.atPitch(galleryHighPitch),
];
