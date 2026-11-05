import 'package:flutter/widgets.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_platform_interface/src/widget/inherited_model.dart';

/// The [MapController] can be used to control, update and manipulate a
/// rendered [MapLibreMap].
///
/// {@category Basic}
abstract interface class MapController {
  /// Find the [MapController] of the closest [MapLibreMap] in the widget tree.
  /// Returns null if called outside of the [MapLibreMap.children].
  static MapController? maybeOf(BuildContext context) =>
      MapLibreInheritedModel.maybeMapControllerOf(context);

  /// Find the [MapController] of the closest [MapLibreMap] in the widget tree.
  /// Throws an [StateError] if called outside of the [MapLibreMap.children].
  static MapController of(BuildContext context) =>
      maybeOf(context) ??
      (throw StateError('Unable to find an instance of MapController'));

  /// Get the [MapOptions] from [MapLibreMap.options].
  MapOptions get options;

  /// Get the [StyleController] for the map. It returns null null if
  /// accessed before [MapLibreMap.onStyleLoaded] has been called.
  StyleController? get style;

  /// Convert a latitude/longitude coordinate to a screen location in logical
  /// pixels.
  ///
  /// It answers at once, from the projection of the frame on screen. Over a
  /// terrain, on native it resolves at sea level, not on the ground the map
  /// draws: over high ground it can be kilometres off. Use
  /// [toScreenLocationOnTerrain] for the ground. On web it follows the terrain.
  Offset toScreenLocation(Geographic lngLat);

  /// Get the latitude/longitude coordinate for a screen location in logical
  /// pixels.
  ///
  /// It answers at once, from the projection of the frame on screen. Over a
  /// terrain, on native it resolves at sea level, not on the ground the map
  /// draws: over high ground it can be kilometres off. Use
  /// [toLngLatOnTerrain] for the ground. On web it follows the terrain.
  Geographic toLngLat(Offset screenLocation);

  /// Convert a latitude/longitude coordinate to a screen location in logical
  /// pixels. Over a terrain, on native these are at sea level, as with
  /// [toScreenLocation].
  List<Offset> toScreenLocations(List<Geographic> lngLats);

  /// Get the latitude/longitude coordinate for a screen location in logical
  /// pixels. Over a terrain, on native these are at sea level, as with
  /// [toLngLat].
  List<Geographic> toLngLats(List<Offset> screenLocations);

  /// Finds the ground that the map draws at [screenLocation], in logical
  /// pixels, following the line of sight to the first ground of the terrain.
  ///
  /// [toLngLat] answers at once, but on native it projects onto sea level,
  /// also over a terrain, so over high ground it finds a point behind the
  /// one drawn there. Use this where the ground matters, such as for the
  /// point an app's tap hit over mountains.
  ///
  /// Without a terrain in the style, this is the point that [toLngLat]
  /// finds. Returns null where the line of sight meets no ground of a loaded
  /// DEM tile: above the horizon, beyond the terrain's tiles, and while they
  /// load. Also null before the map has drawn its first frame.
  ///
  /// Each call is one query of the map's latest frame on native, or a few
  /// calls into maplibre-gl-js on web.
  Future<Geographic?> toLngLatOnTerrain(Offset screenLocation);

  /// Finds where the map draws [lngLat] on the ground, at the height the
  /// terrain draws there, and whether nearer ground hides it.
  ///
  /// [toScreenLocation] answers at once, but on native it projects from sea
  /// level, also over a terrain. Use this to place a widget on the ground it
  /// marks, or to hide it behind a ridge.
  ///
  /// Without a terrain in the style, the offset is the one that
  /// [toScreenLocation] finds, and [TerrainScreenLocation.occluded] is false.
  /// Returns null where no DEM tile that the map has loaded covers [lngLat],
  /// for a point behind the camera on native, and before the map has drawn
  /// its first frame.
  ///
  /// On web, maplibre-gl-js has no public occlusion test, so a point counts
  /// as hidden when the ground drawn at its screen location is higher than
  /// the point: a line of sight that comes down onto the ground meets the
  /// higher ground first.
  ///
  /// Each call is one query of the map's latest frame on native, or a few
  /// calls into maplibre-gl-js on web.
  Future<TerrainScreenLocation?> toScreenLocationOnTerrain(Geographic lngLat);

  /// Moves the camera to [update] without an animation.
  ///
  /// It stops a running [animateCamera].
  Future<void> moveCamera(CameraUpdate update);

  /// Animates the camera to [update], see [CameraAnimation] for the kinds of
  /// animation.
  ///
  /// The returned future completes when the animation ends, with
  /// [CameraAnimationResult.cancelled] if a gesture, [stopCamera] or
  /// [moveCamera] stopped it.
  ///
  /// ```dart
  /// final result = await controller.animateCamera(
  ///   const CameraUpdate.position(center: munich, zoom: 12),
  ///   animation: const CameraAnimation.fly(),
  /// );
  /// ```
  Future<CameraAnimationResult> animateCamera(
    CameraUpdate update, {
    CameraAnimation animation = const CameraAnimation.ease(),
  });

