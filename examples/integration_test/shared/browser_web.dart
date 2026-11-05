import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject get _performance =>
    globalContext.getProperty<JSObject>('performance'.toJS);

/// Clears the browser's resource timing entries.
void clearResourceTimings() =>
    _performance.callMethod<JSAny?>('clearResourceTimings'.toJS);

/// How many requests the browser made for [url].
int resourceRequests(String url) => _performance
    .callMethod<JSArray<JSAny?>>('getEntriesByName'.toJS, url.toJS)
    .length;

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
