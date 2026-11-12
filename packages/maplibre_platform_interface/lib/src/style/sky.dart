import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_platform_interface/src/style/expressions/expression_json.dart';

/// The sky of a style: the color above the horizon, and the fog that fades
/// the distant ground into it.
///
/// The sky shows only while the horizon is on screen: on a phone-shaped
/// view, from a pitch of about 69 degrees, above the default
/// [MapOptions.maxPitch] of 60. The fog fades the ground of a 3D terrain
/// only above a pitch of 60 degrees and in full from 70 degrees, on web and
/// native alike. Set it with [StyleController.setSky].
///
/// The blends are clamped to the range from 0 to 1, on web and native alike.
///
/// https://maplibre.org/maplibre-style-spec/sky/
@immutable
class Sky {
  /// Creates a sky. Each member defaults to its style spec default.
  const Sky({
    this.skyColor = const Color(0xFF88C6FC),
    this.horizonColor = const Color(0xFFFFFFFF),
    this.fogColor = const Color(0xFFFFFFFF),
    this.fogGroundBlend = 0.5,
    this.horizonFogBlend = 0.8,
    this.skyHorizonBlend = 0.8,
    this.atmosphereBlend = 0.8,
  });

  /// The color of the sky at the top of the screen.
  final Color skyColor;

  /// The color of the sky at the horizon.
  final Color horizonColor;

  /// The color of the fog over the distant ground.
  final Color fogColor;

  /// Where the fog starts on the ground, from 0 at the camera to 1 at the
  /// horizon. 1 turns the fog off. The fog shows only on a 3D terrain viewed
  /// at a pitch above 60 degrees, and in full from 70 degrees.
  final double fogGroundBlend;

  /// How far the fog color reaches up into the sky at the horizon, from 0 to
  /// 1.
  final double horizonFogBlend;

  /// How far the horizon color reaches up into the sky, from 0 to 1.
  final double skyHorizonBlend;

  /// How much the atmosphere shows around the globe, from 0 to 1. Only on
  /// web, with [MapProjection.globe].
  final double atmosphereBlend;

  /// The sky as a style spec sky object, with each blend clamped to the
  /// range from 0 to 1, as native clamps them and web would reject them.
  Map<String, Object?> toJson() => {
    'sky-color': cssColorOf(skyColor),
    'horizon-color': cssColorOf(horizonColor),
    'fog-color': cssColorOf(fogColor),
    'fog-ground-blend': fogGroundBlend.clamp(0.0, 1.0),
    'horizon-fog-blend': horizonFogBlend.clamp(0.0, 1.0),
    'sky-horizon-blend': skyHorizonBlend.clamp(0.0, 1.0),
    'atmosphere-blend': atmosphereBlend.clamp(0.0, 1.0),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Sky &&
          skyColor == other.skyColor &&
          horizonColor == other.horizonColor &&
          fogColor == other.fogColor &&
          fogGroundBlend == other.fogGroundBlend &&
          horizonFogBlend == other.horizonFogBlend &&
          skyHorizonBlend == other.skyHorizonBlend &&
          atmosphereBlend == other.atmosphereBlend;

  @override
  int get hashCode => Object.hash(
    skyColor,
    horizonColor,
    fogColor,
    fogGroundBlend,
    horizonFogBlend,
    skyHorizonBlend,
    atmosphereBlend,
  );

  @override
  String toString() =>
      'Sky(skyColor: $skyColor, horizonColor: $horizonColor, '
      'fogColor: $fogColor, fogGroundBlend: $fogGroundBlend, '
      'horizonFogBlend: $horizonFogBlend, skyHorizonBlend: $skyHorizonBlend, '
      'atmosphereBlend: $atmosphereBlend)';
}
