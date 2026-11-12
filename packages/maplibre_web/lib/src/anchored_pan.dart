import 'dart:math';
import 'dart:ui';

import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_web/src/extensions.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;

/// A camera of the web map.
typedef WebCamera = ({interop.LngLat center, num zoom, num bearing, num pitch});

/// Converts a [WebCamera] for gl-js.
extension WebCameraOptions on WebCamera {
  /// The camera as options for `jumpTo`.
  interop.JumpToOptions get options => interop.JumpToOptions(
    center: center,
    zoom: zoom,
    bearing: bearing,
    pitch: pitch,
  );
}

/// Applies gesture steps to the web map so the ground a gesture holds stays
/// where the gesture holds it, with terrain or without.
///
/// GL JS resolves `easeTo`'s `offset` on the flat plane at the elevation of
/// the map's centre, while `unproject` and `project` see the terrain. Where
/// the ground under a point is higher or lower than the centre, one step
/// lands it far from where it was aimed, and a drag made of such steps
/// drifts further with every move. Here the result of each step is measured
/// with `project` and the rest of the distance is panned again, scaled by
/// how far the ground moved along each screen axis for the last steps. The
/// ground is foreshortened up the screen, so it moves unlike along x and y.
///
/// Every camera write here is made inside the silent callback, so the map
/// reports none of them; [apply] then reports the camera it ended at with
/// one write.
final class AnchoredPan {
  /// Creates the steps for [_map]. [_silently] runs camera writes that the
  /// map does not report as moves.
  AnchoredPan(this._map, this._silently);

  final interop.JsMap _map;
  final void Function(void Function() writes) _silently;

  /// At most this many correcting writes per placement.
  static const maxSteps = 4;

  /// Close enough, in logical pixels.
  static const tolerance = 0.5;

  /// The gains accepted from a step: how far the ground moves on screen for
  /// each pixel the flat plane moves. Outside them a measurement is a clamp,
  /// a stall or noise, not the ground.
  static const minGain = 0.2;

  /// See [minGain].
  static const maxGain = 20.0;

  /// A step is at most this many times the distance still to go.
  static const maxStepPerMiss = 4.0;

  /// A step whose ground moved less than this share of it hit a clamp
  /// (bounds or a zoom limit), and the placement stops.
  static const stallShare = 0.05;

  /// An axis of a step counts towards that axis's gain only when it is at
  /// least this share of the step.
  static const minAxisShare = 0.2;

  /// The ground held last is dropped when it is drawn further than this many
  /// canvases from where it was put.
  static const maxCanvases = 3;

  interop.LngLat? _anchor;
  Offset? _lastTo;
  // How far the ground moves on screen along x and along y for each pixel
  // the flat plane moves, as last measured. Kept across gestures, as the
  // ground in view is alike.
  var _gainX = 1.0;
  var _gainY = 1.0;

  /// How far the ground moves on screen, for each pixel the flat plane is
  /// moved in [direction], as last measured.
  double gainAlong(Offset direction) {
    if (direction.distance == 0) return 1;
    return Offset(direction.dx * _gainX, direction.dy * _gainY).distance /
        direction.distance;
  }

  /// Forgets the ground the last gesture held.
  void reset() {
    _anchor = null;
    _lastTo = null;
  }

  /// The camera now.
  WebCamera camera() => (
    center: _map.getCenter(),
    zoom: _map.getZoom(),
    bearing: _map.getBearing(),
    pitch: _map.getPitch(),
  );

  /// Applies one gesture step, and reports the camera it ends at with one
  /// write.
  void apply(GestureCameraUpdate update) {
    _silently(() {
      if (update.pans) _pan(update.panFrom!, update.panTo!);
      if (update.zoomBy == 0 && update.rotateBy == 0 && update.pitchBy == 0) {
        return;
      }
      final around = update.around;
      _map.jumpTo(
        around == null
            ? interop.JumpToOptions(
                zoom: _map.getZoom() + update.zoomBy,
                bearing: _map.getBearing() + update.rotateBy,
                pitch: _map.getPitch() + update.pitchBy,
              )
            : cameraAround(
                around,
                zoomBy: update.zoomBy,
                rotateBy: update.rotateBy,
                pitchBy: update.pitchBy,
              ).options,
      );
    });
    _map.jumpTo(camera().options);
  }

  /// The camera after zooming, rotating and tilting by the given amounts
  /// while the ground at [around] stays there. The camera is left as it was.
  ///
  /// GL JS's `around` drifts by hundreds of pixels on the globe and over
  /// terrain; changing the camera first and then placing the ground back
  /// stays exact in every projection.
  WebCamera cameraAround(
    Offset around, {
    double zoomBy = 0,
    double rotateBy = 0,
    double pitchBy = 0,
  }) {
    final location = _groundAt(around);
    final before = camera();
    late WebCamera target;
    _silently(() {
      _map.jumpTo(
        interop.JumpToOptions(
          zoom: before.zoom + zoomBy,
          bearing: before.bearing + rotateBy,
          pitch: before.pitch + pitchBy,
        ),
      );
      if (location != null) _place(location, around);
      target = camera();
      _map.jumpTo(before.options);
    });
    return target;
  }

