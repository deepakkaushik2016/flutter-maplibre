import 'dart:typed_data';

/// Clears the browser's resource timing entries.
void clearResourceTimings() {}

/// How many requests the browser made for [url].
int resourceRequests(String url) => 0;

/// The URLs of the requests the browser made whose URL starts with
/// [prefix].
List<String> resourcesUnder(String prefix) => const [];

/// Answers maplibre-gl-js requests for `<scheme>://…` URLs with the JSON
/// that [respond] completes with.
void addJsonProtocol(
  String scheme,
  Future<String> Function(String url) respond,
) => throw UnsupportedError('Only maplibre-gl-js has custom protocols.');

/// Fails maplibre-gl-js requests for `<scheme>://…` URLs once [until]
/// completes, with the error that gl-js gives a request that a server
/// answered with 404 Not Found: an `AJAXError` that names the URL.
void addNotFoundProtocol(
  String scheme,
  Future<void> Function(String url) until,
) => throw UnsupportedError('Only maplibre-gl-js has custom protocols.');

/// Answers maplibre-gl-js requests for `<scheme>://…` URLs with what
/// [respond] completes with: JSON text for a JSON request, bytes for a tile
/// or an image, an HTTP status for the error of that status, or null for the
/// error of a 404 Not Found.
void addFixtureProtocol(
  String scheme,
  Future<Object?> Function(String url) respond,
) => throw UnsupportedError('Only maplibre-gl-js has custom protocols.');

/// How many elements of the page match the CSS [selector].
int countElements(String selector) =>
    throw UnsupportedError('Only the browser has a page.');

/// The pixels of a frame that maplibre-gl-js drew: `rgba` rows of `width`
/// pixels, `scale` pixels per logical pixel of the map.
typedef MapFrame = ({int width, int height, Uint8List rgba, double scale});

/// Reads the next frame that the maplibre-gl-js map on the page draws.
/// Before it has seen the map render, [render] makes it.
Future<MapFrame> readMapFrame(void Function() render) =>
    throw UnsupportedError('Only maplibre-gl-js draws into a canvas.');

/// Hides the evaluated properties (`paint`) of every layer that
/// maplibre-gl-js's `Map.getLayer` returns, until the returned function
/// restores them.
void Function() hideLayerPaint() =>
    throw UnsupportedError('Only maplibre-gl-js has these internals.');

/// Where the camera of a maplibre-gl-js map is: its eye in degrees and
/// meters above sea level, the elevation of its center, and whether that
/// center is clamped to the ground.
typedef MapEye = ({
  double lon,
  double lat,
  double altitude,
  double centerElevation,
  bool centerClampedToGround,
});

/// The camera of the maplibre-gl-js map on the page that drew last, or null
/// before a map drew since the first call.
MapEye? lastMapEye() =>
    throw UnsupportedError('Only maplibre-gl-js has these internals.');
