// The sparse raster-dem routing of maplibre_web in a page of its own, for the
// headless browser check of tool/sparse_dem_check (run.sh compiles it with
// `dart compile js`). Load the script after maplibre-gl-js and call
// `sparseDem.register()`; then wire each map as map_state.dart does:
// `transformRequest: sparseDem.transformRequest`, `sparseDem.onEmptyTile(map)`,
// `sparseDem.setSource(map, id)` on a source's metadata event,
// `sparseDem.refresh(map)` on a style data event, and
// `sparseDem.styleSet()` before `map.setStyle`.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:maplibre_web/src/sparse_dem.dart';

void main() {
  final tiles = RasterDemTiles();
  void register() => globalContext
      .getProperty<JSObject>('maplibregl'.toJS)
      .callMethod<JSAny?>(
        'addProtocol'.toJS,
        sparseDemProtocol.toJS,
        sparseDemLoad.toJS,
      );
  void setSource(JSObject map, String id) => tiles.setJsSource(
    id,
    map.callMethod<JSObject?>('getSource'.toJS, id.toJS),
  );
  int knownEmpty() => knownEmptyTiles.length;
  void refresh(JSObject map) => tiles.refresh(
    (id) => map.callMethod<JSObject?>('getSource'.toJS, id.toJS),
  );
  void styleSet() => knownEmptyTiles.clear();
  // As map_state.dart wires it, without a MapLibreNetwork transform.
  JSObject? transformRequest(String url, String? resourceType) =>
      tiles.transformRequest(url, resourceType);
  void onEmptyTile(JSObject map) => emptyTileListeners.add(
    () => map.callMethod<JSAny?>('triggerRepaint'.toJS),
  );
  globalContext.setProperty(
    'sparseDem'.toJS,
    JSObject()
      ..setProperty('register'.toJS, register.toJS)
      ..setProperty('transformRequest'.toJS, transformRequest.toJS)
      ..setProperty('setSource'.toJS, setSource.toJS)
      ..setProperty('knownEmpty'.toJS, knownEmpty.toJS)
      ..setProperty('refresh'.toJS, refresh.toJS)
      ..setProperty('styleSet'.toJS, styleSet.toJS)
      ..setProperty('onEmptyTile'.toJS, onEmptyTile.toJS),
  );
}
