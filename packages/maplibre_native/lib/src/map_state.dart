import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:maplibre_native/src/extensions.dart';
import 'package:maplibre_native/src/map_renderer.dart';
import 'package:maplibre_native/src/style_controller.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart' as mln;
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// MapLibre Native, rendered through its C API into a Flutter texture.
class MapLibreMapStateNative extends MapLibreMapState {
  MapRenderer? _renderer;

  /// The events that the map queues, see `MapLibreMapExt.eventMask`.
  mln.RuntimeEventFlag? _eventMask;

  /// The map, from its creation on, before [_renderer] exists.
  mln.MapHandle? _map;
  Future<void>? _creating;
  var _disposed = false;

  @override
  StyleControllerNative? style;

  /// Whether the camera constraints of [MapOptions] wait for the first
  /// style, see [_setUp].
  var _constraintsAfterStyle = false;

  /// Holds a terrain set while [_setStyle] loads a style.
  final _deferredTerrain = DeferredTerrain();

  /// The generations of the style loads submitted to the map that it hasn't
  /// started yet, oldest first.
  ///
  /// The map runs its commands in order, and each style load reports
  /// `mapLoadingStarted` before anything else of that load: its
  /// `mapStyleLoaded` or `mapLoadingFailed` follows its start, and the start
  /// of a newer load cancels it. So the end of a load belongs to the load
  /// that started last. Its generation can be older than the latest one: the
  /// map may have ended a load before Dart submitted a newer style, whose
  /// generation is already the latest by the time the event arrives.
  final _submittedStyleLoads = ListQueue<int>();

  /// The generation of the style load that the map started last.
  var _startedStyleLoad = 0;

  /// A projection of the latest published camera. Closed whenever the camera
  /// or extent changes, because a projection never sees later map changes.
  mln.MapProjectionHandle? _projection;

  /// The view of the map frame on screen, and its projection once a screen
  /// location needs it. The map image trails the latest camera by a frame or
  /// two, so [camera] and screen locations follow this one, and widgets over
  /// the map stay on what they mark. The projection is made on demand, not
  /// for every frame.
  mln.MapView? _shownView;
  mln.MapProjectionHandle? _shownProjection;

  /// The session extent generation of the frame on screen. Screen locations
  /// move with the extent even while the camera stays.
  int? _shownExtentGeneration;

  /// The camera of the last camera event, to report each change once.
  CameraPosition? _eventCamera;

  var _gestureActive = false;
  var _cameraMoving = false;

  /// The running camera animation, to jump to its target when the map
  /// pauses and to report whether it was cancelled.
  _CameraAnimationRun? _animation;

  /// Why the camera moves, from the start of the move on.
  CameraChangeReason _moveReason = CameraChangeReason.map;

  /// Why the camera changes next. Runtime events arrive after the change was
  /// submitted, possibly after a short gesture already ended, so the reason
  /// is taken when the change is made.
  CameraChangeReason? _nextChangeReason;

  @override
  late final GestureCameraSink gestureCamera = _NativeGestureCamera(this);

