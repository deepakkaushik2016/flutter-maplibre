import 'package:maplibre/maplibre.dart';
// Still images and the shared runtime are below the public API: the plugin
// shows continuous maps only.
import 'package:maplibre_native/src/database.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart' as mln;

/// A static map that renders still images offscreen, on a runtime of the
/// database that every map and the offline manager share.
final class StillImageMap {
  StillImageMap._(this._runtime, this._map, this._session);

  /// Opens a map of [size] logical pixels that shows [styleUrl] around
  /// [center] at [zoom].
  static Future<StillImageMap> open({
    required String styleUrl,
    required Geographic center,
    required double zoom,
    int size = 64,
  }) async {
    final runtime = await createRuntime();
    final map = runtime.createMap(
      mln.MapOptions(
        initialExtent: mln.LogicalExtent(
          width: size,
          height: size,
          scaleFactor: 1,
        ),
        mapMode: mln.MapMode.static,
      ),
    );
    await map.ready;
    map.discarding
      ..setStyleUrl(styleUrl)
      ..updateCamera(
        mln.CameraUpdate(
          camera: mln.CameraOptions(
            center: mln.LatLng(latitude: center.lat, longitude: center.lon),
            zoom: zoom,
          ),
        ),
      );
    final session = map.attachOffscreen(
      mln.OffscreenDescriptor(
        logicalSize: mln.LogicalSize(width: size, height: size),
      ),
      // The library renders on its own thread.
      const mln.RenderSessionAttachOptions(
        driver: mln.RenderDriverKind.coreWorker,
      ),
    );
    await session.ready;
    return StillImageMap._(runtime, map, session);
  }

  final mln.RuntimeHandle _runtime;
  final mln.MapHandle _map;
  final mln.RenderSessionHandle _session;

  /// Renders a still image, and completes once it is done.
  Future<void> render() => _map.requestStillImage();

  /// The premultiplied RGBA color at [x], [y] of the last image.
  Future<List<int>> pixel(int x, int y) async {
    final image = await _session.readTexture();
    final offset = y * image.info.stride + x * 4;
    return image.data.sublist(offset, offset + 4);
  }

  /// Releases the map.
  Future<void> close() async {
    await _session.release();
    await _map.release();
    await _runtime.release();
  }
}
