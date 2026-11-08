import 'package:maplibre/maplibre.dart';

/// A static map that renders still images offscreen. Not on web.
abstract final class StillImageMap {
  /// Opens a map of [size] logical pixels that shows [styleUrl] around
  /// [center] at [zoom].
  static Future<StillImageMap> open({
    required String styleUrl,
    required Geographic center,
    required double zoom,
    int size = 64,
  }) => throw UnsupportedError('Still images are not supported on web.');

  /// Renders a still image, and completes once it is done.
  Future<void> render();

  /// The premultiplied RGBA color at [x], [y] of the last image.
  Future<List<int>> pixel(int x, int y);

  /// Releases the map.
  Future<void> close();
}
