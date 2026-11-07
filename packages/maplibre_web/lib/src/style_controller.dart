part of 'map_state.dart';

/// Web specific implementation of the [StyleController].
class StyleControllerWeb extends StyleController implements StyleBackend {
  /// Create a new [StyleControllerWeb] instance.
  StyleControllerWeb(this._map, this._deferredTerrain, this._rasterDemTiles);

  final interop.JsMap _map;

  /// The raster-dem tiles of the map's sources (see `sparse_dem.dart`).
  final RasterDemTiles _rasterDemTiles;

  /// Holds a terrain set while the map loads a new style.
  final DeferredTerrain _deferredTerrain;

  @override
  late final StyleSources sources = StyleSources(this, layers: () => layers);

  @override
  late final StyleLayers layers = StyleLayers(this, sources: sources);

  /// Fills [layers] and [sources] from the style that the map loaded.
  void load() {
    final style = _map.getStyle();
    if (style == null) return;
    final json = jsonDecode(stringify(style)) as Map<String, Object?>;
    if (json case {'sources': final Map<String, Object?> styleSources}) {
      sources.load(styleSources);
    }
    if (json case {'layers': final List<Object?> styleLayers}) {
      layers.load(styleLayers.whereType<Map<String, Object?>>());
    }
  }

  /// Reads what the tile sources of the map learned from their TileJSON into
  /// [sources].
  void refreshTileJson() {
    for (final source in sources.toList()) {
      final js = _map.getSource(source.id);
      if (js == null) continue;
      sources.applyTileJson(
        source.id,
        attribution: js['attribution'].dartify()?.toString(),
        minZoom: (js['minzoom'].dartify() as num?)?.toDouble(),
        maxZoom: (js['maxzoom'].dartify() as num?)?.toDouble(),
        bounds: switch (js['bounds'].dartify()) {
          final List<Object?> bounds when bounds.length == 4 => [
            for (final value in bounds) (value! as num).toDouble(),
          ],
          _ => null,
        },
      );
    }
  }

  @override
  void batch(void Function() updates) => updates();

  /// The blob URLs of image and video sources from bytes or an
  /// [ImageProvider], by source id. They are revoked when their source is
  /// removed.
  final _blobUrls = <String, String>{};

  @override
  Future<void> addImage(
    String id,
    Uint8List bytes, {
    double pixelRatio = 1,
    StyleImageOptions options = const StyleImageOptions(),
  }) async {
    // The browser decodes the image: Flutter's skwasm renderer gives decoded
    // images the size of the view.
    final blob = Blob([bytes.toJS].toJS);
    final bitmap = await window.createImageBitmap(blob).toDart;
    _map.addImage(id, bitmap, options.toJs(pixelRatio));
  }

  @override
  Future<void> addImageFromUiImage({
    required String id,
    required ui.Image image,
    double pixelRatio = 1,
    StyleImageOptions options = const StyleImageOptions(),
  }) async {
    // Raw pixels, as Flutter's skwasm renderer encodes some images to PNG at
    // the size of the view.
    final data = await image.toByteData(
      format: ImageByteFormat.rawStraightRgba,
    );
    if (data == null) {
      throw StateError('Failed to read the pixels of the image "$id".');
    }
    _map.addImage(
      id,
      interop.ImageSpecification(
        width: image.width,
        height: image.height,
        data: data.buffer.asUint8List().toJS,
      ),
      options.toJs(pixelRatio),
    );
  }

  @override
  Future<void> removeImage(String id) async => _map.removeImage(id);

  @override
  Future<void> addLayer(
    Map<String, Object?> json, {
    String? belowLayerId,
  }) async =>
      _throwErrorEvents(() => _map.addLayer(json.jsify()!, belowLayerId));

  @override
  Future<void> removeLayer(String id) async => _map.removeLayer(id);

  @override
  void moveLayer(String id, {String? belowLayerId}) =>
      _map.moveLayer(id, belowLayerId);

  @override
  void setLayerProperty(
    String layerId,
    String name,
    Object? value, {
    required bool layout,
  }) => layout
      ? _map.setLayoutProperty(layerId, name, value.jsify())
      : _map.setPaintProperty(layerId, name, value.jsify());

  @override
  void setFilter(String layerId, Object? filter) =>
      _map.setFilter(layerId, filter.jsify());

  @override
  void setZoomRange(String layerId, double minZoom, double maxZoom) =>
      _map.setLayerZoomRange(layerId, minZoom, maxZoom);

  @override
  Future<void> removeSource(String id) async {
    // Removing a source the style lacks is not an error on other platforms.
    if (_map.getSource(id) != null) _map.removeSource(id);
    _rasterDemTiles.removeSource(id);
    if (_blobUrls.remove(id) case final String url) {
      URL.revokeObjectURL(url);
    }
  }

  @override
  Future<void> setGeoJsonData(String id, GeoJsonData data) async =>
      _map.getSource(id)!.setData(data.toJs());

