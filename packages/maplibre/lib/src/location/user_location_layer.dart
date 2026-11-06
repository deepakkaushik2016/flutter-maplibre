import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre/src/location/user_location_geometry.dart';

/// Shows the user location on the [MapLibreMap] by using it in
/// [MapLibreMap.children], and moves the camera with it while [tracking].
///
/// The map draws the location itself, in its style, so it stays on the
/// ground of a 3D terrain at every pitch, and the camera moves it without
/// any work in Dart:
///
/// - the circle of the location's [UserLocation.accuracy], draped on the
///   ground;
/// - a cone towards its [UserLocation.heading], which fades from the dot
///   out. It lies flat at the height of the ground under the dot, turned
///   from north whatever the map's bearing, and keeps its length on screen
///   at every zoom;
/// - the dot, which faces the screen at the height of the ground, so it
///   stays round when the map is tilted. MapLibre Native draws it over the
///   terrain; on web, maplibre-gl-js fades it where nearer ground hides it.
///
/// The layer adds a GeoJSON source, [sourceId], and three style layers:
/// [accuracyLayerId], [headingLayerId] and [dotLayerId], from bottom to top.
/// A second layer on the same map adds `-2` to each ID, and so on. They go
/// below [belowLayerId], or else below the style's first symbol layer, so
/// the location shows over roads and trails but under labels. Once a new
/// style has loaded, the layer adds them to it again.
///
/// Each new location updates the source, but only if it moved, its
/// accuracy changed or it turned by 1° or more, at most 30 times a second
/// and one update at a time; camera moves update nothing. A heading that is
/// not a number counts as unknown. While tracking, the camera follows at
/// most 30 times a second too.
///
/// The layer takes its locations from a stream, so it works the same on
/// every platform and with any location source. It asks for no permission;
/// use a package such as `permission_handler` or `geolocator` for that, and
/// `maplibre_geolocator` to turn `geolocator` positions into locations.
///
/// A drag or scroll wheel zoom on the map stops the tracking and reports
/// [UserLocationTracking.none] to [onTrackingChanged].
///
/// {@category Location}
class UserLocationLayer extends StatefulWidget {
  /// Creates a layer that shows the latest of [locations].
  const UserLocationLayer({
    required this.locations,
    this.tracking = UserLocationTracking.none,
    this.onTrackingChanged,
    this.trackingZoom,
    this.trackingDuration = const Duration(milliseconds: 500),
    this.color = const Color(0xFF1A73E8),
    this.radius = 8,
    this.style = const UserLocationStyle(),
    this.belowLayerId,
    super.key,
  });

  /// The ID of the GeoJSON source of the first user location layer of a map.
  static const sourceId = 'maplibre-user-location';

  /// The ID of the style layer of the accuracy circle, a fill layer.
  static const accuracyLayerId = '$sourceId-accuracy';

  /// The ID of the style layer of the heading cone, a symbol layer. It is
  /// added once the cone's image is in the style.
  static const headingLayerId = '$sourceId-heading';

  /// The ID of the style layer of the dot, a circle layer.
  static const dotLayerId = '$sourceId-dot';

  /// The shortest time between two updates of the source: 30 a second.
  static const updateInterval = Duration(microseconds: 33334);

  /// The locations of the user. The layer shows the latest one.
  final Stream<UserLocation> locations;

  /// How the camera moves with the user location.
  final UserLocationTracking tracking;

  /// Called when the tracking changes because the user moved the map.
  final ValueChanged<UserLocationTracking>? onTrackingChanged;

  /// The zoom the camera moves to when the tracking starts, or null to keep
  /// the zoom.
  final double? trackingZoom;

  /// How long the camera takes to follow a new location.
  final Duration trackingDuration;

  /// The color of the location dot, and of its accuracy circle and heading
  /// cone unless [style] sets theirs.
  final Color color;

  /// The radius of the location dot in logical pixels.
  final double radius;

