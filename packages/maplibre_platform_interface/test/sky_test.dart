import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

// Equal values from separate calls, which const would canonicalize into one
// instance.
Sky _sky({Color skyColor = const Color(0xFF88C6FC), double fog = 0.5}) =>
    Sky(skyColor: skyColor, fogGroundBlend: fog);

void main() {
  group('Sky', () {
    test('defaults to the style spec defaults', () {
      expect(const Sky().toJson(), {
        'sky-color': '#88c6fc',
        'horizon-color': '#ffffff',
        'fog-color': '#ffffff',
        'fog-ground-blend': 0.5,
        'horizon-fog-blend': 0.8,
        'sky-horizon-blend': 0.8,
        'atmosphere-blend': 0.8,
      });
    });

    test('serializes to the style spec sky object', () {
      const sky = Sky(
        skyColor: Color(0xFF3E7CC0),
        horizonColor: Color(0xFFDCE7EF),
        fogColor: Color(0x80C6D4E0),
        fogGroundBlend: 0.35,
        horizonFogBlend: 0.75,
        skyHorizonBlend: 0.85,
        atmosphereBlend: 0.9,
      );
      expect(sky.toJson(), {
        'sky-color': '#3e7cc0',
        'horizon-color': '#dce7ef',
        'fog-color': 'rgba(198, 212, 224, ${const Color(0x80C6D4E0).a})',
        'fog-ground-blend': 0.35,
        'horizon-fog-blend': 0.75,
        'sky-horizon-blend': 0.85,
        'atmosphere-blend': 0.9,
      });
    });

    test('compares by every member', () {
      expect(_sky(), _sky());
      expect(_sky().hashCode, _sky().hashCode);
      expect(_sky(), const Sky());
      expect(_sky(), isNot(_sky(skyColor: const Color(0xFF0000FF))));
      expect(_sky(), isNot(_sky(fog: 1)));
    });

    test('asserts blends between 0 and 1', () {
      expect(() => Sky(fogGroundBlend: -0.1), throwsA(isA<AssertionError>()));
      expect(() => Sky(atmosphereBlend: 1.1), throwsA(isA<AssertionError>()));
    });
  });
}
