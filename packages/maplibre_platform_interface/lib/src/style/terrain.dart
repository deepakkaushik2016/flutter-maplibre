import 'package:flutter/foundation.dart';
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
  /// Builds every terrain tile in the frame that reveals it, and keeps up
  /// to 64 of them. The sharpest, but a frame can stall on a burst of tiles.
  quality,

  /// Builds up to 32 new terrain tiles a frame, and keeps up to 48.
  balanced,

  /// Builds up to 8 new terrain tiles a frame, and keeps up to 24: the
  /// smoothest on a weak GPU, and the shortest view distance.
  performance,
}