  /// How the outline of the dot, the accuracy circle and the heading cone
  /// look.
  final UserLocationStyle style;

  /// The ID of the style layer that the location goes below. If null, or if
  /// the style has no such layer, the location goes below the style's first
  /// symbol layer, or on top if it has none.
  final String? belowLayerId;

  @override
  State<UserLocationLayer> createState() => _UserLocationLayerState();
}

class _UserLocationLayerState extends State<UserLocationLayer> {
  StreamSubscription<UserLocation>? _subscription;
  UserLocation? _location;
  late UserLocationTracking _tracking = widget.tracking;

  /// Whether the camera has moved to the location since the tracking
  /// started, so [UserLocationLayer.trackingZoom] applies only once.
  var _tracked = false;

  /// The location the camera last moved to.
  UserLocation? _followed;

  /// Where each pointer on the map went down, to tell a drag from a tap.
  final _downPositions = <int, Offset>{};

  MapController? _controller;

  /// The style that has the source and layers, or null.
  StyleController? _style;

  /// The ID of the source in [_style].
  String? _sourceId;

  /// The location that the source shows.
  UserLocation? _shown;

  /// Runs while updates wait for [UserLocationLayer.updateInterval] to pass
  /// since the last one.
  Timer? _cooldown;

  /// Whether a location arrived during [_cooldown] or [_updating] that the
  /// source should show.
  var _pending = false;

  /// Whether a source update is on its way to the map. The next waits for
  /// it, so a slow map gets the latest location rather than a queue.
  var _updating = false;

  /// The style the app had set when the source was added. While the app's
  /// style differs, the map is loading a new one: it still hands out
  /// [_style] but drops its sources, so a failed call is not reported.
  MapStyle? _mapStyle;

  /// Runs while camera moves wait for [UserLocationLayer.updateInterval] to
  /// pass since the last one.
  Timer? _followCooldown;

  /// Whether a location arrived during [_followCooldown] that the camera
  /// should move to.
  var _followPending = false;

  /// The image of the heading cone in [_style], or null.
  String? _coneImage;