  @override
  Widget buildPlatformWidget(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = mln.LogicalExtent(
          width: constraints.maxWidth.isFinite
              ? constraints.maxWidth.floor().clamp(1, 16384)
              : 256,
          height: constraints.maxHeight.isFinite
              ? constraints.maxHeight.floor().clamp(1, 16384)
              : 256,
          scaleFactor: pixelRatio,
        );
        final renderer = _renderer;
        if (renderer == null) {
          _creating ??= _create(extent, pixelRatio);
          return const SizedBox.expand();
        }
        if (renderer.extent != extent) {
          renderer.resize(extent);
          _invalidateProjection();
        }
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _map?.discarding.cancelCameraTransitions(),
          child: Texture(textureId: renderer.textureId),
        );
      },
    );
  }

  Future<void> _create(mln.LogicalExtent extent, double pixelRatio) async {
    try {
      // The map takes its options, camera, and style before the session
      // renders, so its first frame shows them.
      final renderer = await MapRenderer.create(
        extent: extent,
        eventMask: _eventMask = widget.eventMask,
        fastPforEnabled: options.fastPforEnabled,
        setUp: _setUp,
        onEvent: _onRuntimeEvent,
        onFrameShown: _onFrameShown,
      );
      if (_disposed) {
        await renderer.dispose();
        return;
      }
      _renderer = renderer..paused = isRenderingPaused;
      setState(() {
        camera = _readCamera();
        isInitialized = true;
      });
      widget.onMapCreated?.call(this);
      // Events that arrived meanwhile, such as the style load, follow
      // onMapCreated.
      renderer.start();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'maplibre_native',
          context: ErrorDescription('while creating the map'),
        ),
      );
    }
  }

  /// Submits the options, initial camera, and style of a new [map].
  Future<void> _setUp(mln.MapHandle map) async {
    _map = map;
    // The callbacks may have changed while the map was being created.
    final eventMask = widget.eventMask;
    if (eventMask != _eventMask) {
      _eventMask = eventMask;
      map.discarding.setEventMask(eventMask);
    }
    final options = this.options;
    final initCamera = options.initCamera;
    // Without an initial camera, MapLibre Native moves to the camera of the
    // style once it loads, but only while no camera change happened. Setting
    // camera constraints is one, so they follow the first style.
    _constraintsAfterStyle = initCamera == null;
    await Future.wait([
      _applyCenterClamp(map),
      if (initCamera != null) ...[
        _applyOptions(),
        _applyInitialCamera(map, initCamera),
      ],
      _setStyle(options.style),
    ]);
  }

  Future<void> _applyInitialCamera(
    mln.MapHandle map,
    CameraUpdate initCamera,
  ) async {
    final camera = await initCamera.toMln(map);
    await map.updateCamera(mln.CameraUpdate(camera: camera));
  }

  /// Applies [MapOptions.centerClampedToGround]. The map keeps it for every
  /// style, and it applies only while the style has a terrain.
  Future<void> _applyCenterClamp(mln.MapHandle map) => map.setTerrainOptions(
    mln.MapTerrainOptions(centerClampedToGround: options.centerClampedToGround),
  );

  /// Applies the camera constraints of [MapOptions].
  Future<void> _applyOptions() async {
    final map = _map;
    if (map == null || _constraintsAfterStyle) return;
    final options = this.options;
    await map.setBounds(
      mln.BoundOptions(
        bounds: switch (options.maxBounds) {
          final bounds? => bounds.toMln(),
          null => null,
        },
        unbounded: options.maxBounds == null,
        minZoom: options.minZoom,
        maxZoom: options.maxZoom,
        minPitch: options.minPitch,
        maxPitch: options.maxPitch,
      ),
    );
  }

  @override
  void setRenderingPaused({required bool paused}) {
    _renderer?.paused = paused;
    // Camera animations advance only while the map renders. One that runs
    // now ends at its target, so its caller does not wait for the resume.
    final animation = _animation;
    final map = _map;
    if (!paused || animation == null || map == null) return;
    _animation = null;
    unawaited(map.updateCamera(mln.CameraUpdate(camera: animation.target)));
  }

  @override
  void didUpdateWidget(covariant MapLibreMap oldWidget) {
    final options = widget.options;
    if (oldWidget.options != options) unawaited(_applyOptions());
    if (oldWidget.options.centerClampedToGround !=
        options.centerClampedToGround) {
      if (_map case final map?) unawaited(_applyCenterClamp(map));
    }
    if (oldWidget.options.style != options.style) {
      unawaited(_setStyle(options.style));
    }
    layerManager?.updateLayers(widget.layers);
    final eventMask = widget.eventMask;
    final map = _map;
    if (eventMask != _eventMask && map != null) {
      _eventMask = eventMask;
      map.discarding.setEventMask(eventMask);
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _disposed = true;
    _animation?.end(CameraAnimationResult.cancelled);
    _animation = null;
    _deferredTerrain.dispose();
    style?.dispose();
    _loadingStyle?.dispose();
    _invalidateProjection();
    _shownProjection?.release();
    _shownProjection = null;
    _map = null;
    unawaited(_renderer?.dispose());
    super.dispose();
  }

  // Events

  void _onRuntimeEvent(mln.RuntimeEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case mln.RuntimeEventType.mapCameraWillChange:
        if (_cameraMoving) return;
        _cameraMoving = true;
        final reason =
            _nextChangeReason ??
            (_gestureActive
                ? CameraChangeReason.gesture
                : CameraChangeReason.map);
        _nextChangeReason = null;
        _moveReason = reason;
        widget.onCameraMoveStart?.call(MapEventCameraMoveStart(reason: reason));
      case mln.RuntimeEventType.mapCameraIsChanging:
        _onCameraChanged();
      case mln.RuntimeEventType.mapCameraDidChange:
        _onCameraChanged();
        // A gesture publishes one change per pointer update and ends with
        // the gesture instead, and an animation changes the camera once per
        // transition until its last one ended.
        final snapshot = _map?.getSnapshot();
        if (!_gestureActive &&
            snapshot != null &&
            !snapshot.transitionInProgress) {
          _onCameraIdle();
        }
      case mln.RuntimeEventType.mapLoadingStarted:
        _startedStyleLoad = _submittedStyleLoads.isEmpty
            // Not a load of _setStyle; none starts elsewhere.
            ? _deferredTerrain.generation
            : _submittedStyleLoads.removeFirst();
        widget.onLoadingStarted?.call(const MapEventLoadingStarted());
      case mln.RuntimeEventType.mapStyleLoaded:
        // A style requested later replaces this one, and its own load hands
        // it out, as on web.
        if (_startedStyleLoad != _deferredTerrain.generation) return;
        unawaited(_onStyleLoaded(_startedStyleLoad));
      case mln.RuntimeEventType.mapIdle:
        widget.onIdle?.call(const MapEventIdle());
      case mln.RuntimeEventType.mapSourceChanged:
        // A source learns its attribution once its tile set loads.
        unawaited(style?.refreshAttributions());
        final onSourceChanged = widget.onSourceChanged;
        if (onSourceChanged == null) return;
        if (event.payload case mln.RuntimeEventPayloadSourceChanged(
          :final value,
        )) {
          onSourceChanged(MapEventSourceChanged(sourceId: value.sourceId));
        }
      case mln.RuntimeEventType.mapLoadingFailed:
        // Reported only for the style document, not for its resources.
        _deferredTerrain.styleLoadFailed(
          _startedStyleLoad,
          StateError('The style failed to load: ${event.message}'),
        );
        _onError(MapErrorKind.style, event.message);
      case mln.RuntimeEventType.mapRenderError:
        _onError(MapErrorKind.render, event.message);
      case mln.RuntimeEventType.mapGlyphsError:
        _onError(MapErrorKind.glyphs, event.message);
      case mln.RuntimeEventType.mapSpriteError:
        _onError(MapErrorKind.sprite, event.message);
      case mln.RuntimeEventType.mapLoadingFinished:
        widget.onLoadingFinished?.call(const MapEventLoadingFinished());
      case mln.RuntimeEventType.mapStyleImageMissing:
        final onStyleImageMissing = widget.onStyleImageMissing;
        if (onStyleImageMissing == null) return;
        if (event.payload case mln.RuntimeEventPayloadStyleImage(
          :final value,
        )) {
          onStyleImageMissing(MapEventStyleImageMissing(id: value.imageId));
        }
      case mln.RuntimeEventType.mapTileAction:
        final onTile = widget.onTile;
        final action = switch (event.payload) {
          mln.RuntimeEventPayloadTileAction(:final value) => value,
          _ => null,
        };
        final operation = action?.operation.toMapTileOperation();
        if (onTile == null || action == null || operation == null) return;
        final tile = action.tileId;
        onTile(
          MapEventTile(
            operation: operation,
            sourceId: action.sourceId,
            z: tile.canonicalZ,
            x: tile.canonicalX,
            y: tile.canonicalY,
            overscaledZ: tile.overscaledZ,
            wrap: tile.wrap,
          ),
        );
      case mln.RuntimeEventType.mapRenderFrameFinished:
        final onRenderFrame = widget.onRenderFrame;
        final frame = switch (event.payload) {
          mln.RuntimeEventPayloadRenderFrame(:final value) => value,
          _ => null,
        };
        if (onRenderFrame == null || frame == null) return;
        final stats = frame.stats;
        onRenderFrame(
          MapEventRenderFrame(
            fullyRendered: frame.mode == mln.RenderMode.full,
            stats: MapRenderingStats(
              encodingTime: _milliseconds(stats.encodingTimeMs),
              renderingTime: _milliseconds(stats.renderingTimeMs),
              drawCalls: stats.drawCallCount,
            ),
          ),
        );
      case mln.RuntimeEventType.mapRenderMapFinished:
        // The C API reports only fully rendered maps here.
        widget.onRenderMap?.call(const MapEventRenderMap(fullyRendered: true));
      case mln.RuntimeEventType.mapGlyphsRequested ||
          mln.RuntimeEventType.mapGlyphsLoaded:
        final onGlyphs = widget.onGlyphs;
        final glyphs = switch (event.payload) {
          mln.RuntimeEventPayloadGlyphs(:final value) => value,
          _ => null,
        };
        if (onGlyphs == null || glyphs == null) return;
        onGlyphs(
          MapEventGlyphs(
            state: event.type == mln.RuntimeEventType.mapGlyphsLoaded
                ? MapResourceState.loaded
                : MapResourceState.requested,
            fontStack: glyphs.fontStack,
            first: glyphs.first,
            last: glyphs.last,
          ),
        );
      case mln.RuntimeEventType.mapSpriteRequested ||
          mln.RuntimeEventType.mapSpriteLoaded:
        final onSprite = widget.onSprite;
        final sprite = switch (event.payload) {
          mln.RuntimeEventPayloadSprite(:final value) => value,
          _ => null,
        };
        if (onSprite == null || sprite == null) return;
        onSprite(
          MapEventSprite(
            state: event.type == mln.RuntimeEventType.mapSpriteLoaded
                ? MapResourceState.loaded
                : MapResourceState.requested,
            id: sprite.id,
            url: sprite.url,
          ),
        );
      default:
        break;
    }
  }

  /// Reports an error to [MapLibreMap.onError], or prints it while no
  /// callback is set, so it is never lost.
  void _onError(MapErrorKind kind, String message) {
    final onError = widget.onError;
    if (onError == null) {
      debugPrint('maplibre_native: $message');
      return;
    }
    onError(MapEventError(kind: kind, message: message));
  }

  static Duration _milliseconds(double milliseconds) => Duration(
    microseconds: (milliseconds * Duration.microsecondsPerMillisecond).round(),
  );

  /// Reports the map's latest camera. [camera] instead follows the frame on
  /// screen, see [_onFrameShown].
  void _onCameraChanged() {
    _invalidateProjection();
    final newCamera = _readCamera();
    if (newCamera == null || newCamera == _eventCamera) return;
    _eventCamera = newCamera;
    widget.onCameraMove?.call(
      MapEventCameraMove(camera: newCamera, reason: _moveReason),
    );
  }

  /// Moves [camera] and screen locations to the frame that Flutter shows
  /// next, so widgets over the map rebuild in the same frame as the map.
  void _onFrameShown(mln.RenderFrameResult frame) {
    if (_disposed) return;
    _shownProjection?.release();
    _shownProjection = null;
    _shownView = frame.view;
    final shown = frame.view.camera.toCameraPosition();
    final resized = frame.generation != _shownExtentGeneration;
    _shownExtentGeneration = frame.generation;
    if (shown == camera && !resized) return;
    setState(() => camera = shown);
  }

  void _onCameraIdle() {
    if (!_cameraMoving) return;
    _cameraMoving = false;
    final onCameraMoveEnd = widget.onCameraMoveEnd;
    final camera = _readCamera();
    if (onCameraMoveEnd == null || camera == null) return;
    onCameraMoveEnd(MapEventCameraMoveEnd(camera: camera, reason: _moveReason));
  }

  /// Submits [update] and waits until its transitions end: they complete,
  /// another change replaces or cancels them, or the map closes.
  Future<CameraAnimationResult> _submitCamera(
    mln.MapHandle map,
    mln.CameraUpdate update,
  ) async {
    _nextChangeReason = CameraChangeReason.programmatic;
    final animates =
        update.mode != mln.CameraUpdateMode.jump && !isRenderingPaused;
    // A later camera write replaces the animation, whether or not it animates.
    final run = _CameraAnimationRun(update.camera);
    _animation = animates ? run : null;
    await map.updateCamera(
      update.copyWith(
        // A paused map does not advance animations, so it jumps.
        mode: isRenderingPaused ? mln.CameraUpdateMode.jump : null,
        animation: update.animation.copyWith(
          endHandler: mln.CameraTransitionHandler(
            callback: (end) {
              if (identical(_animation, run)) _animation = null;
              run.end(
                end.outcome == mln.CameraTransitionOutcome.completed
                    ? CameraAnimationResult.completed
                    : CameraAnimationResult.cancelled,
              );
            },
          ),
        ),
      ),
    );
    return run.result;
  }

  /// Cancels the running camera animation, for a gesture or [stopCamera].
  void _cancelAnimation() {
    final animation = _animation;
    if (animation == null) return;
    _animation = null;
    animation.cancelled = true;
    _map?.discarding.cancelCameraTransitions();
  }

  /// The style controller that [_onStyleLoaded] is filling, until it becomes
  /// [style].
  StyleControllerNative? _loadingStyle;

  Future<void> _onStyleLoaded(int generation) async {
    final map = _map;
    if (map == null) return;
    if (_constraintsAfterStyle) {
      _constraintsAfterStyle = false;
      await _applyOptions();
    }
    // Only the next LayerManager sees MapLibreMap.layers: the layers of the
    // old one are gone.
    layerManager = null;
    style?.dispose();
    style = null;
    late final StyleControllerNative styleController;
    styleController = StyleControllerNative(
      map,
      _deferredTerrain,
      // Rebuilds the widgets in MapLibreMap.children, such as
      // SourceAttribution.
      onAttributionsChanged: () {
        if (mounted && style == styleController) setState(() {});
      },
    );
    _loadingStyle = styleController;
    // The style is only handed out once its layers and sources are known.
    bool stale() => _disposed || _loadingStyle != styleController;
    await styleController.load();
    if (!stale()) {
      // Before the style is handed out, so its terrain is the one set while
      // it loaded.
      await _deferredTerrain.styleLoaded(
        generation,
        styleController.applyTerrain,
      );
    }
    if (stale()) {
      styleController.dispose();
      return;
    }
    _loadingStyle = null;
    style = styleController;
    widget.onStyleLoaded?.call(styleController);
    layerManager = LayerManager(styleController, widget.layers);
    // Refresh the widgets in MapLibreMap.children.
    setState(() {});
  }

  CameraPosition? _readCamera() {
    final map = _map;
    if (map == null || _disposed) return null;
    return map.getSnapshot().view.camera.toCameraPosition();
  }

  // Gestures

  /// Moves the camera's center onto the terrain it looks at, keeping the
  /// view, so the gesture that follows moves, zooms and turns the ground
  /// under the fingers, not a plane at the center's old height. Once per
  /// gesture: the map holds that height while the gesture runs.
  void _anchorOnTerrain() {
    if (style?.terrain == null) return;
    _map?.discarding.anchorCenterOnTerrain();
  }

  /// Applies [delta] without waiting for it, in order with later commands.
  void _applyDelta(mln.CameraDelta delta) =>
      _map?.discarding.applyCameraDelta(delta);

  @override
  Future<List<SourceFeature>> querySourceFeatures(
    String sourceId, {
    String? sourceLayer,
    Expression<bool>? filter,
  }) async {
    final renderer = _renderer;
    if (renderer == null || _disposed) return const [];
    final features = await renderer.querySourceFeatures(
      sourceId,
      sourceLayerIds: sourceLayer == null ? null : [sourceLayer],
      filter: filter?.toJson(),
    );
    return [
      for (final queried in features)
        if (queried.feature case final Map<String, Object?> feature)
          SourceFeature(
            id: feature['id'],
            properties: _properties(feature),
            geometry: RenderedFeature.geometryFromJson(feature['geometry']),
            sourceLayer: _nonEmpty(queried.sourceLayerId),
          ),
    ];
  }

  @override
  Future<double> getClusterExpansionZoom(String sourceId, int clusterId) async {
    final session = _session;
    if (session == null) {
      throw StateError('No cluster $clusterId in the source "$sourceId".');
    }
    return (await session.getClusterExpansionZoom(
      sourceId,
      clusterId,
    )).toDouble();
  }

  @override
  Future<List<SourceFeature>> getClusterChildren(
    String sourceId,
    int clusterId,
  ) async =>
      _clusterFeatures(await _session?.getClusterChildren(sourceId, clusterId));

  @override
  Future<List<SourceFeature>> getClusterLeaves(
    String sourceId,
    int clusterId, {
    int limit = 10,
    int offset = 0,
  }) async => _clusterFeatures(
    await _session?.getClusterLeaves(sourceId, clusterId, limit, offset),
  );

  /// The render session that answers cluster queries, or null once the map
  /// is disposed.
  mln.RenderSessionHandle? get _session =>
      _disposed ? null : _renderer?.session;

  static List<SourceFeature> _clusterFeatures(Object? result) => [
    for (final feature in switch (result) {
      {'features': final List<Object?> features} => features,
      final List<Object?> features => features,
      _ => const <Object?>[],
    })
      if (feature case final Map<String, Object?> feature)
        SourceFeature(
          id: feature['id'],
          properties: _properties(feature),
          geometry: RenderedFeature.geometryFromJson(feature['geometry']),
        ),
  ];

  // MapController

  /// The projection of the frame on screen, so that screen locations match
  /// the map image, or of the latest camera before the first frame.
  mln.MapProjectionHandle _currentProjection() {
    final map = _map;
    if (map == null) {
      throw StateError('The map has not been created yet.');
    }
    final shownView = _shownView;
    if (shownView != null) {
      return _shownProjection ??= mln.MapProjectionHandle.create(shownView);
    }
    return _projection ??= mln.MapProjectionHandle.create(
      map.getSnapshot().view,
    );
  }

  void _invalidateProjection() {
    _projection?.release();
    _projection = null;
  }

  // The map's latest camera, so it reflects a completed moveCamera. [camera]
  // instead follows the frame on screen, for widgets over the map.
  @override
  CameraPosition getCamera() =>
      _readCamera() ??
      camera ??
      (throw StateError('The map has not been created yet.'));

  @override
  Offset toScreenLocation(Geographic lngLat) =>
      toScreenLocations([lngLat]).single;

  @override
  Geographic toLngLat(Offset screenLocation) =>
      toLngLats([screenLocation]).single;

  @override
  List<Offset> toScreenLocations(List<Geographic> lngLats) {
    final projection = _currentProjection();
    return [
      for (final lngLat in lngLats)
        projection.pixelForLatLng(lngLat.toMln()).toOffset(),
    ];
  }

  @override
  List<Geographic> toLngLats(List<Offset> screenLocations) {
    final projection = _currentProjection();
    return [
      for (final screenLocation in screenLocations)
        projection.latLngForPixel(screenLocation.toMln()).toGeographic(),
    ];
  }

  @override
  double getMetersPerPixelAtLatitude(double latitude) =>
      _currentProjection().metersPerPixelAtLatitude(latitude);

  @override
  GeoBox getVisibleBounds() {
    final size = context.size ?? Size.zero;
    final corners = toLngLats([
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]);
    return GeoBox(
      west: corners.map((c) => c.lon).reduce(min),
      east: corners.map((c) => c.lon).reduce(max),
      south: corners.map((c) => c.lat).reduce(min),
      north: corners.map((c) => c.lat).reduce(max),
    );
  }

  @override
  Future<void> moveCamera(CameraUpdate update) async {
    final map = _map;
    if (map == null) return;
    final camera = await update.toMln(map);
    if (_map != map) return;
    // A jump would replace a running animation, which then counts as
    // completed, so it is cancelled first.
    _cancelAnimation();
    await _submitCamera(map, mln.CameraUpdate(camera: camera));
  }

  @override
  Future<CameraAnimationResult> animateCamera(
    CameraUpdate update, {
    CameraAnimation animation = const CameraAnimation.ease(),
  }) async {
    final map = _map;
    if (map == null) return CameraAnimationResult.cancelled;
    final camera = await update.toMln(map);
    if (_map != map) return CameraAnimationResult.cancelled;
    return _submitCamera(
      map,
      mln.CameraUpdate(
        mode: switch (animation) {
          CameraAnimationEase() => mln.CameraUpdateMode.ease,
          CameraAnimationFly() => mln.CameraUpdateMode.fly,
        },
        camera: camera,
        animation: animation.toMln(),
      ),
    );
  }

  @override
  Future<void> stopCamera() async => _cancelAnimation();

  @override
  Future<CameraPosition> cameraFor(CameraUpdate update) async {
    final map = _map;
    if (map == null) {
      throw StateError('The map has not been created yet.');
    }
    final current = getCamera();
    final camera = await update.toMln(map);
    final center = camera.center;
    final padding = camera.padding;
    return CameraPosition(
      center: center?.toGeographic() ?? current.center,
      zoom: camera.zoom ?? current.zoom,
      bearing: camera.bearing ?? current.bearing,
      pitch: camera.pitch ?? current.pitch,
      roll: camera.roll ?? current.roll,
      padding: padding?.toEdgeInsets() ?? current.padding,
    );
  }

  /// Counts [_setStyle] calls, so a style that loads after a newer one was
  /// set is dropped.
  var _styleRequest = 0;

  /// Starts to load [style], see [MapOptions.style]. Completes once the map
  /// has the style load, without waiting for the style document, as later
  /// commands run after it anyway.
  Future<void> _setStyle(MapStyle style) async {
    final map = _map;
    if (map == null) return;
    final request = ++_styleRequest;
    bool stale() => _map != map || request != _styleRequest;
    layerManager = null;
    final generation = _deferredTerrain.styleLoading();
    final Future<mln.CommandCompletion> load;
    try {
      switch (style) {
        case MapStyleJson(:final json):
          load = _startStyleLoad(
            generation,
            () => map.setStyleJson(jsonDecode(json)),
          );
        case MapStyleUrl(:final url):
          load = _startStyleLoad(generation, () => map.setStyleUrl(url));
        case MapStyleFile(:final path):
          final url = Uri.file(path).toString();
          load = _startStyleLoad(generation, () => map.setStyleUrl(url));
        case MapStyleAsset(:final asset):
          final json = await DefaultAssetBundle.of(context).loadString(asset);
          if (stale()) return;
          final decoded = jsonDecode(json);
          load = _startStyleLoad(generation, () => map.setStyleJson(decoded));
      }
    } on Object catch (error) {
      // No style loads, so no terrain waits for one.
      _deferredTerrain.styleLoadFailed(generation, error);
      rethrow;
    }
    // A style that fails to load is reported by the map's loading failed
    // event, and a newer style cancels this one.
    load.ignore();
  }

  /// Submits the style load of [generation] with [submit], which makes the
  /// map call at once, so the load joins [_submittedStyleLoads] in the order
  /// the map runs it.
  Future<mln.CommandCompletion> _startStyleLoad(
    int generation,
    Future<mln.CommandCompletion> Function() submit,
  ) {
    _submittedStyleLoads.add(generation);
    final load = submit();
    load.then<void>(
      (_) {},
      onError: (Object error) {
        // A call that the C API rejected, or that never ran, starts no load.
        // A style that failed to parse started one, and its start may still
        // be on its way.
        if (error is! mln.MaplibreException ||
            error.status != mln.Status.nativeError) {
          _submittedStyleLoads.remove(generation);
        }
      },
    );
    return load;
  }

  @override
  Future<void> setTerrainLoadMode(TerrainLoadMode mode) async {
    await _map?.setTerrainOptions(
      mln.MapTerrainOptions(
        loadMode: switch (mode) {
          TerrainLoadMode.quality => mln.TerrainLoadMode.quality,
          TerrainLoadMode.balanced => mln.TerrainLoadMode.balanced,
          TerrainLoadMode.performance => mln.TerrainLoadMode.performance,
        },
      ),
    );
  }

  /// The terrain load mode that MapLibre Native uses for the map, read back
  /// from the map's state, or null before the map exists.
  @visibleForTesting
  TerrainLoadMode? get engineTerrainLoadMode =>
      switch (_map?.getSnapshot().terrain.loadMode) {
        mln.TerrainLoadMode.quality => TerrainLoadMode.quality,
        mln.TerrainLoadMode.balanced => TerrainLoadMode.balanced,
        mln.TerrainLoadMode.performance => TerrainLoadMode.performance,
        _ => null,
      };

  @override
  Future<double?> queryTerrainElevation(Geographic point) async {
    final elevation = await _queryFrame(
      (renderer) => renderer.queryTerrainElevation(point.toMln()),
    );
    return elevation?.meters;
  }

  @override
  Future<Geographic?> toLngLatOnTerrain(Offset screenLocation) async {
    final ground = await _queryFrame(
      (renderer) => renderer.queryLatLngForPixel(screenLocation.toMln()),
    );
    return ground?.coordinate.toGeographic();
  }

  @override
  Future<TerrainScreenLocation?> toScreenLocationOnTerrain(
    Geographic lngLat,
  ) async {
    final drawn = await _queryFrame(
      (renderer) => renderer.queryPixelForLatLng(lngLat.toMln()),
    );
    return drawn?.toTerrainScreenLocation();
  }

  @override
  Future<List<TerrainScreenLocation?>> toScreenLocationsOnTerrain(
    List<Geographic> lngLats,
  ) => queryConvertibleLngLats(lngLats, (points) async {
    // One query of one frame for every point, rather than one for each.
    final drawn = await _queryFrame(
      (renderer) => renderer.queryPixelsForLatLngs([
        for (final point in points) point.toMln(),
      ]),
    );
    if (drawn == null) return List.filled(points.length, null);
    return [for (final result in drawn) result.toTerrainScreenLocation()];
  });

  /// Runs [query] on the session's latest frame, or answers null without a
  /// frame to read.
  Future<T?> _queryFrame<T extends Object>(
    Future<T?> Function(MapRenderer renderer) query,
  ) async {
    final renderer = _renderer;
    if (renderer == null || _disposed) return null;
    try {
      return await query(renderer);
    } on mln.MaplibreException catch (error) {
      // The session has no frame to read yet: before its first frame, or
      // after its scale factor changed. No terrain is drawn then.
      if (error.status == mln.Status.invalidState) return null;
      rethrow;
    }
  }

  @override
  Future<List<RenderedFeature>> queryRenderedFeatures(
    QueryGeometry geometry, {
    List<String>? layerIds,
    Expression<bool>? filter,
  }) async {
    final renderer = _renderer;
    // No layers to query matches nothing, as on web.
    if (renderer == null ||
        _disposed ||
        (layerIds != null && layerIds.isEmpty)) {
      return const [];
    }
    final features = await renderer.queryRenderedFeatures(
      switch (geometry) {
        QueryGeometryPoint(:final point) => mln.RenderedQueryGeometry.point(
          point.toMln(),
        ),
        QueryGeometryRect(:final rect) => mln.RenderedQueryGeometry.box(
          rect.toMln(),
        ),
        QueryGeometryViewport() => mln.RenderedQueryGeometry.box(
          (Offset.zero &
                  Size(
                    renderer.extent.width.toDouble(),
                    renderer.extent.height.toDouble(),
                  ))
              .toMln(),
        ),
      },
      layerIds: layerIds,
      filter: filter?.toJson(),
    );
    return [
      for (final queried in features)
        if (queried.feature case final Map<String, Object?> feature)
          RenderedFeature(
            id: feature['id'],
            properties: _properties(feature),
            geometry: RenderedFeature.geometryFromJson(feature['geometry']),
            sourceId: _nonEmpty(queried.sourceId),
            sourceLayer: _nonEmpty(queried.sourceLayerId),
            layerId: _nonEmpty(queried.layerId),
          ),
    ];
  }
}