  /// Stops a running [animateCamera], whose future then completes with
  /// [CameraAnimationResult.cancelled].
  Future<void> stopCamera();

  /// The camera that [update] would move the map to, without moving it.
  ///
  /// [CameraUpdatePosition.anchor] is not taken into account: the camera
  /// keeps the center of [update], or the current one.
  Future<CameraPosition> cameraFor(CameraUpdate update);

  /// Get the current camera position on the map.
  CameraPosition getCamera();

  /// Get the current camera position on the map.
  CameraPosition? get camera;

  /// Whether the map stopped rendering, because [MapLibreMap.paused] is set
  /// or the map is hidden. See [MapLibreMap.paused].
  bool get isRenderingPaused;

  /// Returns the distance spanned by one logical pixel at the specified
  /// latitude and current zoom level.
  ///
  /// The distance between pixels decreases as the latitude approaches the
  /// poles. This relationship parallels the relationship between longitudinal
  /// coordinates at different latitudes.
  double getMetersPerPixelAtLatitude(double latitude);

  /// The smallest bounding box that includes the visible part of the map.
  ///
  /// With a bearing or pitch, the visible part is not an axis-aligned
  /// rectangle, and the box is larger than it.
  GeoBox getVisibleBounds();

  /// The features that the map draws in [geometry], topmost first.
  ///
  /// If [layerIds] is non-null, only features from those layers are
  /// returned; an empty list returns none. If [filter] is non-null, only
  /// features for which it is true are returned.
  ///
  /// A feature can appear more than once, for example if it crosses tile
  /// boundaries or more than one layer draws it.
  ///
  /// Returns an empty list if the map has been disposed.
  Future<List<RenderedFeature>> queryRenderedFeatures(
    QueryGeometry geometry, {
    List<String>? layerIds,
    Expression<bool>? filter,
  });

  /// The features of the source [sourceId] in the tiles that it loaded,
  /// including features that are hidden or outside the visible part of the
  /// map, but only while a visible layer uses the source.
  ///
  /// For a vector tile source, [sourceLayer] names the source layer to
  /// query, and is required. If [filter] is non-null, only features for which
  /// it is true are returned.
  ///
  /// A feature can appear more than once, for example if it crosses tile
  /// boundaries.
  ///
  /// Returns an empty list if the map has been disposed.
  Future<List<SourceFeature>> querySourceFeatures(
    String sourceId, {
    String? sourceLayer,
    Expression<bool>? filter,
  });

  /// The zoom level at which the cluster [clusterId] of the GeoJSON source
  /// [sourceId] breaks up into its children.
  ///
  /// [clusterId] is the `cluster_id` property of a cluster feature, see
  /// [GeoJsonCluster].
  Future<double> getClusterExpansionZoom(String sourceId, int clusterId);

  /// The clusters and points one zoom level below the cluster [clusterId] of
  /// the GeoJSON source [sourceId].
  ///
  /// Returns an empty list if the map has been disposed.
  Future<List<SourceFeature>> getClusterChildren(
    String sourceId,
    int clusterId,
  );

  /// The points of the cluster [clusterId] of the GeoJSON source [sourceId],
  /// [limit] of them after skipping [offset].
  ///
  /// Returns an empty list if the map has been disposed.
  Future<List<SourceFeature>> getClusterLeaves(
    String sourceId,
    int clusterId, {
    int limit = 10,
    int offset = 0,
  });

  /// Sets how the map trades the detail of the terrain for loading speed.
  /// The default is [TerrainLoadMode.quality].
  ///
  /// It applies to every style of the map. maplibre-gl-js has no load modes,
  /// so on web this does nothing.
  Future<void> setTerrainLoadMode(TerrainLoadMode mode);

  /// Returns the height of the terrain at [point] as the map draws it, in
  /// meters above sea level.
  ///
  /// The drawn height includes the terrain's [Terrain.exaggeration] on every
  /// platform, as maplibre-gl-js reports it: under an exaggeration of 1.5, a
  /// 1000 m peak reads 1500 m. The true height of the ground is the drawn
  /// height divided by the exaggeration. At an exaggeration of 0 the terrain
  /// is drawn flat, so the drawn height is 0 and there is no ground height to
  /// derive.
  ///
  /// Returns null if the style has no terrain, or if no DEM tile that the map
  /// has loaded covers [point]: before its tile arrives, beyond the tiles of
  /// the terrain's source, and before the map has drawn its first frame. A
  /// point off screen reads its height while its DEM tile stays loaded.
  ///
  /// Every platform draws a DEM pixel's height at the pixel's centre, so the
  /// platforms read the same height from the same tiles. Before
  /// maplibre-gl-js 6.15.0, ground at exactly 0 m reads null on web.
  ///
  /// Each call is one query of the map's latest frame on native, or one call
  /// into maplibre-gl-js on web.
  Future<double?> queryTerrainElevation(Geographic point);
}
