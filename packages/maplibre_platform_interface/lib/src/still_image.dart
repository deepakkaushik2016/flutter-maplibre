import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Renders images of a map without showing one, for example to share a map.
///
/// ```dart
/// final renderer = await StillImageRenderer.createInstance();
/// final png = await renderer.render(
///   style: const MapStyle.url('https://example.com/style.json'),
///   size: const Size(512, 512),
///   camera: const CameraUpdate.position(
///     center: Geographic(lon: 11.4, lat: 47.3),
///     zoom: 13,
///     pitch: 50,
///   ),
///   terrain: const Terrain(sourceId: 'dem'),
/// );
/// renderer.dispose();
/// ```
///
/// Images use the same cache and offline regions as maps. While
/// [MapLibreNetwork.status] is [NetworkStatus.offline], an image finishes
/// with the tiles it has, and fails if a style, sprite or glyph range it
/// needs is missing.
///
/// On web, the network status does nothing, and images are drawn one at a
/// time: a request waits for the ones before it, within its timeout.
///
/// {@category Offline}
abstract interface class StillImageRenderer {
  /// Creates a new [StillImageRenderer].
  ///
  /// You'll have to call [dispose] to free resources once no longer needed.
  static Future<StillImageRenderer> createInstance() async =>
      MapLibrePlatform.instance.createStillImageRenderer();

  /// Whether still images are supported on the current platform.
  static bool get isSupported =>
      MapLibrePlatform.instance.stillImageRendererIsSupported;

  /// Renders [style] at [camera] and returns a PNG of [size] logical pixels
  /// times [pixelRatio]. Requests may overlap.
  ///
  /// [camera] may pitch up to 85 degrees, as a map whose
  /// [MapOptions.maxPitch] is 85.
  ///
  /// [terrain]'s source must be in [style]. Unless you give [centerAltitude],
  /// in meters above sea level, the camera's center moves onto the ground, as
  /// on a map with [MapOptions.centerClampedToGround], whether or not there
  /// is a [terrain]: with one, which takes at least one more render; without
  /// one, the ground is flat and it does nothing. A given [centerAltitude]
  /// turns this off and places the center there, with a [terrain] or not.
  ///
  /// Throws a [StillImageException] when the image can't be drawn, a
  /// [TimeoutException] when it isn't done within [timeout], and an
  /// [ArgumentError] for a [size] under one pixel or over 16384.
  Future<Uint8List> render({
    required MapStyle style,
    required Size size,
    required CameraUpdate camera,
    double pixelRatio = 1,
    Terrain? terrain,
    double? centerAltitude,
    Duration timeout = const Duration(seconds: 30),
  });

  /// Call to free resources when the [StillImageRenderer] is no longer
  /// needed. Requests that are still running fail with a
  /// [StillImageException].
  void dispose();
}

/// A still image could not be drawn, because a resource it needs failed to
/// load or the [StillImageRenderer] was disposed.
///
/// {@category Offline}
final class StillImageException implements Exception {
  /// Creates an exception that says why the image failed.
  const StillImageException(this.message);

  /// Why the image failed.
  final String message;

  @override
  String toString() => 'StillImageException: $message';
}
