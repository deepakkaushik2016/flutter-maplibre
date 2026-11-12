import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

JSObject get _performance =>
    globalContext.getProperty<JSObject>('performance'.toJS);

/// Clears the browser's resource timing entries.
void clearResourceTimings() =>
    _performance.callMethod<JSAny?>('clearResourceTimings'.toJS);

/// How many requests the browser made for [url].
int resourceRequests(String url) => _performance
    .callMethod<JSArray<JSAny?>>('getEntriesByName'.toJS, url.toJS)
    .length;

/// The URLs of the requests the browser made whose URL starts with
/// [prefix].
List<String> resourcesUnder(String prefix) => [
  for (final entry
      in _performance
          .callMethod<JSArray<JSObject>>(
            'getEntriesByType'.toJS,
            'resource'.toJS,
          )
          .toDart)
    if (entry.getProperty<JSString>('name'.toJS).toDart case final name
        when name.startsWith(prefix))
      name,
];

/// Answers maplibre-gl-js requests for `<scheme>://…` URLs with the JSON
/// that [respond] completes with.
void addJsonProtocol(
  String scheme,
  Future<String> Function(String url) respond,
) {
  final maplibre = globalContext.getProperty<JSObject>('maplibregl'.toJS);
  final json = globalContext.getProperty<JSObject>('JSON'.toJS);
  maplibre.callMethod<JSAny?>(
    'addProtocol'.toJS,
    scheme.toJS,
    ((JSObject request, JSAny? _) {
      final url = request.getProperty<JSString>('url'.toJS).toDart;
      return respond(url).then((text) {
        final response = JSObject()
          ..setProperty(
            'data'.toJS,
            json.callMethod<JSAny?>('parse'.toJS, text.toJS),
          );
        return response;
      }).toJS;
    }).toJS,
  );
}

/// Fails maplibre-gl-js requests for `<scheme>://…` URLs once [until]
/// completes, with the error that gl-js gives a request that a server
/// answered with 404 Not Found: an `AJAXError` that names the URL.
void addNotFoundProtocol(
  String scheme,
  Future<void> Function(String url) until,
) {
  final maplibre = globalContext.getProperty<JSObject>('maplibregl'.toJS);
  final ajaxError = maplibre.getProperty<JSFunction>('AJAXError'.toJS);
  final blob = globalContext.getProperty<JSFunction>('Blob'.toJS);
  final promise = globalContext.getProperty<JSFunction>('Promise'.toJS);
  maplibre.callMethod<JSAny?>(
    'addProtocol'.toJS,
    scheme.toJS,
    ((JSObject request, JSAny? _) {
      final url = request.getProperty<JSString>('url'.toJS).toDart;
      return promise.callAsConstructor<JSObject>(
        ((JSFunction resolve, JSFunction reject) {
          until(url).then((_) {
            final error = ajaxError.callAsConstructor<JSObject>(
              404.toJS,
              'Not Found'.toJS,
              url.toJS,
              blob.callAsConstructor<JSObject>(JSArray<JSAny?>()),
            );
            reject.callAsFunction(null, error);
          });
        }).toJS,
      );
    }).toJS,
  );
}

