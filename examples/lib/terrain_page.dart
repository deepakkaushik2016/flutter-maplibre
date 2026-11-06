import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre_example/utils/simulated_locations.dart';

/// 3D terrain from a raster DEM source, with its hillshade. Tap the map to
/// read the ground and its height there. A simulated walk shows the user
/// location on the ground, with its heading.
@immutable
class TerrainPage extends StatefulWidget {
  const TerrainPage({super.key});

  static const location = '/terrain';

  @override
  State<TerrainPage> createState() => _TerrainPageState();
}

const _demSourceId = 'terrain';

const _center = Geographic(lon: 11.39085, lat: 47.27574);

class _TerrainPageState extends State<TerrainPage> {
  MapController? _controller;
  StyleController? _style;
  double _exaggeration = 1.5;
  TerrainLoadMode _loadMode = .quality;
  String? _tapped;
  final Stream<UserLocation> _walk = simulatedLocations(
    center: _center,
    radius: 400,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('3D Terrain')),
      body: Stack(
        children: [
          MapLibreMap(
            options: const MapOptions(
              initCamera: CameraUpdate.position(
                center: _center,
                zoom: 12,
                pitch: 60,
              ),
              maxPitch: 85,
            ),
            onMapCreated: (controller) => _controller = controller,
            onStyleLoaded: _onStyleLoaded,
            onClick: (event) => _onTap(event.screenPoint),
            children: [UserLocationLayer(locations: _walk)],
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: SafeArea(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_tapped ?? 'Tap the map to read the ground there.'),
                      Row(
                        children: [
                          Text(
                            'Exaggeration ${_exaggeration.toStringAsFixed(1)}',
                          ),
                          Expanded(
                            child: Slider(
                              value: _exaggeration,
                              max: 3,
                              divisions: 30,
                              onChanged: (value) {
                                setState(() => _exaggeration = value);
                                _applyTerrain();
                              },
                            ),
                          ),
                        ],
                      ),
                      SegmentedButton<TerrainLoadMode>(
                        segments: [
                          for (final mode in TerrainLoadMode.values)
                            ButtonSegment(value: mode, label: Text(mode.name)),
                        ],
                        selected: {_loadMode},
                        onSelectionChanged: (modes) {
                          setState(() => _loadMode = modes.single);
                          // A map option, kept for every style; web has none.
                          _controller?.setTerrainLoadMode(_loadMode);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onStyleLoaded(StyleController style) async {
    _style = style;
    await style.sources.add(
      const RasterDemSource.url(
        id: _demSourceId,
        url: 'https://demotiles.maplibre.org/terrain-tiles/tiles.json',
        tileSize: 256,
      ),
    );
    await style.layers.add(
      HillshadeStyleLayer(id: 'hillshade', sourceId: _demSourceId),
    );
    await _applyTerrain();
  }

  Future<void> _applyTerrain() async {
    await _style?.setTerrain(
      Terrain(sourceId: _demSourceId, exaggeration: _exaggeration),
    );
  }

  /// Finds the ground drawn at [screenPoint], not the sea-level point that
  /// the tap event carries, and reads its height.
  Future<void> _onTap(Offset screenPoint) async {
    final controller = _controller;
    if (controller == null) return;
    final ground = await controller.toLngLatOnTerrain(screenPoint);
    if (ground == null) {
      setState(() => _tapped = 'No ground there: sky, or its tile loads.');
      return;
    }
    final drawn = await controller.queryTerrainElevation(ground);
    if (!mounted) return;
    setState(() {
      final at =
          '${ground.lat.toStringAsFixed(5)}, ${ground.lon.toStringAsFixed(5)}';
      _tapped = switch (drawn) {
        // The drawn height includes the exaggeration.
        final drawn? when _exaggeration > 0 =>
          'Ground at $at, ${(drawn / _exaggeration).round()} m high',
        _ => 'Ground at $at',
      };
    });
  }
}
