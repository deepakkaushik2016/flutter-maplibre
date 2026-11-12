import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_web/src/extensions.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;
import 'package:maplibre_web/src/map_state.dart';
import 'package:maplibre_web/src/sparse_dem.dart';
import 'package:web/web.dart';

/// The [StillImageRenderer] of maplibre_web: each image is a map of its own
/// in a hidden container, read from its canvas once it is idle.
///
/// Images are drawn one at a time, so that the page holds at most one more
/// WebGL context than its maps: browsers drop the oldest context past a
/// limit of their own.
final class StillImageRendererWeb implements StillImageRenderer {
  /// The class of the container of an image's map, which the integration
  /// tests count.
  static const _containerClass = 'maplibre-still-image';

  /// The requests that have not ended, which [dispose] ends.
  final _requests = <_Request>{};

  /// Completes once the last request that was made has ended and removed
  /// its map.
  Future<void> _last = Future.value();

  var _disposed = false;

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
    final previous = _last;
    final ended = Completer<void>();
    _last = ended.future;
    Timer? timer;
    try {
      // dispose ends a request that waits for its turn.
      await Future.any([previous, request.cancelled]);
      // As on native, the timeout counts the image's own work only.
      timer = Timer(
        timeout,
        () => request.cancel(
          TimeoutException('The still image took too long', timeout),
        ),
      );
      return await Future.any([
        _draw(
          request,
          style: style,
          width: width,
          height: height,
          pixelRatio: pixelRatio,
          camera: camera,
          terrain: terrain,
          centerAltitude: centerAltitude,
        ),
        request.cancelled,
      ]);
    } finally {
      timer?.cancel();
      _requests.remove(request);
      try {
        request.close();
      } finally {
        // The next request starts once this one and every one before it
        // removed their maps, also when this one ended while it waited or
        // its map failed to go.
        unawaited(previous.then((_) => ended.complete()));
      }
    }
  }

  /// The steepest pitch of an image, as of a map's [MapOptions.maxPitch].
  static const _maxPitch = 85.0;

  Future<Uint8List> _draw(
    _Request request, {
    required MapStyle style,
    required int width,
    required int height,
    required double pixelRatio,
    required CameraUpdate camera,
    required Terrain? terrain,
    required double? centerAltitude,
  }) async {
    final JSAny jsStyle;
    try {
      jsStyle = style.toJs();
    } on FormatException catch (error) {
      throw StillImageException('The style is not JSON: ${error.message}');
    }
    final container = request.container = HTMLDivElement()
      ..className = _containerClass
      ..style.position = 'fixed'
      ..style.left = '0'
      ..style.top = '0'
      ..style.width = '${width}px'
      ..style.height = '${height}px'
      ..style.visibility = 'hidden'
      ..style.pointerEvents = 'none';
    document.body!.appendChild(container);

    final tiles = RasterDemTiles();
    final interop.JsMap map;
    try {
      map = request.map = interop.JsMap(
        interop.MapOptions(
          container: container,
          style: jsStyle,
          attributionControl: false,
          interactive: false,
          // MapLibreNetwork first, then the sparse-dem routing of raster-dem
          // tiles, as on a map.
          transformRequest:
              ((String url, String? resourceType) => tiles.transformRequest(
                url,
                resourceType,
                MapLibreMapStateWeb.transformNetworkRequest,
              )).toJS,
          // As on native, the center moves onto the ground unless the caller
          // gives its height.
          centerClampedToGround: centerAltitude == null,
          canvasContextAttributes: {'preserveDrawingBuffer': true}.jsify(),
          pixelRatio: pixelRatio,
          maxCanvasSize: [16384, 16384].jsify(),
          maxPitch: _maxPitch,
          // A fade would only add frames before the map is idle.
          fadeDuration: 0,
          trackResize: false,
        ),
      );
    } on Object catch (error) {
      // gl-js throws when the browser gives it no WebGL context.
      throw StillImageException('The map could not be created: $error');
    }

    final idle = Completer<void>();
    void fail(Object error) {
      if (!idle.isCompleted) idle.completeError(error);
    }

    // An empty raster-dem tile draws no frame of its own, so the map would
    // not fire `idle` after one (see `emptyTileListeners`).
    void onEmptyTile() => map.triggerRepaint();
    request.onEmptyTile = onEmptyTile;
    emptyTileListeners.add(onEmptyTile);
    map
      ..on(
        interop.MapEventType.error,
        (interop.MapErrorEvent event) {
          // As on native, any resource that fails fails the image: the
          // style, a source's TileJSON, a tile or the sprite. Neither
          // reports a 404 tile, which both take as missing. The only
          // validation messages gl-js reports are errors of a style it
          // then doesn't load; it only logs warnings.
          final error = event.error as interop.JsError?;
          fail(StillImageException(error?.message ?? 'Unknown error'));
        }.toJS,
      )
      ..on(
        interop.MapEventType.data,
        (interop.MapDataEvent event) {
          // The source's tile URLs, before gl-js asks for a tile.
          if (event.sourceDataType == 'metadata') {
            if (event.sourceId case final String id) {
              tiles.setJsSource(id, map.getSource(id));
            }
          }
        }.toJS,
      )
      ..once(
        interop.MapEventType.load,
        (JSAny _) {
          try {
            if (terrain != null) _setTerrain(map, terrain);
          } on Object catch (error) {
            return fail(error);
          }
          map.once(
            interop.MapEventType.idle,
            (JSAny _) {
              if (!idle.isCompleted) idle.complete();
            }.toJS,
          );
        }.toJS,
      );

    // Before the style loads, so the first tiles are those of the image.
    final target = _target(map, camera);
    if (centerAltitude != null) target['elevation'] = centerAltitude.toJS;
    map.jumpTo(target as interop.JumpToOptions);

    await idle.future;
    request.check();
    final canvas = map.getCanvas();
    final expectedWidth = (width * pixelRatio).floor();
    final expectedHeight = (height * pixelRatio).floor();
    if (canvas.width < expectedWidth || canvas.height < expectedHeight) {
      throw StillImageException(
        'The browser can draw at most ${canvas.width} x ${canvas.height} '
        'pixels, not $expectedWidth x $expectedHeight',
      );
    }
    final blob = Completer<Blob?>();
    // A tear-off of complete takes a FutureOr, which JS can't call.
    void encoded(Blob? png) => blob.complete(png);
    _onBackground(map, canvas).toBlob(encoded.toJS, 'image/png');
    final png = await blob.future;
    if (png == null) {
      throw const StillImageException('The image could not be encoded');
    }
    final bytes = await png.arrayBuffer().toDart;
    request.check();
    return bytes.toDart.asUint8List();
  }

  /// [canvas] over the color that native clears an image with: the bottom
  /// layer's when it is a background of a solid color (`getSolidBackground`
  /// of the native renderer), or none. gl-js always clears the canvas
  /// transparent and, over a terrain, draws the background onto the ground
  /// only, so where native shows that color, above the ground of a steep
  /// camera without a sky or under the ground, gl-js leaves the canvas clear.
  static HTMLCanvasElement _onBackground(
    interop.JsMap map,
    HTMLCanvasElement canvas,
  ) {
    final background = _solidBackground(map);
    if (background == null) return canvas;
    final (:color, :opacity) = background;
    final composite = HTMLCanvasElement()
      ..width = canvas.width
      ..height = canvas.height;
    composite.getContext('2d')! as CanvasRenderingContext2D
      ..globalAlpha = opacity
      ..fillStyle = color.toJS
      ..fillRect(0, 0, canvas.width, canvas.height)
      ..globalAlpha = 1
      ..drawImage(canvas, 0, 0);
    return composite;
  }

  /// The CSS color and opacity of the bottom layer of [map]'s style when it
  /// is a visible background without a pattern, from gl-js's evaluated
  /// properties of the layer.
  ///
  /// Those properties are internals of gl-js, not its API: if a release of
  /// gl-js reshapes them, the image is drawn without the color, as the
  /// transparent canvas, instead of failing with a JavaScript error.
  static ({String color, double opacity})? _solidBackground(interop.JsMap map) {
    try {
      return _evaluatedBackground(map);
    } catch (_) {
      // A JavaScript error is not an Exception, so every error is caught.
      return null;
    }
  }

  static ({String color, double opacity})? _evaluatedBackground(
    interop.JsMap map,
  ) {
    final order = map.getLayersOrder().toDart;
    if (order.isEmpty) return null;
    final layer = map.getLayer(order.first.toDart);
    if (layer == null ||
        layer.getProperty<JSString?>('type'.toJS)?.toDart != 'background' ||
        layer
            .callMethod<JSBoolean>('isHidden'.toJS, map.getZoom().toJS)
            .toDart) {
      return null;
    }
    final paint = layer.getProperty<JSObject>('paint'.toJS);
    T get<T extends JSAny?>(String name) =>
        paint.callMethod<T>('get'.toJS, name.toJS);
    final opacity = get<JSNumber>('background-opacity').toDartDouble;
    if (get<JSAny?>('background-pattern') != null || opacity <= 0) return null;
    // gl-js's Color writes itself as a CSS rgba() color.
    final color = get<JSObject>('background-color')
        .callMethod<JSString>('toString'.toJS)
        .toDart;
    return (color: color, opacity: opacity);
  }

  /// The camera options of [camera] on the new [map].
  static JSObject _target(interop.JsMap map, CameraUpdate camera) =>
      switch (camera) {
        CameraUpdatePosition() => camera.toJs(map),
        CameraUpdateFit() =>
          camera.toJs(map) ??
              (throw StillImageException(
                'The bounds ${camera.bounds} do not fit the image',
              )),
      };

  /// Sets [terrain] on the loaded style, whose source must be a raster-dem
  /// source of the style.
  static void _setTerrain(interop.JsMap map, Terrain terrain) {
    final type = map.getSource(terrain.sourceId)?.type;
    if (type != 'raster-dem') {
      throw StillImageException(
        'The source "${terrain.sourceId}" of the terrain is '
        '${type == null ? 'not in the style' : 'a "$type" source'}, not '
        '"raster-dem".',
      );
    }
    map.setTerrain(terrain.toJson().jsify());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _requests) {
      request.cancel(const StillImageException(_disposedMessage));
    }
  }

  static const _disposedMessage = 'The StillImageRenderer was disposed';
}

/// One image in the making, and what ends it early.
final class _Request {
  final _cancelled = Completer<Never>();

  HTMLDivElement? container;
  interop.JsMap? map;
  void Function()? onEmptyTile;

  /// Fails with the reason the request was cancelled.
  Future<Never> get cancelled => _cancelled.future;

  Exception? _reason;

  /// Ends the request with [reason], unless it already ended.
  void cancel(Exception reason) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    _cancelled.completeError(reason);
  }

  /// Stops [StillImageRendererWeb._draw] once the request was cancelled.
  void check() {
    if (_reason case final reason?) throw reason;
  }

  /// Removes the map, which releases its WebGL context, and its container.
  void close() {
    // Nobody may wait for it once the request ended normally.
    unawaited(_cancelled.future.then<void>((_) {}, onError: (Object _) {}));
    if (onEmptyTile case final listener?) emptyTileListeners.remove(listener);
    map?.remove();
    container?.remove();
    onEmptyTile = null;
    map = null;
    container = null;
  }
}
