import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// The 3D terrain of a style, which raises the map by the elevations of a
/// raster DEM source.
///
/// Set it with [StyleController.setTerrain].
///
/// https://maplibre.org/maplibre-style-spec/terrain/
@immutable
class Terrain {
  /// Creates a terrain from the raster DEM source with the ID [sourceId].
  const Terrain({required this.sourceId, this.exaggeration = 1.0})
    : assert(exaggeration >= 0, 'exaggeration must not be negative');

  /// The ID of the raster DEM source that provides the elevations.
  final String sourceId;

  /// The factor the elevations are multiplied by. 1 shows them as they are,
  /// 0 flattens the terrain.
  final double exaggeration;

  /// The terrain as a style spec terrain object.
  Map<String, Object?> toJson() => {
    'source': sourceId,
    'exaggeration': exaggeration,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Terrain &&
          sourceId == other.sourceId &&
          exaggeration == other.exaggeration;

  @override
  int get hashCode => Object.hash(sourceId, exaggeration);

  @override
  String toString() =>
      'Terrain(sourceId: $sourceId, exaggeration: $exaggeration)';
}

/// How the map trades the detail of the terrain for loading speed.
///
/// Set it with [MapController.setTerrainLoadMode].
enum TerrainLoadMode {
  /// Builds each terrain tile in the frame that reveals it, and keeps the
  /// most tiles. The sharpest, but a frame can stall on a burst of tiles.
  quality,

  /// Spreads the building of new terrain tiles over frames, and keeps fewer
  /// tiles.
  balanced,

  /// Builds the fewest new terrain tiles a frame, and keeps the fewest: the
  /// smoothest on a weak GPU, and the shortest view distance. It also drapes
  /// the map over the terrain at 512 pixels a tile, so draped lines look
  /// softer close up.
  performance,
}

/// Where the map draws a point of the ground, as
/// [MapController.toScreenLocationOnTerrain] finds it.
@immutable
class TerrainScreenLocation {
  /// Creates a screen location of a point of the ground.
  const TerrainScreenLocation({required this.offset, required this.occluded});

  /// The screen location in logical pixels.
  final Offset offset;

  /// Whether ground nearer the camera hides the point, such as a ridge in
  /// front of it.
  final bool occluded;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerrainScreenLocation &&
          offset == other.offset &&
          occluded == other.occluded;

  @override
  int get hashCode => Object.hash(offset, occluded);

  @override
  String toString() =>
      'TerrainScreenLocation(offset: $offset, occluded: $occluded)';
}
