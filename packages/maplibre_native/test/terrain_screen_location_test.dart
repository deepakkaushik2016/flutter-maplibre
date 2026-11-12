import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/extensions.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart' as mln;
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

void main() {
  group('terrain screen locations', () {
    const hidden = mln.TerrainScreenPoint(
      point: mln.ScreenPoint(x: 12.5, y: -3),
      occluded: true,
    );

    test('convert a point of the ground', () {
      expect(
        hidden.toTerrainScreenLocation(),
        const TerrainScreenLocation(offset: Offset(12.5, -3), occluded: true),
      );
    });

    test('convert a found batch result to its point', () {
      expect(
        const mln.TerrainScreenPointResult(
          found: true,
          pixel: hidden,
        ).toTerrainScreenLocation(),
        hidden.toTerrainScreenLocation(),
      );
    });

    test('convert a missed batch result to null', () {
      expect(
        const mln.TerrainScreenPointResult().toTerrainScreenLocation(),
        isNull,
      );
      // A miss is null whatever its zeroed point holds.
      expect(
        const mln.TerrainScreenPointResult(pixel: hidden)
            .toTerrainScreenLocation(),
        isNull,
      );
    });
  });
}