  @override
  Future<void> setGeoJsonUrl(String id, String url) async =>
      _map.getSource(id)!.setData(url.toJS);

  @override
  Future<void> setImageCoordinates(String id, LngLatQuad coordinates) async =>
      _map.getSource(id)!.setCoordinates(coordinates.toJson().jsify()!);

  @override
  Future<void> setTiles(
    String id,
    List<String> tiles,
    Map<String, Object?> specification,
  ) async {
    _map.getSource(id)!.setTiles(tiles.jsify()!);
    // Its tiles may be another tileset's now.
    _rasterDemTiles.setJsSource(id, _map.getSource(id));
  }

  @override
  Future<void> setTileJsonUrl(
    String id,
    String url,
    Map<String, Object?> specification,
  ) async => _map.getSource(id)!.setUrl(url);

  @override
  List<String> get attributions {
    final sources =
        _map.getStyle()?.sources.dartify() as Map<Object?, Object?>?;
    if (sources == null) return const [];
    final attributions = <String>[];
    for (final MapEntry(:key, :value) in sources.entries) {
      // The source object has the attribution of a loaded TileJSON, the
      // style only the one of the source options.
      final attribution =
          _map.getSource(key! as String)?['attribution'].dartify() ??
          (value! as Map<Object?, Object?>)['attribution'];
      if (attribution == null) continue;
      if (attribution is String && attribution.isEmpty) continue;
      attributions.add(attribution.toString());
    }
    return attributions;
  }

  @override
  Future<void> addSource(Source source) async {
    switch (source) {
      case GeoJsonSource():
        // The browser parses the data, which is faster than Dart.
        final data = switch (source) {
          GeoJsonSourceUrl(:final url) => url.toJS,
          GeoJsonSourceData(:final data) => data.toJs(),
        };
        _addSource(
          source.id,
          _sourceSpecification({
            'type': 'geojson',
            ...geoJsonOptionsOf(source),
          }, data: data),
        );
      case RasterDemSource() || RasterSource() || VectorSource():
        // gl-js has no volatile sources.
        _addSource(
          source.id,
          _sourceSpecification(source.toJson()!..remove('volatile')),
        );
      case ImageSource():
        // MapLibre GL JS loads image sources only from a URL. The image of a
        // provider must be resolved first, so the source starts with an empty
        // image: calls after this one must find it on the map.
        final url = switch (source) {
          ImageSourceUrl(:final url) => url,
          ImageSourceBytes(:final bytes) => URL.createObjectURL(
            Blob([bytes.toJS].toJS),
          ),
          ImageSourceProvider() => _emptyImageUrl,
        };
        _addBlobSource(
          source.id,
          source is ImageSourceBytes ? url : null,
          interop.SourceSpecification.image(
            type: 'image',
            url: url,
            // The coordinates start at the top left corner of the image and
            // proceed in clockwise order.
            // https://github.com/maplibre/maplibre-gl-js/blob/87486a5ef2085e600e8fa4e31252629dd8488dcd/src/source/image_source.ts#L24
            coordinates: source.coordinates.toJson().jsify()!,
          ),
        );
        if (source is ImageSourceProvider) {
          await _loadProviderImage(source);
        }
      case VideoSource():
        final blobUrl = switch (source) {
          VideoSourceBytes(:final bytes) => URL.createObjectURL(
            Blob([bytes.toJS].toJS),
          ),
          _ => null,
        };
        final urls = switch (source) {
          VideoSourceUrls(:final urls) => urls,
          VideoSourceBytes() => [blobUrl!],
          VideoSourceAsset(:final asset) => [AssetManager().getAssetUrl(asset)],
        };
        _addBlobSource(
          source.id,
          blobUrl,
          interop.SourceSpecification.video(
            type: 'video',
            urls: urls.jsify()!,
            coordinates: source.coordinates.toJson().jsify()!,
          ),
        );
    }
  }

  /// Adds the source [specification], whose content comes from [blobUrl]
  /// if it isn't null. The blob URL is kept for [removeSource] once the map
  /// accepts the source, and revoked if it rejects it.
  void _addBlobSource(
    String id,
    String? blobUrl,
    interop.SourceSpecification specification,
  ) {
    try {
      _addSource(id, specification);
    } catch (_) {
      if (blobUrl != null) URL.revokeObjectURL(blobUrl);
      rethrow;
    }
    if (blobUrl != null) _blobUrls[id] = blobUrl;
  }

  /// Gives the image source [source], which was added with an empty image,
  /// the image of its provider.
  Future<void> _loadProviderImage(ImageSourceProvider source) async {
    // Whether the source is still on the map: it may have been removed or
    // replaced meanwhile. Moving its corners keeps the image.
    bool current() => switch (sources[source.id]) {
      ImageSourceProvider(:final image) => identical(image, source.image),
      _ => false,
    };
    final String blobUrl;
    try {
      blobUrl = await _blobUrlOfProvider(source.image);
    } catch (_) {
      // The collection takes the source out again.
      if (current()) _map.removeSource(source.id);
      rethrow;
    }
    if (!current()) {
      URL.revokeObjectURL(blobUrl);
      return;
    }
    _blobUrls[source.id] = blobUrl;
    _map
        .getSource(source.id)!
        .updateImage(interop.UpdateImageOptions(url: blobUrl));
  }

