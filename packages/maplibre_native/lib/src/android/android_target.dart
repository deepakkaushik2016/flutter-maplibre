import 'package:maplibre_native/src/android/android_plugin.dart';
import 'package:maplibre_native/src/android/surface_tracker.dart';
import 'package:maplibre_native/src/frame_target.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart';

/// Creates the target of an Android map, which presents to the Surface of a
/// Flutter SurfaceProducer texture on its session's core worker, through the
/// graphics context that the C library creates: an EGL context of its own
/// (OpenGL ES, the default), or a Vulkan device and swapchain.
FrameTarget createAndroidTarget(LogicalExtent extent) {
  AndroidPlugin.initialize();
  return _SurfaceTarget(extent);
}

final class _SurfaceTarget extends FrameTarget {
  _SurfaceTarget(LogicalExtent extent) {
    final (width, height) = physicalSize(extent);
    _surface = SurfaceTracker(
      setSurface: (host) => _setSurface(_session, host.extent),
      releaseTarget: () => _session.releaseTarget(),
    );
    _texture = AndroidPlugin.createSurfaceTexture(
      width,
      height,
      onSurfaceAvailable: _surface.back,
      onSurfaceCleanup: _surface.lost,
    );
  }

  late final SurfaceTexture _texture;

  late RenderSessionHandle _session;

  /// Whether the Surface accepts frames. Flutter takes it away while the app
  /// is in the background.
  late final SurfaceTracker _surface;

  @override
  set host(FrameTargetHost? host) {
    super.host = host;
    _surface.host = host;
  }

  @override
  int get textureId => _texture.textureId;

  @override
  bool get acceptsFrames => _surface.available;

  @override
  RenderSessionHandle attach(
    MapHandle map,
    LogicalExtent extent,
    Wake frameWake,
  ) {
    _session = AndroidPlugin.withSurface<RenderSessionHandle>(
      textureId,
      (jniEnv, surface) => map.attachAndroidSurface(
        AndroidSurfaceDescriptor(
          logicalSize: logicalSize(extent),
          jniEnv: jniEnv,
          surface: surface,
        ),
        RenderSessionAttachOptions(
          driver: RenderDriverKind.coreWorker,
          frameWake: frameWake,
        ),
      ),
    );
    _surface.attached();
    return _session;
  }

  /// Sizes the SurfaceProducer's buffers and the session. Flutter may hand
  /// out a new Surface for the new size, which the session then moves to.
  @override
  Future<void> resize(RenderSessionHandle session, LogicalExtent extent) async {
    final (width, height) = physicalSize(extent);
    if (AndroidPlugin.resizeSurfaceTexture(textureId, width, height)) {
      await _setSurface(session, extent);
    } else {
      await session.resize(logicalSize(extent));
    }
  }

  /// The session presented the frame to the Surface, and Flutter takes the
  /// newest image there.
  @override
  Future<bool> present(
    RenderSessionHandle session,
    RenderFrameResult frame,
  ) async => true;

  /// Moves [session] to the texture's current Surface.
  Future<void> _setSurface(RenderSessionHandle session, LogicalExtent extent) =>
      AndroidPlugin.withSurface(
        textureId,
        (jniEnv, surface) => session.setAndroidSurfaceTarget(
          AndroidSurfaceReplacement(
            logicalSize: logicalSize(extent),
            jniEnv: jniEnv,
            surface: surface,
          ),
        ),
      );

  /// The session closed, so nothing presents to the surface anymore.
  @override
  void dispose() => AndroidPlugin.disposeTexture(_texture);
}