  /// Moves the content under [from] to [to].
  ///
  /// The ground under the pointer is taken where the gesture's pan starts,
  /// and each later move puts that same ground under the pointer. A new
  /// ground is taken when a move does not start where the last one ended (a
  /// finger added or lifted moves the focal point), or when the held ground
  /// can no longer be drawn sensibly. Over the sky, where there is no ground,
  /// the flat plane moves with the pointer.
  void _pan(Offset from, Offset to) {
    var anchor = _anchor;
    final lastTo = _lastTo;
    if (anchor == null ||
        lastTo == null ||
        (from - lastTo).distance > tolerance ||
        !_plausible(_screenOf(anchor), from)) {
      anchor = _groundAt(from);
    }
    _anchor = anchor;
    _lastTo = to;
    if (anchor == null) {
      _write(_map.getCenter(), to - from);
      return;
    }
    _place(anchor, to);
  }

  /// Moves the camera so [location] is drawn at [point], or as near as the
  /// camera may go.
  void _place(interop.LngLat location, Offset point) {
    final at = _screenOf(location);
    if (at == null) return;
    var best = (center: _map.getCenter(), at: at);
    var atBest = true;
    var scale = 1.0;
    for (var i = 0; i < maxSteps; i++) {
      final miss = point - best.at;
      if (miss.distance <= tolerance) break;
      var step = Offset(miss.dx / _gainX, miss.dy / _gainY) * scale;
      final cap = miss.distance * maxStepPerMiss;
      if (step.distance > cap) step = step / step.distance * cap;
      // Draws the best centre `step` away from the middle: the flat plane
      // moves by `step` from there, and the ground by about the gains times
      // it.
      _write(best.center, step);
      atBest = false;
      final now = _screenOf(location);
      if (now == null) {
        scale /= 2;
        continue;
      }
      final moved = now - best.at;
      if (moved.distance < stallShare * step.distance) break;
      // What the ground did teaches the gains even when the step overshot.
      final relearnt = _learn(step, moved);
      if ((point - now).distance >= miss.distance) {
        // Worse: back to the best. With gains just put right the next step
        // is whole; with gains that held, it is half as long.
        scale = relearnt ? 1 : scale / 2;
        continue;
      }
      best = (center: _map.getCenter(), at: now);
      atBest = true;
      scale = 1;
    }
    if (!atBest) _write(best.center, Offset.zero);
  }

  /// Takes, for each axis of [step], the share of it that the ground took,
  /// when the ground moved that way at all. A ground that moved against the
  /// step, or by an implausible share, teaches nothing.
  ///
  /// Returns whether a gain changed by more than a tenth.
  bool _learn(Offset step, Offset moved) {
    double? learnt(double step, double moved, double length) {
      if (step.abs() < minAxisShare * length) return null;
      final gain = moved / step;
      return gain.isFinite && gain >= minGain && gain <= maxGain ? gain : null;
    }

    final length = step.distance;
    final x = learnt(step.dx, moved.dx, length) ?? _gainX;
    final y = learnt(step.dy, moved.dy, length) ?? _gainY;
    final changed =
        (x - _gainX).abs() > 0.1 * _gainX || (y - _gainY).abs() > 0.1 * _gainY;
    _gainX = x;
    _gainY = y;
    return changed;
  }

  // Only called within [apply] and [cameraAround], which make it silent.
  void _write(interop.LngLat center, Offset offset) => _map.easeTo(
    interop.EaseToOptions(center: center, offset: offset.toJs(), duration: 0),
  );

  /// Where [location] is drawn, or null if it can't be.
  Offset? _screenOf(interop.LngLat location) {
    final point = _map.project(location).toOffset();
    return point.isFinite ? point : null;
  }

  /// The ground drawn at [point], or null over the sky.
  interop.LngLat? _groundAt(Offset point) {
    final location = _map.unproject(point.toJs());
    final lng = location.lng.toDouble();
    final lat = location.lat.toDouble();
    return lng.isFinite && lat.isFinite ? location : null;
  }

  /// Whether ground drawn at [at] can still be the ground put at [want].
  bool _plausible(Offset? at, Offset want) {
    if (at == null) return false;
    final canvas = _map.getCanvas();
    final side = max(canvas.clientWidth, canvas.clientHeight).toDouble();
    return (at - want).distance <= maxCanvases * side;
  }
}