  /// Adds the source [specification] and throws if the map rejects it.
  void _addSource(String id, interop.SourceSpecification specification) =>
      _throwErrorEvents(() => _map.addSource(id, specification));

  /// Runs [change] and throws the first error that the map reports meanwhile.
  /// MapLibre GL JS fires an error event instead of throwing for some changes
  /// it rejects, such as a layer or source that fails validation.
  void _throwErrorEvents(void Function() change) {
    String? error;
    final listener = (JSObject event) {
      error ??=
          event
              .getProperty<JSObject?>('error'.toJS)
              ?.getProperty<JSString?>('message'.toJS)
              ?.toDart ??
          'The map rejected the change.';
    }.toJS;
    _map.on(interop.MapEventType.error, listener);
    try {
      change();
    } finally {
      _map.off(interop.MapEventType.error, listener);
    }
    if (error case final error?) throw StateError(error);
  }

  var _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    layers.dispose();
    sources.dispose();
    // Interop members can't be torn off for forEach.
    // ignore: prefer_foreach
    for (final url in _blobUrls.values) {
      URL.revokeObjectURL(url);
    }
    _blobUrls.clear();
  }

  /// A blob URL of a PNG of the image of [provider].
  static Future<String> _blobUrlOfProvider(ImageProvider provider) async {
    final image = await resolveImageProvider(provider);
    try {
      // Raw pixels, as Flutter's skwasm renderer encodes some images to PNG at
      // the size of the view.
      final data = await image.toByteData(
        format: ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        throw StateError('Failed to read the pixels of the image source.');
      }
      final canvas = OffscreenCanvas(image.width, image.height);
      final context =
          canvas.getContext('2d')! as OffscreenCanvasRenderingContext2D;
      context.putImageData(
        ImageData(data.buffer.asUint8ClampedList().toJS, image.width),
        0,
        0,
      );
      final blob = await canvas.convertToBlob().toDart;
      return URL.createObjectURL(blob);
    } finally {
      image.dispose();
    }
  }

  @override
  void setProjection(Expression<MapProjection> projection) =>
      _map.setProjection(
        interop.ProjectionSpecification(type: projection.toJson().jsify()!),
      );

  @override
  Future<void> setTerrain(Terrain? terrain) async {
    // Before the deferral, so a replaced style fails alike during a load.
    _checkCurrent();
    if (_deferredTerrain.defer(terrain) case final applied?) return applied;
    applyTerrain(terrain);
  }

  /// Sets [terrain] on the map now, which must have loaded its style.
  void applyTerrain(Terrain? terrain) {
    _checkCurrent();
    // MapLibre GL JS throws an error that doesn't say which source is
    // missing in its message, and takes a source without heights, so both
    // are checked first, with the same errors as on native.
    if (terrain != null) {
      final source = _map.getSource(terrain.sourceId);
      if (source == null) {
        throw StateError(
          'The style is missing the source "${terrain.sourceId}" of the '
          'terrain.',
        );
      }
      final type = source.getProperty<JSString?>('type'.toJS)?.toDart;
      if (type != 'raster-dem') {
        throw StateError(
          'The source "${terrain.sourceId}" of the terrain is a "$type" '
          'source, not "raster-dem".',
        );
      }
    }
    _throwErrorEvents(() => _map.setTerrain(terrain?.toJson().jsify()));
  }

  /// Throws once a newer style replaced this one, whether or not a style
  /// loads: a replaced style takes no terrain.
  void _checkCurrent() {
    if (_disposed) {
      throw StateError('The style was replaced; use the current style.');
    }
  }

  @override
  Terrain? get terrain {
    final terrain = _map.getTerrain();
    if (terrain == null) return null;
    return Terrain(
      sourceId: terrain.getProperty<JSString>('source'.toJS).toDart,
      exaggeration:
          terrain.getProperty<JSNumber?>('exaggeration'.toJS)?.toDartDouble ??
          1,
    );
  }

  @override
  Future<void> setGlobalState(String key, Object? value) async =>
      _map.setGlobalStateProperty(key, value.jsify());
}

/// A transparent PNG of one pixel, the image of an image source until its
/// image is ready.
const _emptyImageUrl =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

/// A source specification of the [properties] that are set. MapLibre GL JS
/// rejects a property that is present but null.
interop.SourceSpecification _sourceSpecification(
  Map<String, Object?> properties, {
  JSAny? data,
}) {
  final spec =
      ({...properties}..removeWhere((key, value) => value == null)).jsify()!
          as JSObject;
  if (data != null) spec.setProperty('data'.toJS, data);
  return spec as interop.SourceSpecification;
}
