/// Conversions between the types of this plugin and those of gl-js:
/// `toJs()` converts to gl-js, `to<Type>()` converts back. Not exported
/// publicly.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:ui_web';

import 'package:flutter/widgets.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;
import 'package:maplibre_web/src/interop/json.dart';

/// Extension methods for the [Geographic] class.
extension GeographicExt on Geographic {
  /// This position in gl-js.
  interop.LngLat toJs() => interop.LngLat(lng: lon, lat: lat);
}

/// Extension methods for the [GeoBox] class.
extension GeoBoxExt on GeoBox {
  /// These bounds in gl-js.
  interop.LngLatBounds toJs() => interop.LngLatBounds(
    interop.LngLat(lng: west, lat: south),
    interop.LngLat(lng: east, lat: north),
  );
}

/// Extension methods for the [Offset] class.
extension OffsetExt on Offset {
  /// This screen location in gl-js.
  interop.Point toJs() => interop.Point(dx, dy);
}

/// Extension methods for the [interop.Point] class.
extension JsPointExt on interop.Point {
  /// This screen location as an [Offset].
  Offset toOffset() => Offset(x.toDouble(), y.toDouble());
}

/// Extension methods for the [EdgeInsets] class.
extension EdgeInsetsExt on EdgeInsets {
  /// This padding in gl-js, which takes logical pixels too.
  interop.PaddingOptions toJs() => interop.PaddingOptions(
    right: right,
    left: left,
    bottom: bottom,
    top: top,
  );
}

/// Extension methods for the [JSAny] class.
extension JsAnyExt on JSAny? {
  /// Like [JSAny?.dartify], but for the special case of a JSON map.
  Map<String, Object?>? asStringMap() =>
      (dartify() as Map<Object?, Object?>?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      ) ??
      {};
}

/// Converts a MapLibre GL JS `ResourceType`.
extension JsResourceTypeExt on String? {
  /// The [MapResourceKind] of this resource type.
  MapResourceKind toMapResourceKind() => switch (this) {
    'Style' => MapResourceKind.style,
    'Source' => MapResourceKind.source,
    'Tile' => MapResourceKind.tile,
    'Glyphs' => MapResourceKind.glyphs,
    'SpriteImage' => MapResourceKind.spriteImage,
    'SpriteJSON' => MapResourceKind.spriteJson,
    'Image' => MapResourceKind.image,
    _ => MapResourceKind.unknown,
  };
}

/// Extension methods for the [GeoJsonData] class.
extension GeoJsonDataExt on GeoJsonData {
  /// This data as a JS object. The browser parses text faster than Dart.
  JSAny toJs() => switch (this) {
    GeoJsonDataJson(:final json) => json.jsify()!,
    _ => parse(toText()),
  };
}

/// Extension methods for the [StyleImageOptions] class.
extension StyleImageOptionsExt on StyleImageOptions {
  /// These options as the metadata of `addImage` for an image of
  /// [pixelRatio].
  interop.StyleImageMetadata toJs(double pixelRatio) =>
      {
            'pixelRatio': pixelRatio,
            'sdf': sdf,
            if (stretchX.isNotEmpty)
              'stretchX': [
                for (final (from, to) in stretchX) [from, to],
              ],
            if (stretchY.isNotEmpty)
              'stretchY': [
                for (final (from, to) in stretchY) [from, to],
              ],
            if (content case final content?)
              'content': [
                content.left,
                content.top,
                content.right,
                content.bottom,
              ],
            'textFitWidth': ?textFitWidth?.name,
            'textFitHeight': ?textFitHeight?.name,
          }.jsify()!
          as interop.StyleImageMetadata;
}

