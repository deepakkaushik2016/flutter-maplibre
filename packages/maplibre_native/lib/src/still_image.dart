import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre_native/src/database.dart';
import 'package:maplibre_native/src/extensions.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart' as mln;
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// The [StillImageRenderer] of maplibre_native: each image is a static map of
/// its own with an offscreen session, on one runtime of the database that
/// every map shares.
final class StillImageRendererNative implements StillImageRenderer {
  StillImageRendererNative._(this._runtime);

  /// Creates a renderer on the shared database.
  static Future<StillImageRendererNative> create() async =>
      StillImageRendererNative._(await createRuntime());

  final mln.RuntimeHandle _runtime;

  /// The requests that run now, which [dispose] ends.
  final _requests = <_Request>{};

  var _disposed = false;

  /// How many frames the last finished image rendered.
  @visibleForTesting
  int debugLastFrameCount = 0;

  @override
  Future<Uint8List> render({
    required MapStyle style,
    required ui.Size size,
    required CameraUpdate camera,
    double pixelRatio = 1,
    Terrain? terrain,
    double? centerAltitude,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final width = size.width.ceil();
    final height = size.height.ceil();
    if (width < 1 || height < 1 || width > 16384 || height > 16384) {
      throw ArgumentError.value(size, 'size', 'must be 1 to 16384 pixels');
    }
    if (_disposed) throw const StillImageException(_disposedMessage);
    final request = _Request();
    _requests.add(request);
    final timer = Timer(
      timeout,
      () => request.cancel(
        TimeoutException('The still image took too long', timeout),
      ),
    );
    try {
      // A cancelled request ends at once, and its native work ends in
      // [_Request.close]. Future.any ignores the error of the one that loses.
      return await Future.any([
        _draw(
          request,
          style: style,
          extent: mln.LogicalExtent(
            width: width,
            height: height,
            scaleFactor: pixelRatio,
          ),
          camera: camera,
          terrain: terrain,
          centerAltitude: centerAltitude,
        ),
        request.cancelled,
      ]);
    } on mln.MaplibreException catch (error, stack) {
      Error.throwWithStackTrace(StillImageException('$error'), stack);
    } finally {
      timer.cancel();
      await request.close();
      _requests.remove(request);
      if (_disposed && _requests.isEmpty) unawaited(_runtime.release());
    }
  }

  Future<Uint8List> _draw(
    _Request request, {
    required MapStyle style,
    required mln.LogicalExtent extent,
    required CameraUpdate camera,
    required Terrain? terrain,
    required double? centerAltitude,
  }) async {
    final map = request.map = _runtime.createMap(
      mln.MapOptions(initialExtent: extent, mapMode: mln.MapMode.static),
    );
    await map.ready;
    request.check();
    // A static map doesn't follow the ground by default: over high ground
    // its camera would be under the terrain and draw only the background.
    // On exactly when the caller gives no center height, with a terrain or
    // not: without one there is no ground to reach, so it does nothing.
    await map.setTerrainOptions(
      mln.MapTerrainOptions(centerClampedToGround: centerAltitude == null),
    );
    request.check();
    await _setStyle(map, style);
    request.check();
    if (terrain != null) await _setTerrain(map, terrain);
    request.check();
    final options = await camera.toMln(map);
    request.check();
    await map.updateCamera(
      mln.CameraUpdate(
        camera: centerAltitude == null
            ? options
            : options.copyWith(centerAltitude: centerAltitude),
      ),
    );
    request.check();
    final session = request.session = map.attachOffscreen(
      mln.OffscreenDescriptor(
        logicalSize: mln.LogicalSize(
          width: extent.width,
          height: extent.height,
        ),
      ),
      // The library renders on its own thread.
      const mln.RenderSessionAttachOptions(
        driver: mln.RenderDriverKind.coreWorker,
      ),
    );
    await session.ready;
    request.check();
    await map.requestStillImage();
    request.check();
    final frames = session.drainFrameResults().where(
      (result) => result.disposition == mln.RenderResult.rendered,
    );
    debugLastFrameCount = frames.length;
    final image = await session.readTexture();
    request.check();
    return _encodePng(image);
  }

  Future<void> _setStyle(mln.MapHandle map, MapStyle style) async {
    switch (style) {
      case MapStyleJson(:final json):
        final Object? decoded;
        try {
          decoded = jsonDecode(json);
        } on FormatException catch (error) {
          throw StillImageException('The style is not JSON: ${error.message}');
        }
        await map.setStyleJson(decoded);
      case MapStyleUrl(:final url):
        await map.setStyleUrl(url);
      case MapStyleFile(:final path):
        await map.setStyleUrl(Uri.file(path).toString());
      case MapStyleAsset(:final asset):
        await map.setStyleJson(jsonDecode(await rootBundle.loadString(asset)));
    }
  }

  /// Sets [terrain] on the loaded style. The C API takes a terrain on a
  /// source the style lacks, which would draw flat ground without an error.
  Future<void> _setTerrain(mln.MapHandle map, Terrain terrain) async {
    final style = await map.getLoadedStyleJson();
    final type = switch (style) {
      {'sources': final Map<String, Object?> sources} =>
        switch (sources[terrain.sourceId]) {
          {'type': final String type} => type,
          _ => null,
        },
      _ => null,
    };
    if (type != 'raster-dem') {
      throw StillImageException(
        'The source "${terrain.sourceId}" of the terrain is '
        '${type == null ? 'not in the style' : 'a "$type" source'}, not '
        '"raster-dem".',
      );
    }
    await map.setStyleTerrainJson(terrain.toJson());
  }

  /// Encodes premultiplied RGBA pixels on Flutter's threads, off the UI
  /// isolate.
  static Future<Uint8List> _encodePng(mln.TextureReadbackResult result) async {
    final info = result.info;
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      result.data,
      info.width,
      info.height,
      ui.PixelFormat.rgba8888,
      decoded.complete,
      rowBytes: info.stride,
    );
    final image = await decoded.future;
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw const StillImageException('The image could not be encoded');
      }
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_requests.isEmpty) {
      unawaited(_runtime.release());
      return;
    }
    for (final request in _requests) {
      request.cancel(const StillImageException(_disposedMessage));
    }
  }

  static const _disposedMessage = 'The StillImageRenderer was disposed';
}

/// One image in the making, and what ends it early.
final class _Request {
  final _cancelled = Completer<Never>();

  mln.MapHandle? map;
  mln.RenderSessionHandle? session;

  /// Fails with the reason the request was cancelled.
  Future<Never> get cancelled => _cancelled.future;

  Exception? _reason;

  /// Ends the request with [reason], unless it already ended.
  void cancel(Exception reason) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    _cancelled.completeError(reason);
  }

  /// Stops [StillImageRendererNative._draw] once the request was cancelled.
  void check() {
    if (_reason case final reason?) throw reason;
  }

  /// Releases the session and then the map, which also ends a still image
  /// that is still running.
  Future<void> close() async {
    // Nobody may wait for it once the request ended normally.
    unawaited(_cancelled.future.then<void>((_) {}, onError: (Object _) {}));
    final session = this.session;
    final map = this.map;
    this.session = null;
    this.map = null;
    try {
      await session?.release();
    } on Object {
      // A session that failed to attach has nothing to release.
    }
    try {
      await map?.release();
    } on Object {
      // A map that failed to start has nothing to release.
    }
  }
}