  /// Counts the cone images, so each has its own ID: gl-js can't replace
  /// an image in place.
  var _coneImages = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuilds only for a new controller or style, not with the camera.
    final controller = MapController.maybeOf(context, camera: false);
    _controller = controller;
    final style = controller?.style;
    if (identical(style, _style)) return;
    // The source and layers went with the old style.
    _detach(removeFromStyle: false);
    if (style != null) _attach(style);
  }

  @override
  void didUpdateWidget(UserLocationLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.locations != oldWidget.locations) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
    if (widget.tracking != oldWidget.tracking) {
      _tracking = widget.tracking;
      _tracked = false;
      _follow();
    }
    if (widget.color != oldWidget.color ||
        widget.radius != oldWidget.radius ||
        widget.style != oldWidget.style ||
        widget.belowLayerId != oldWidget.belowLayerId) {
      _restyle(oldWidget);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _followCooldown?.cancel();
    _detach(removeFromStyle: true);
    super.dispose();
  }

  void _subscribe() {
    _subscription = widget.locations.listen((location) {
      if (!mounted) return;
      _location = location;
      if (_differs(_shown, location)) _requestUpdate();
      if (_differs(_followed, location)) _requestFollow();
    });
  }

  /// Whether [location] looks different from [old]: it moved, its accuracy
  /// changed, or its heading appeared, went, or turned by 1° or more.
  static bool _differs(UserLocation? old, UserLocation location) {
    if (old == null) return true;
    if (old.position != location.position ||
        old.accuracy != location.accuracy) {
      return true;
    }
    final (a, b) = (_headingOf(old), _headingOf(location));
    if (a == null || b == null) return (a == null) != (b == null);
    return headingDifference(a, b) >= 1;
  }

  /// The heading of [location], or null if it is unknown or not a number.
  static double? _headingOf(UserLocation location) =>
      switch (location.heading) {
        final heading? when heading.isFinite => heading,
        _ => null,
      };

  // The source and layers in the style.

  void _attach(StyleController style) {
    _style = style;
    var id = UserLocationLayer.sourceId;
    for (var n = 2; style.sources[id] != null; n++) {
      id = '${UserLocationLayer.sourceId}-$n';
    }
    _sourceId = id;
    _shown = _location;
    _mapStyle = _controller?.options.style;
    final data = _data();
    style.batch(() {
      _run(
        style,
        style.sources.add(
          // Simplifying the few vertices would save nothing; tiles up to
          // zoom 22 keep the accuracy circle round when zoomed in.
          GeoJsonSource.data(id: id, data: data, maxZoom: 22, tolerance: 0),
        ),
      );
      _addLayers(style, id);
    });
  }

  /// Adds the accuracy and dot layers, and the cone's once its image is in
  /// the style.
  void _addLayers(StyleController style, String id) {
    final below = _belowLayerId(style, id);
    _run(style, style.layers.add(_accuracyLayer(id), belowLayerId: below));
    _run(style, style.layers.add(_dotLayer(id), belowLayerId: below));
    if (widget.style.showHeading) unawaited(_addCone(style, id));
  }

  /// Draws the image of the heading cone into [style], and then adds its
  /// layer below the dot's.
  Future<void> _addCone(StyleController style, String id) async {
    final image = '$id-heading-${++_coneImages}';
    final appearance = widget.style;
    final length = appearance.headingLength;
    final call = style.addImageFromCanvas(
      id: image,
      width: 2 * length,
      height: 2 * length,
      painter: (canvas) => paintCone(
        canvas,
        length: length,
        halfAngle: appearance.headingHalfAngle,
        color: appearance.headingColor ?? widget.color,
        opacity: appearance.headingOpacity,
      ),
    );
    _run(style, call);
    try {
      await call;
    } on Object {
      return;
    }
    if (!mounted ||
        !identical(_style, style) ||
        image != '$id-heading-$_coneImages') {
      // Replaced or gone meanwhile: take the image out of a style that the
      // map still shows.
      if (identical(_controller?.style, style)) {
        unawaited(style.removeImage(image).catchError((Object _) {}));
      }
      return;
    }
    final old = _coneImage;
    _coneImage = image;
    style.batch(() {
      if (style.layers['$id-heading'] != null) {
        _run(style, style.layers.remove('$id-heading'));
      }
      _run(
        style,
        style.layers.add(_coneLayer(id, image), belowLayerId: '$id-dot'),
      );
      if (old != null) _run(style, style.removeImage(old));
    });
  }

  /// Forgets the style, and removes the source and layers from it if
  /// [removeFromStyle] and the map still has it.
  void _detach({required bool removeFromStyle}) {
    _cooldown?.cancel();
    _cooldown = null;
    _pending = false;
    _updating = false;
    final style = _style;
    final id = _sourceId;
    final image = _coneImage;
    _style = null;
    _sourceId = null;
    _coneImage = null;
    if (!removeFromStyle || style == null || id == null) return;
    if (!identical(_controller?.style, style)) return;
    style.batch(() {
      _removeLayers(style, id);
      _run(style, style.sources.remove(id));
      if (image != null) _run(style, style.removeImage(image));
    });
  }

  void _removeLayers(StyleController style, String id) {
    for (final layerId in _layerIds(id)) {
      if (style.layers[layerId] != null) {
        _run(style, style.layers.remove(layerId));
      }
    }
  }

  /// Applies new colors, sizes or a new position of the layers.
  void _restyle(UserLocationLayer oldWidget) {
    final style = _style;
    final id = _sourceId;
    if (style == null || id == null) return;
    final image = _coneImage;
    _coneImage = null;
    style.batch(() {
      _removeLayers(style, id);
      if (image != null) _run(style, style.removeImage(image));
      _addLayers(style, id);
    });
    if (oldWidget.style.showAccuracy != widget.style.showAccuracy ||
        oldWidget.style.showHeading != widget.style.showHeading) {
      _update();
    }
  }

  /// Reports a failed style call, unless the style went away meanwhile or
  /// the map is replacing it.
  void _run(StyleController style, Future<void> call) {
    unawaited(
      call.catchError((Object error, StackTrace stackTrace) {
        if (!mounted || !identical(_style, style) || _replacing(style)) return;
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'maplibre',
            context: ErrorDescription('while showing the user location'),
          ),
        );
      }),
    );
  }

  /// Whether the map is replacing [style] with a new one: the app set
  /// another style, or the style dropped the source. Until the new style
  /// has loaded, the map keeps handing out the old one, which takes a
  /// terrain for the new one (see [StyleController.setTerrain]), and the
  /// layer adds itself to the new one with the latest location then.
  bool _replacing(StyleController style) {
    final id = _sourceId;
    return id == null ||
        style.sources[id] == null ||
        _controller?.options.style != _mapStyle;
  }

  /// Updates the source now, or once [UserLocationLayer.updateInterval] has
  /// passed since the last update and the map took it.
  void _requestUpdate() {
    if (_sourceId == null) return;
    _pending = true;
    _flush();
  }

  /// Sends the pending location, unless an update is too recent or on its
  /// way.
  void _flush() {
    if (_cooldown != null || _updating || !_pending) return;
    _pending = false;
    final location = _location;
    if (location != null && _differs(_shown, location)) _update();
  }

  void _update() {
    final style = _style;
    final id = _sourceId;
    if (style == null || id == null) return;
    // A style that dropped the source is on its way out; the next one gets
    // the latest location.
    if (style.sources[id] == null) return;
    _shown = _location;
    _updating = true;
    final call = style.sources.updateGeoJsonData(id, _data());
    _run(style, call);
    unawaited(
      call
          .then((_) {
            // The style stayed after all, as for a style that maplibre-gl-js
            // found unchanged.
            if (identical(_style, style)) {
              _mapStyle = _controller?.options.style;
            }
          }, onError: (Object _) {})
          .whenComplete(() {
            if (!identical(_style, style)) return;
            _updating = false;
            _flush();
          }),
    );
    _cooldown?.cancel();
    _cooldown = Timer(UserLocationLayer.updateInterval, () {
      _cooldown = null;
      _flush();
    });
  }

  GeoJsonData _data() {
    final location = _location;
    if (location == null) {
      return const GeoJsonData.text(
        '{"type":"FeatureCollection","features":[]}',
      );
    }
    final style = widget.style;
    return GeoJsonData.text(
      userLocationGeoJson(
        location,
        showAccuracy: style.showAccuracy,
        showHeading: style.showHeading,
      ),
    );
  }

  static List<String> _layerIds(String id) => [
    '$id-accuracy',
    '$id-heading',
    '$id-dot',
  ];

  String? _belowLayerId(StyleController style, String id) {
    final requested = widget.belowLayerId;
    if (requested != null && style.layers[requested] != null) return requested;
    final own = _layerIds(id).toSet();
    for (final layer in style.layers) {
      if (layer.type == 'symbol' && !own.contains(layer.id)) return layer.id;
    }
    return null;
  }

  static Object _kind(String kind) => [
    '==',
    ['get', 'k'],
    kind,
  ];

  StyleLayer _accuracyLayer(String id) {
    final style = widget.style;
    final color = style.accuracyColor ?? widget.color;
    return StyleLayer.fromJson({
      'id': '$id-accuracy',
      'type': 'fill',
      'source': id,
      'filter': _kind('accuracy'),
      'paint': {
        // The alpha is in the colors, so that the outline's can be higher.
        'fill-color': _css(color, style.accuracyOpacity),
        'fill-outline-color': _css(color, style.accuracyOutlineOpacity),
      },
    });
  }

  static StyleLayer _coneLayer(String id, String image) => StyleLayer.fromJson({
    'id': '$id-heading',
    'type': 'symbol',
    'source': id,
    'filter': _kind('heading'),
    'layout': {
      'icon-image': image,
      // Turned from north on the ground, whatever the map's bearing and
      // pitch.
      'icon-rotate': ['get', 'h'],
      'icon-rotation-alignment': 'map',
      'icon-pitch-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  });

  StyleLayer _dotLayer(String id) {
    final style = widget.style;
    return StyleLayer.fromJson({
      'id': '$id-dot',
      'type': 'circle',
      'source': id,
      'filter': _kind('dot'),
      'paint': {
        'circle-radius': widget.radius,
        'circle-color': _css(widget.color, 1),
        'circle-stroke-color': _css(style.strokeColor, 1),
        'circle-stroke-width': style.strokeWidth,
        // Faces the screen, so it stays round when the map is tilted.
        'circle-pitch-alignment': 'viewport',
        'circle-pitch-scale': 'viewport',
      },
    });
  }

  static String _css(Color color, double opacity) =>
      Literal<Color>(color.withValues(alpha: (color.a * opacity).clamp(0, 1)))
              .toJson()!
          as String;

  // Tracking

  /// Moves the camera to the latest location now, or once
  /// [UserLocationLayer.updateInterval] has passed since the last move.
  void _requestFollow() {
    if (_followCooldown != null) {
      _followPending = true;
      return;
    }
    _follow();
    _followCooldown = Timer(UserLocationLayer.updateInterval, () {
      _followCooldown = null;
      final location = _location;
      if (_followPending && location != null && _differs(_followed, location)) {
        _requestFollow();
      }
      _followPending = false;
    });
  }

  /// Moves the camera to the latest location while tracking.
  void _follow() {
    final location = _location;
    final controller = _controller;
    if (location == null ||
        controller == null ||
        _tracking == UserLocationTracking.none) {
      return;
    }
    _followed = location;
    final zoom = _tracked ? null : widget.trackingZoom;
    _tracked = true;
    unawaited(
      controller.animateCamera(
        CameraUpdate.position(
          center: location.position,
          zoom: zoom,
          bearing: _tracking == UserLocationTracking.positionAndHeading
              ? _headingOf(location)
              : null,
        ),
        animation: CameraAnimation.fly(duration: widget.trackingDuration),
      ),
    );
  }

  void _stopTracking() {
    if (_tracking == UserLocationTracking.none) return;
    _tracking = UserLocationTracking.none;
    widget.onTrackingChanged?.call(UserLocationTracking.none);
  }

  void _onPointerDown(PointerDownEvent event) =>
      _downPositions[event.pointer] = event.localPosition;

  void _onPointerMove(PointerMoveEvent event) {
    final down = _downPositions[event.pointer];
    if (down == null) return;
    if ((event.localPosition - down).distance > kTouchSlop) _stopTracking();
  }

  void _onPointerEnd(PointerEvent event) =>
      _downPositions.remove(event.pointer);

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent || event is PointerScaleEvent) {
      _stopTracking();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Translucent, so the map behind still gets every pointer.
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        onPointerSignal: _onPointerSignal,
      ),
    );
  }
}

/// Paints the heading cone, pointing up from the center of a square
/// 2 [length] wide: [opacity] at the apex, fading to nothing at [length].
@visibleForTesting
void paintCone(
  Canvas canvas, {
  required double length,
  required double halfAngle,
  required Color color,
  required double opacity,
}) {
  final center = Offset(length, length);
  final half = halfAngle.clamp(0.5, 180) * pi / 180;
  final bounds = Rect.fromCircle(center: center, radius: length);
  final cone = Path()
    ..moveTo(center.dx, center.dy)
    ..arcTo(bounds, -pi / 2 - half, 2 * half, false)
    ..close();
  final apex = color.withValues(alpha: color.a * opacity.clamp(0, 1));
  canvas.drawPath(
    cone,
    Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: [
          apex,
          apex.withValues(alpha: apex.a * 0.45),
          apex.withValues(alpha: 0),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(bounds),
  );
}
