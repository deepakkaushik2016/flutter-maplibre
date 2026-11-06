import 'dart:typed_data';

/// Clears the browser's resource timing entries.
void clearResourceTimings() {}

/// How many requests the browser made for [url].
int resourceRequests(String url) => 0;

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

/// The pixels of a frame that maplibre-gl-js drew: `rgba` rows of `width`
/// pixels, `scale` pixels per logical pixel of the map.
typedef MapFrame = ({int width, int height, Uint8List rgba, double scale});

/// Reads the next frame that the maplibre-gl-js map on the page draws.
/// Before it has seen the map render, [render] makes it.
Future<MapFrame> readMapFrame(void Function() render) =>
    throw UnsupportedError('Only maplibre-gl-js draws into a canvas.');