/// The properties of a GeoJSON [feature], or none.
Map<String, Object?> _properties(Map<String, Object?> feature) =>
    switch (feature['properties']) {
      final Map<String, Object?> properties => properties,
      _ => const {},
    };

/// [value], or null for the empty string that the C API reports as absent.
String? _nonEmpty(String value) => value.isEmpty ? null : value;

/// Applies gestures with the map's projection-aware camera deltas, which
/// move, scale, rotate and tilt around a screen point.
class _NativeGestureCamera implements GestureCameraSink {
  _NativeGestureCamera(this._state);

  final MapLibreMapStateNative _state;

  @override
  void gestureStart() {
    _state
      .._cancelAnimation()
      .._gestureActive = true
      .._nextChangeReason = CameraChangeReason.gesture
      .._anchorOnTerrain();
    _state._applyDelta(
      const mln.CameraDelta(gesturePhase: mln.GesturePhase.begin),
    );
  }

  @override
  void gestureUpdate(GestureCameraUpdate update) {
    final scales = update.zoomBy != 0;
    final rotates = update.rotateBy != 0;
    final tilts = update.pitchBy != 0;
    final pans = update.pans;
    final around = update.around;
    // One delta per step. With an anchor, the map grabs the ground under it
    // (over a terrain, at that ground's height) and keeps it there: a pan
    // moves the ground under the finger (`around` is where the step leaves
    // it), and a pinch scales and turns about where its focal point was,
    // then pans that ground to `around`.
    _state._applyDelta(
      mln.CameraDelta(
        offset: pans ? (update.panTo! - update.panFrom!).toMln() : null,
        scale: scales ? pow(2, update.zoomBy).toDouble() : null,
        bearing: rotates ? update.rotateBy : null,
        pitch: tilts ? update.pitchBy : null,
        // The C API rejects an anchor of a delta that changes nothing.
        anchor: around != null && (pans || scales || rotates || tilts)
            ? around.toMln()
            : null,
        gesturePhase: mln.GesturePhase.update,
      ),
    );
    _state._renderer?.expediteFrame();
  }