/// Extension methods for the [interop.PaddingOptions] class.
extension JsPaddingOptionsExt on interop.PaddingOptions {
  /// This padding as [EdgeInsets].
  EdgeInsets toEdgeInsets() => EdgeInsets.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// Extension methods for the [interop.GeoJSONFeature] class.
extension JsGeoJSONFeatureExt on interop.GeoJSONFeature {
  /// This feature as a [SourceFeature] of [sourceLayer].
  SourceFeature toSourceFeature({String? sourceLayer}) => SourceFeature(
    id: id.dartify(),
    properties: properties.asStringMap() ?? {},
    geometry: RenderedFeature.geometryFromJson(geometry.dartify()),
    sourceLayer: sourceLayer,
  );
}

/// Extension methods for the [interop.MapGeoJSONFeature] class.
extension JsMapGeoJSONFeatureExt on interop.MapGeoJSONFeature {
  /// This feature as a [RenderedFeature].
  RenderedFeature toRenderedFeature() => RenderedFeature(
    id: id.dartify(),
    properties: properties.asStringMap() ?? {},
    geometry: RenderedFeature.geometryFromJson(geometry.dartify()),
    sourceId: source,
    sourceLayer: sourceLayer,
    layerId: layer.id,
  );
}

/// Extension methods for the [interop.LngLat] class.
extension JsLngLatExt on interop.LngLat {
  /// This position as a [Geographic].
  Geographic toGeographic() =>
      Geographic(lon: lng.toDouble(), lat: lat.toDouble());
}

/// Extension methods for the [MapStyle] class.
extension MapStyleExt on MapStyle {
  /// This style as gl-js takes it: a style object or the URL of one.
  ///
  /// Throws a [FormatException] for JSON text that doesn't parse.
  JSAny toJs() => switch (this) {
    MapStyleJson(:final json) =>
      (jsonDecode(json) as Map<String, dynamic>).jsify() ??
          (throw StateError('Failed to convert style JSON to JS object.')),
    MapStyleUrl() || MapStyleAsset() => jsUrl!.toJS,
    MapStyleFile() => throw UnsupportedError(
      'MapStyle.file is not supported on web, use MapStyle.url or '
      'MapStyle.asset.',
    ),
  };

