import 'dart:ui';

import 'package:maplibre_web/src/extensions.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;

/// Moves the camera so a map location lands on a screen point, exactly,
/// with terrain or without.
///
/// GL JS resolves `easeTo`'s `offset` on the flat plane at the elevation of
/// the map's centre, while `unproject` and `project` see the terrain. Where
/// the ground under a point is higher or lower than the centre, one step
/// lands it far from where it was aimed, and a drag made of such steps
/// drifts further with every move. Here the result of each step is measured
/// with `project` and the rest of the distance is panned again, scaled by
/// how far the ground moved for the last step.
final class AnchoredPan {
  /// Creates a pan that drives [_map].
  AnchoredPan(this._map);

  final interop.JsMap _map;

  /// At most this many steps per placement; each is one camera write.
  static const maxSteps = 4;

  /// Close enough, in logical pixels.
  static const tolerance = 0.5;

  interop.LngLat? _anchor;
  Offset? _lastTo;

  // How far the ground under the anchor moves on screen for each pixel the
  // flat plane is panned. Kept across moves, as nearby ground is alike.
  double _gain = 1;

  /// Forgets the gesture's anchor, for the next gesture.
  void reset() {
    _anchor = null;
    _lastTo = null;
    _gain = 1;
  }

  /// Moves the content under [from] to [to].
  ///
  /// The location under the pointer is taken once, where the gesture's pan
  /// started, and each later move puts that same location under the
  /// pointer. A move that does not start where the last one ended (a finger
  /// added or lifted moves the focal point) takes a new location.
  void pan(Offset from, Offset to) {
    if (_anchor == null ||
        _lastTo == null ||
        (from - _lastTo!).distance > 0.5) {
      _anchor = _map.unproject(from.toJs());
    }
    _lastTo = to;
    place(_anchor!, to);
  }

  /// Moves the camera so [location] is drawn at [point].
  void place(interop.LngLat location, Offset point) {
    var at = _map.project(location).toOffset();
    for (var i = 0; i < maxSteps; i++) {
      final miss = point - at;
      if (miss.distance <= tolerance || !miss.isFinite) return;
      final step = miss / _gain;
      // Draws the centre `step` away from the middle: the flat plane moves
      // by `step`, and the ground by about `_gain` times that.
      _map.easeTo(
        interop.EaseToOptions(
          center: _map.getCenter(),
          offset: step.toJs(),
          duration: 0,
        ),
      );
      final now = _map.project(location).toOffset();
      final moved = now - at;
      at = now;
      // The share of the step the ground took, along the step.
      final gain =
          (moved.dx * step.dx + moved.dy * step.dy) /
          (step.dx * step.dx + step.dy * step.dy);
      if (gain.isFinite && gain > 0.05 && gain < 20) _gain = gain;
    }
  }
}
