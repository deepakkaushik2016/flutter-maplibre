import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:maplibre/maplibre.dart';

/// How a [UserLocationLayer] draws the accuracy circle and the heading cone
/// around its dot, and the dot's outline. The dot's own color and size are
/// [UserLocationLayer.color] and [UserLocationLayer.radius].
///
/// {@category Location}
@immutable
class UserLocationStyle {
  /// Creates a style; every value has a default.
  const UserLocationStyle({
    this.strokeColor = const Color(0xFFFFFFFF),
    this.strokeWidth = 2,
    this.showAccuracy = true,
    this.accuracyColor,
    this.accuracyOpacity = 0.15,
    this.accuracyOutlineOpacity = 0.4,
    this.showHeading = true,
    this.headingColor,
    this.headingOpacity = 0.5,
    this.headingHalfAngle = 30,
    this.headingLength = 64,
  });

  /// The color of the dot's outline.
  final Color strokeColor;

  /// The width of the dot's outline in logical pixels.
  final double strokeWidth;

  /// Whether the circle of [UserLocation.accuracy] shows around the dot.
  final bool showAccuracy;

  /// The color of the accuracy circle, or null for the dot's color.
  final Color? accuracyColor;

  /// The opacity of the accuracy circle's area, from 0 to 1.
  final double accuracyOpacity;

  /// The opacity of the accuracy circle's outline, from 0 to 1.
  final double accuracyOutlineOpacity;

  /// Whether the cone of [UserLocation.heading] shows. It never shows while
  /// the heading is null.
  final bool showHeading;

  /// The color of the heading cone, or null for the dot's color.
  final Color? headingColor;

  /// The opacity of the heading cone at its apex, from 0 to 1. It fades to
  /// nothing at its far end.
  final double headingOpacity;

  /// Half the angle of the heading cone in degrees: 30 for a cone 60° wide.
  final double headingHalfAngle;

  /// The length of the heading cone in logical pixels on screen.
  ///
  /// The cone keeps this length at every zoom, as the beams of mainstream
  /// map apps do: a length in meters would be a few pixels when zoomed out
  /// and fill the screen when zoomed in.
  final double headingLength;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserLocationStyle &&
          strokeColor == other.strokeColor &&
          strokeWidth == other.strokeWidth &&
          showAccuracy == other.showAccuracy &&
          accuracyColor == other.accuracyColor &&
          accuracyOpacity == other.accuracyOpacity &&
          accuracyOutlineOpacity == other.accuracyOutlineOpacity &&
          showHeading == other.showHeading &&
          headingColor == other.headingColor &&
          headingOpacity == other.headingOpacity &&
          headingHalfAngle == other.headingHalfAngle &&
          headingLength == other.headingLength;

  @override
  int get hashCode => Object.hash(
    strokeColor,
    strokeWidth,
    showAccuracy,
    accuracyColor,
    accuracyOpacity,
    accuracyOutlineOpacity,
    showHeading,
    headingColor,
    headingOpacity,
    headingHalfAngle,
    headingLength,
  );
}
