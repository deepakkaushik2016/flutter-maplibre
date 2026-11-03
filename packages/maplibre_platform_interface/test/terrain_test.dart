import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

// Equal values from separate calls, which const would canonicalize into one
// instance.
Terrain _terrain(String sourceId, {double exaggeration = 1}) =>
    Terrain(sourceId: sourceId, exaggeration: exaggeration);

void main() {
  group('Terrain', () {
    test('serializes to the style spec terrain object', () {
      expect(const Terrain(sourceId: 'dem', exaggeration: 1.25).toJson(), {
        'source': 'dem',
        'exaggeration': 1.25,
      });
    });

    test('defaults the exaggeration to 1.0', () {
      const terrain = Terrain(sourceId: 'dem');
      expect(terrain.exaggeration, 1.0);
      expect(terrain.toJson(), {'source': 'dem', 'exaggeration': 1.0});
    });

    test('compares by source and exaggeration', () {
      expect(_terrain('dem'), _terrain('dem'));
      expect(_terrain('dem').hashCode, _terrain('dem').hashCode);
      expect(
        _terrain('dem', exaggeration: 2),
        _terrain('dem', exaggeration: 2),
      );
      expect(_terrain('dem'), isNot(_terrain('other')));
      expect(_terrain('dem'), isNot(_terrain('dem', exaggeration: 2)));
    });

    test('asserts a non-negative exaggeration', () {
      expect(
        () => _terrain('dem', exaggeration: -0.5),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('TerrainLoadMode', () {
    test('has the quality, balanced and performance modes', () {
      expect(TerrainLoadMode.values, [
        TerrainLoadMode.quality,
        TerrainLoadMode.balanced,
        TerrainLoadMode.performance,
      ]);
    });
  });
}