  /// The URL that gl-js loads this style from, or null for JSON text.
  String? get jsUrl => switch (this) {
    MapStyleUrl(:final url) => url,
    MapStyleAsset(:final asset) => AssetManager().getAssetUrl(asset),
    MapStyleJson() || MapStyleFile() => null,
  };
}

/// Extension methods for the [CameraUpdatePosition] class.
extension CameraUpdatePositionExt on CameraUpdatePosition {
  /// The gl-js camera options that move [map] here, with only the fields
  /// that change.
  JSObject toJs(interop.JsMap map) {
    final options = JSObject();
    if (center case final center?) options['center'] = center.toJs();
    if (zoom case final zoom?) options['zoom'] = zoom.toJS;
    if (bearing case final bearing?) options['bearing'] = bearing.toJS;
    if (pitch case final pitch?) options['pitch'] = pitch.toJS;
    if (roll case final roll?) options['roll'] = roll.toJS;
    if (padding case final padding?) options['padding'] = padding.toJs();
    if (anchor case final anchor?) {
      options['around'] = map.unproject(anchor.toJs());
    }
    return options;
  }
}

/// Extension methods for the [CameraUpdateFit] class.
extension CameraUpdateFitExt on CameraUpdateFit {
  /// The gl-js camera options that fit [map] to these bounds, or null if
  /// they don't fit it. gl-js fits them into the padding of earlier camera
  /// moves as well.
  JSObject? toJs(interop.JsMap map) {
    final pitch = this.pitch ?? map.getPitch();
    final camera = map.cameraForBounds(
      bounds.toJs(),
      interop.FitBoundsOptions(
        padding: padding.toJs(),
        bearing: bearing ?? map.getBearing(),
        pitch: pitch,
        // An explicit null would reach gl-js as a max zoom of 0.
        maxZoom: maxZoom ?? double.maxFinite,
      ),
    );
    if (camera == null) return null;
    return JSObject()
      ..['center'] = camera.center
      ..['zoom'] = camera.zoom.toJS
      ..['bearing'] = camera.bearing.toJS
      ..['pitch'] = (camera.pitch ?? pitch).toJS;
  }
}

/// Extension methods for the [CameraUpdateEye] class.
extension CameraUpdateEyeExt on CameraUpdateEye {
  /// The gl-js camera options that put the camera of [map] at the eye,
  /// [altitude] meters above sea level: `center`, `elevation`, `zoom`,
  /// `bearing` and `pitch`.
  ///
  /// The pitch is limited to the map's, with the eye kept in place. Where
  /// gl-js puts the center so near or far that the zoom leaves the map's
  /// range, which would move the camera, the center moves along the view to
  /// a distance in range.
  JSObject toJs(interop.JsMap map, {required double altitude}) {
    final pitch = this.pitch.clamp(
      map.getMinPitch().toDouble(),
      map.getMaxPitch().toDouble(),
    );
    final lngLat = eye.toJs();
    var camera = map.calculateCameraOptionsFromCameraLngLatAltRotation(
      lngLat,
      altitude,
      bearing,
      pitch,
    );
    double zoomOf(JSObject camera) =>
        (camera['zoom']! as JSNumber).toDartDouble;
    final zoom = zoomOf(camera);
    final minZoom = map.getMinZoom().toDouble();
    final maxZoom = map.getMaxZoom().toDouble();
    if (zoom.isFinite && zoom >= minZoom && zoom <= maxZoom) {
      return camera
        ..['bearing'] = bearing.toJS
        ..['pitch'] = pitch.toJS;
    }
    // The zoom falls off by one level for each doubling of the distance from
    // the camera to the center.
    JSObject lookingAt(double distance) {
      final pitchRad = pitch * degree2Radian;
      final bearingRad = bearing * degree2Radian;
      final ahead = distance * sin(pitchRad);
      final target = Geographic(
        lon:
            eye.lon +
            ahead *
                sin(bearingRad) /
                (_earthRadius * cos(eye.lat * degree2Radian)) /
                degree2Radian,
        lat: eye.lat + ahead * cos(bearingRad) / _earthRadius / degree2Radian,
      );
      return map.calculateCameraOptionsFromTo(
        lngLat,
        altitude,
        target.toJs(),
        altitude - distance * cos(pitchRad),
      );
    }

    const probe = 1000.0;
    final probeZoom = zoomOf(lookingAt(probe));
    final targetZoom = zoom.isFinite ? zoom.clamp(minZoom, maxZoom) : maxZoom;
    camera = lookingAt(probe * pow(2, probeZoom - targetZoom));
    // gl-js works out the bearing and pitch from the two points, which is
    // undefined straight down.
    return camera
      ..['bearing'] = bearing.toJS
      ..['pitch'] = pitch.toJS;
  }
}

/// Extension methods for the [interop.JsMap] class.
extension JsMapExt on interop.JsMap {
  /// Where the camera is: its eye, and the eye's height in meters above sea
  /// level, worked out as gl-js places the camera behind its center.
  ({Geographic eye, double altitude}) cameraEye() {
    final center = getCenter().toGeographic();
    final pitch = getPitch() * degree2Radian;
    final bearing = getBearing() * degree2Radian;
    final fov = getVerticalFieldOfView() * degree2Radian;
    final height = getCanvas().clientHeight;
    final latitude = center.lat * degree2Radian;
    // gl-js's cameraToCenterDistance in pixels, over its world size, in
    // meters at the center.
    final distance =
        0.5 *
        height /
        tan(fov / 2) /
        (512 * pow(2, getZoom())) *
        2 *
        pi *
        _earthRadius *
        cos(latitude);
    final behind = distance * sin(pitch);
    return (
      eye: Geographic(
        lon:
            center.lon -
            behind *
                sin(bearing) /
                (_earthRadius * cos(latitude)) /
                degree2Radian,
        lat: center.lat - behind * cos(bearing) / _earthRadius / degree2Radian,
      ),
      altitude: getCenterElevation() + distance * cos(pitch),
    );
  }
}

/// The radius of the earth in meters that gl-js's Mercator coordinates use.
const _earthRadius = 6371008.8;