/// Answers maplibre-gl-js requests for `<scheme>://…` URLs with what
/// [respond] completes with: JSON text for a JSON request, bytes for a tile
/// or an image, an HTTP status for the error of that status, or null for the
/// error of a 404 Not Found.
void addFixtureProtocol(
  String scheme,
  Future<Object?> Function(String url) respond,
) {
  final maplibre = globalContext.getProperty<JSObject>('maplibregl'.toJS);
  final ajaxError = maplibre.getProperty<JSFunction>('AJAXError'.toJS);
  final blob = globalContext.getProperty<JSFunction>('Blob'.toJS);
  final json = globalContext.getProperty<JSObject>('JSON'.toJS);
  final promise = globalContext.getProperty<JSFunction>('Promise'.toJS);
  maplibre.callMethod<JSAny?>(
    'addProtocol'.toJS,
    scheme.toJS,
    ((JSObject request, JSAny? _) {
      final url = request.getProperty<JSString>('url'.toJS).toDart;
      return promise.callAsConstructor<JSObject>(
        ((JSFunction resolve, JSFunction reject) {
          respond(url).then((body) {
            if (body == null || body is int) {
              final status = body as int? ?? 404;
              final error = ajaxError.callAsConstructor<JSObject>(
                status.toJS,
                (status == 404 ? 'Not Found' : 'Error').toJS,
                url.toJS,
                blob.callAsConstructor<JSObject>(JSArray<JSAny?>()),
              );
              reject.callAsFunction(null, error);
              return;
            }
            final data = switch (body) {
              final String text => json.callMethod<JSAny?>(
                'parse'.toJS,
                text.toJS,
              ),
              // A copy, as a view may lie in a larger buffer.
              final Uint8List bytes => Uint8List.fromList(bytes).buffer.toJS,
              _ => throw ArgumentError.value(body, 'body'),
            };
            resolve.callAsFunction(
              null,
              JSObject()..setProperty('data'.toJS, data),
            );
          });
        }).toJS,
      );
    }).toJS,
  );
}

/// How many elements of the page match the CSS [selector].
int countElements(String selector) => globalContext
    .getProperty<JSObject>('document'.toJS)
    .callMethod<JSObject>('querySelectorAll'.toJS, selector.toJS)
    .getProperty<JSNumber>('length'.toJS)
    .toDartInt;

/// The pixels of a frame that maplibre-gl-js drew: `rgba` rows of `width`
/// pixels, `scale` pixels per logical pixel of the map.
typedef MapFrame = ({int width, int height, Uint8List rgba, double scale});

/// Reads the next frame that the maplibre-gl-js map on the page draws.
///
/// Its canvas keeps no frame once the browser showed it, so this reads the
/// canvas right after gl-js renders, in the same task, and has it render
/// once more. Before it has seen the map render, [render] makes it.
Future<MapFrame> readMapFrame(void Function() render) {
  if (!globalContext.has('__maplibreReadFrame')) {
    globalContext.callMethod<JSAny?>('eval'.toJS, _readFrameScript.toJS);
  }
  final frame = globalContext
      .callMethod<JSPromise<JSObject>>('__maplibreReadFrame'.toJS)
      .toDart;
  if (!globalContext.callMethod<JSBoolean>('__maplibreSeen'.toJS).toDart) {
    render();
  }
  return frame.then((frame) {
    final data = frame.getProperty<JSObject>('data'.toJS);
    return (
      width: frame.getProperty<JSNumber>('width'.toJS).toDartInt,
      height: frame.getProperty<JSNumber>('height'.toJS).toDartInt,
      rgba: (data as JSUint8ClampedArray).toDart.buffer.asUint8List(),
      scale: frame.getProperty<JSNumber>('scale'.toJS).toDartDouble,
    );
  });
}

const _readFrameScript = '''
(() => {
  const proto = maplibregl.Map.prototype;
  const render = proto._render;
  let pending = [];
  let last = null;
  proto._render = function (...args) {
    const result = render.apply(this, args);
    last = this;
    if (pending.length > 0) {
      const canvas = this.getCanvas();
      const copy = document.createElement('canvas');
      copy.width = canvas.width;
      copy.height = canvas.height;
      const context = copy.getContext('2d');
      context.drawImage(canvas, 0, 0);
      const image = context.getImageData(0, 0, canvas.width, canvas.height);
      const frame = {
        width: canvas.width,
        height: canvas.height,
        data: image.data,
        scale: canvas.width / canvas.clientWidth,
      };
      const waiting = pending;
      pending = [];
      for (const resolve of waiting) resolve(frame);
    }
    return result;
  };
  window.__maplibreReadFrame = () => new Promise((resolve) => {
    pending.push(resolve);
    if (last) last.triggerRepaint();
  });
  window.__maplibreSeen = () => last !== null;
})();
''';