  /// Continues a flick as the map's own gesture momentum, which slows each
  /// of its pan, zoom and rotation on its own, and which the next gesture
  /// stops. The map ignores a release too slow to fling.
  @override
  void gestureEnd({GestureVelocity velocity = GestureVelocity.zero}) {
    if (!_state._gestureActive) return;
    _state._gestureActive = false;
    if (velocity.isZero) {
      _state
        .._applyDelta(const mln.CameraDelta(gesturePhase: mln.GesturePhase.end))
        .._onCameraIdle();
      return;
    }
    final anchor = velocity.around?.toMln();
    _state._applyDelta(
      mln.CameraDelta(
        gesturePhase: mln.GesturePhase.end,
        momentum: mln.GestureMomentum(
          pan: mln.PanMomentum(
            velocity: velocity.pan == Offset.zero ? null : velocity.pan.toMln(),
          ),
          zoom: mln.AnchoredMomentum(
            velocity: velocity.zoom == 0 ? null : velocity.zoom,
            anchor: anchor,
          ),
          bearing: mln.AnchoredMomentum(
            velocity: velocity.rotate == 0 ? null : velocity.rotate,
            anchor: anchor,
          ),
        ),
        // Ends the move once the momentum stops, at once when it doesn't
        // move, unless another gesture took over.
        animation: mln.AnimationOptions(
          endHandler: mln.CameraTransitionHandler(
            callback: (_) {
              if (!_state._gestureActive) _state._onCameraIdle();
            },
          ),
        ),
      ),
    );
  }

