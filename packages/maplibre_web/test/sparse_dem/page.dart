// The sparse raster-dem routing of maplibre_web in a page of its own, for the
// headless browser tests of the terrain fixture: compile with
// `dart compile js -o page.js test/sparse_dem/page.dart`, load the script
// after maplibre-gl-js, and call `sparseDem.register()`, then create maps
// with `transformRequest: sparseDem.transformRequest` and pass each source's
// metadata event to `sparseDem.setSource(map, id)`, as map_state.dart does.
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
      ..setProperty('onEmptyTile'.toJS, onEmptyTile.toJS),
  );
}
