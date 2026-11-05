import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
// The engine's own state is below the public API on purpose: the public
// setter only completes, whatever the engine did with it.
import 'package:maplibre_native/src/map_state.dart';

/// The terrain load mode that MapLibre Native uses for the map that
/// [tester] shows.
TerrainLoadMode? engineTerrainLoadMode(WidgetTester tester) => tester
    .state<MapLibreMapStateNative>(find.byType(MapLibreMap))
    .engineTerrainLoadMode;
