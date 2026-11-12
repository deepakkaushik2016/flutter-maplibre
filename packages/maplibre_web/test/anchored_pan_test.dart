@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_web/src/anchored_pan.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;

@JS('eval')
external void _eval(String source);

@JS('mockMap')
external interop.JsMap get _mockMap;

@JS('cameraWrites')
external int get _cameraWrites;

/// A map whose ground is drawn [gain] times as far from the middle as the
/// flat plane `easeTo` places things on, as GL JS draws terrain that is
/// higher than the map's centre. Locations are world pixels (lng = x,
/// lat = y); the container's middle is (200, 150).
void _mockTerrain(double gain) => _eval('''
  globalThis.cameraWrites = 0;
  globalThis.maplibregl ??= {
    Point: class { constructor(x, y) { this.x = x; this.y = y; } },
  };
  globalThis.mockMap = (() => {
    const mid = {x: 200, y: 150};
    const k = $gain;
    let c = {x: 1000, y: 1000};
    const ll = (x, y) => ({lng: x, lat: y});
    const pt = (x, y) => ({x, y});
    return {
      getCenter() { return ll(c.x, c.y); },
      project(l) {
        return pt(mid.x + (l.lng - c.x) * k, mid.y + (l.lat - c.y) * k);
      },
      unproject(p) {
        return ll(c.x + (p.x - mid.x) / k, c.y + (p.y - mid.y) / k);
      },
      // The flat plane: `center` is drawn at the middle plus `offset`.
      easeTo(o) {
        cameraWrites++;
        const off = o.offset ? {x: o.offset.x ?? o.offset[0], y: o.offset.y ?? o.offset[1]} : {x: 0, y: 0};
        c = {x: o.center.lng - off.x, y: o.center.lat - off.y};
      },
    };
  })();
''');

Offset _screenOf(interop.LngLat at) {
  final p = _mockMap.project(at);
  return Offset(p.x.toDouble(), p.y.toDouble());
}

/// Drags from [start] by [by] in ten moves, returning how far the ground
/// that was under the pointer is from it after each move.
List<double> _drag(void Function(Offset, Offset) pan, Offset start, Offset by) {
  final anchor = _mockMap.unproject(interop.Point(start.dx, start.dy));
  final misses = <double>[];
  var at = start;
  for (var i = 1; i <= 10; i++) {
    final to = start + by * (i / 10);
    pan(at, to);
    at = to;
    misses.add((_screenOf(anchor) - to).distance);
  }
  return misses;
}

void main() {
  const start = Offset(260, 230);
  const by = Offset(90, 50);

  test('the single flat step drifts over terrain (the mock shows the bug)', () {
    _mockTerrain(2.5);
    // What the gesture camera did before: unproject, then easeTo with an
    // offset that GL JS resolves on the flat plane.
    final misses = _drag((from, to) {
      _mockMap.easeTo(
        interop.EaseToOptions(
          center: _mockMap.unproject(interop.Point(from.dx, from.dy)),
          offset: interop.Point(to.dx - 200, to.dy - 150),
          duration: 0,
        ),
      );
    }, start, by);
    expect(misses.last, greaterThan(100));
  });

  for (final gain in [2.5, 0.4]) {
    test('the ground under the pointer stays under it, gain $gain', () {
      _mockTerrain(gain);
      final pan = AnchoredPan(_mockMap);
      final misses = _drag(pan.pan, start, by);
      expect(misses, everyElement(lessThanOrEqualTo(AnchoredPan.tolerance)));
      // It learns the ground: once the gain is known, a move is one write.
      final before = _cameraWrites;
      pan.pan(start + by, start + by + const Offset(5, 5));
      expect(_cameraWrites - before, 1);
    });
  }

  test('on a flat map each move is one write, as before', () {
    _mockTerrain(1);
    final pan = AnchoredPan(_mockMap);
    final misses = _drag(pan.pan, start, by);
    expect(misses, everyElement(lessThanOrEqualTo(AnchoredPan.tolerance)));
    expect(_cameraWrites, 10);
  });

  test('a move that starts somewhere else takes the ground found there', () {
    _mockTerrain(2.5);
    final pan = AnchoredPan(_mockMap)..pan(start, start + const Offset(10, 0));
    // A second finger moved the focal point: the pan goes on from there.
    const focal = Offset(100, 100);
    final under = _mockMap.unproject(interop.Point(focal.dx, focal.dy));
    pan.pan(focal, focal + const Offset(0, 20));
    expect(
      (_screenOf(under) - (focal + const Offset(0, 20))).distance,
      lessThanOrEqualTo(AnchoredPan.tolerance),
    );
  });

  test('place puts a location at a point', () {
    _mockTerrain(2.5);
    final at = interop.LngLat(lng: 1010, lat: 990);
    AnchoredPan(_mockMap).place(at, const Offset(50, 60));
    expect(
      (_screenOf(at) - const Offset(50, 60)).distance,
      lessThanOrEqualTo(AnchoredPan.tolerance),
    );
  });
}