  /// Zooms around [around] in one anchored camera delta. Over a terrain the
  /// map keeps the ground at [around] in place, also while the clamp of
  /// [MapOptions.centerClampedToGround] moves the center onto the ground.
  @override
  void zoomBy(
    double levels,
    Offset around, {
    Duration duration = Duration.zero,
  }) {
    _state
      .._cancelAnimation()
      .._nextChangeReason = CameraChangeReason.gesture
      .._applyDelta(
        mln.CameraDelta(
          scale: pow(2, levels).toDouble(),
          anchor: around.toMln(),
          animation: duration == Duration.zero
              ? const mln.AnimationOptions()
              : mln.AnimationOptions(
                  durationMs: duration.inMilliseconds.toDouble(),
                ),
        ),
      );
    _state._renderer?.expediteFrame();
  }
}

/// A camera animation of [MapLibreMapStateNative.animateCamera].
class _CameraAnimationRun {
  _CameraAnimationRun(this.target);

  /// The camera that the animation ends at.
  final mln.CameraOptions target;

  /// Whether a gesture or [MapController.stopCamera] cancelled it, which the
  /// map may report as completed.
  bool cancelled = false;

  final _result = Completer<CameraAnimationResult>();

  Future<CameraAnimationResult> get result => _result.future;

  void end(CameraAnimationResult result) {
    if (_result.isCompleted) return;
    _result.complete(cancelled ? CameraAnimationResult.cancelled : result);
  }
}
