import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';

/// The terrain load mode that MapLibre Native uses for the map that
/// [tester] shows; null on web, which has no load modes.
TerrainLoadMode? engineTerrainLoadMode(WidgetTester tester) => null;
