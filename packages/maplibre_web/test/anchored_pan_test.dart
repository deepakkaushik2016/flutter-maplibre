@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_web/src/anchored_pan.dart';
import 'package:maplibre_web/src/interop/interop.dart' as interop;

@JS('eval')
external void _eval(String source);

@JS('mockMap')
external interop.JsMap get _map;

@JS('mockMap.setGain')
external void _setGain(num kx, num ky);

@JS('writes')
external JSArray<JSString> get _writes;

/// A map that draws the ground the way gl-js draws terrain, unlike the flat
/// plane `easeTo` places things on.
///
/// Locations are world pixels (lng = x, lat = y). The ground is drawn [kx]
/// and [ky] times as far from the middle as the flat plane, foreshortened
/// towards the top by [q] per pixel (a perspective, scaled by the pitch over
/// 50), and nothing is drawn above the horizon at [horizon] (sky: NaN).
/// [bounds] clamps the centre, as `maxBounds` does. The container is
/// 400 x 300 with its middle at (200, 150). Each write is logged with
/// whether it was silent.
void _mock({
  double kx = 1,
  double ky = 1,
  double q = 0,
  double horizon = -1e9,
  List<double>? bounds,
}) => _eval('''
  globalThis.silent = 0;
  globalThis.writes = [];
  globalThis.maplibregl ??= {
    Point: class { constructor(x, y) { this.x = x; this.y = y; } },
  };
  globalThis.mockMap = (() => {
    const mid = {x: 200, y: 150};
    const bounds = ${bounds == null ? 'null' : '[${bounds.join(',')}]'};
    let c = {x: 1000, y: 1000}, zoom = 10, bearing = 0, pitch = 50;
    let KX = $kx, KY = $ky;
    const scale = () => Math.pow(2, zoom - 10);
    const qq = () => $q * pitch / 50;
    const rot = (p, deg) => {
      const r = deg * Math.PI / 180, cs = Math.cos(r), sn = Math.sin(r);
      return {x: p.x * cs - p.y * sn, y: p.x * sn + p.y * cs};
    };
    const clamp = () => {
      if (!bounds) return;
      c = {x: Math.min(Math.max(c.x, bounds[0]), bounds[2]),
           y: Math.min(Math.max(c.y, bounds[1]), bounds[3])};
    };
    const log = (what) => writes.push((silent > 0 ? 'silent ' : 'shown ') + what);
    const ll = (x, y) => ({lng: x, lat: y});
    const off = (o) => o ? {x: o.x ?? o[0], y: o.y ?? o[1]} : {x: 0, y: 0};
    return {
      // The terrain changes under the map, as a style or pitch change does.
      setGain(kx, ky) { KX = kx; KY = ky; },
      getCenter() { return ll(c.x, c.y); },
      getZoom() { return zoom; },
      getBearing() { return bearing; },
      getPitch() { return pitch; },
      getCanvas() { return {clientWidth: 400, clientHeight: 300}; },
      project(l) {
        const r = rot({x: (l.lng - c.x) * scale(), y: (l.lat - c.y) * scale()}, -bearing);
        const d = 1 + qq() * r.y;
        if (d <= 0) return {x: NaN, y: NaN};
        return {x: mid.x + KX * r.x / d, y: mid.y + KY * r.y / d};
      },
      unproject(p) {
        if (p.y < $horizon) return ll(NaN, NaN);
        const dy = p.y - mid.y;
        const ry = dy / (KY - qq() * dy);
        const rx = (p.x - mid.x) * (1 + qq() * ry) / KX;
        const w = rot({x: rx, y: ry}, bearing);
        return ll(c.x + w.x / scale(), c.y + w.y / scale());
      },
      // The flat plane: `center` is drawn at the middle plus `offset`.
      easeTo(o) {
        const f = rot(off(o.offset), bearing);
        c = {x: o.center.lng - f.x / scale(), y: o.center.lat - f.y / scale()};
        clamp();
        log('easeTo');
      },
      jumpTo(o) {
        if (o.center) c = {x: o.center.lng, y: o.center.lat};
        if (o.zoom != null) zoom = o.zoom;
        if (o.bearing != null) bearing = o.bearing;
        if (o.pitch != null) pitch = o.pitch;
        clamp();
        log('jumpTo');
      },
    };
  })();
''');

void _silently(void Function() writes) {
  _eval('silent++');
  try {
    writes();
  } finally {
    _eval('silent--');
  }
}

List<String> get _log => _writes.toDart.map((w) => w.toDart).toList();
int get _shown => _log.where((w) => w.startsWith('shown')).length;

interop.LngLat _groundAt(Offset p) => _map.unproject(interop.Point(p.dx, p.dy));

Offset _screenOf(interop.LngLat at) {
  final p = _map.project(at);
  return Offset(p.x.toDouble(), p.y.toDouble());
}

double _miss(interop.LngLat at, Offset want) => (_screenOf(at) - want).distance;

/// Drags with [pan] from [start] by [by] in ten moves, as the gesture
/// detector reports them, returning how far the ground that was under the
/// pointer is from it after each move.
List<double> _drag(AnchoredPan pan, Offset start, Offset by) {
  final grabbed = _groundAt(start);
  final misses = <double>[];
  var at = start;
  for (var i = 1; i <= 10; i++) {
    final to = start + by * (i / 10);
    pan.apply(GestureCameraUpdate(panFrom: at, panTo: to));
    at = to;
    misses.add(_miss(grabbed, to));
  }
  return misses;
}

const _start = Offset(260, 230);
const _by = Offset(90, 50);
const _tolerance = AnchoredPan.tolerance;

void main() {
  test('one flat step drifts over terrain (the mock shows the bug)', () {
    _mock(kx: 2.5, ky: 2.5);
    final grabbed = _groundAt(_start);
    var at = _start;
    for (var i = 1; i <= 10; i++) {
      final to = _start + _by * (i / 10);
      // What the gesture camera did before: unproject, then easeTo with an
      // offset that gl-js resolves on the flat plane.
      _map.easeTo(
        interop.EaseToOptions(
          center: _groundAt(at),
          offset: interop.Point(to.dx - 200, to.dy - 150),
          duration: 0,
        ),
      );
      at = to;
    }
    expect(_miss(grabbed, _start + _by), greaterThan(100));
  });

  group('a drag keeps the ground under the pointer', () {
    for (final (name, kx, ky, q) in const [
      ('ground nearer than the centre', 2.5, 2.5, 0.0),
      ('ground further than the centre', 0.4, 0.4, 0.0),
      ('a perspective, x and y unlike', 1.8, 3.2, 0.002),
      ('steeply foreshortened, as at pitch 75', 1.2, 4.0, 0.0035),
    ]) {
      test(name, () {
        _mock(kx: kx, ky: ky, q: q);
        final misses = _drag(AnchoredPan(_map, _silently), _start, _by);
        expect(misses, everyElement(lessThanOrEqualTo(_tolerance)));
        // The map reports one move per pointer move, not one per write.
        expect(_shown, 10);
      });
    }

    test('on a flat map, one correcting write per move', () {
      _mock();
      final misses = _drag(AnchoredPan(_map, _silently), _start, _by);
      expect(misses, everyElement(lessThanOrEqualTo(_tolerance)));
      expect(_log.where((w) => w == 'silent easeTo').length, 10);
      expect(_shown, 10);
    });

    test('the gain it learns is the ground\'s', () {
      _mock(kx: 2.5, ky: 2.5);
      final pan = AnchoredPan(_map, _silently);
      _drag(pan, _start, _by);
      expect(pan.gainAlong(const Offset(1, 0)), closeTo(2.5, 0.05));
      expect(pan.gainAlong(const Offset(0, 1)), closeTo(2.5, 0.05));
    });
  });

  test('a move that starts somewhere else takes the ground found there', () {
    _mock(kx: 2.5, ky: 2.5);
    final pan = AnchoredPan(_map, _silently)
      ..apply(
        GestureCameraUpdate(
          panFrom: _start,
          panTo: _start + const Offset(10, 0),
        ),
      );
    // A second finger moved the focal point: the pan goes on from there.
    const focal = Offset(100, 100);
    final under = _groundAt(focal);
    pan.apply(
      const GestureCameraUpdate(panFrom: focal, panTo: Offset(100, 120)),
    );
    expect(_miss(under, const Offset(100, 120)), lessThanOrEqualTo(_tolerance));
  });

  test('ground held where it can no longer be drawn is taken again', () {
    _mock(kx: 2.5, ky: 2.5);
    final pan = AnchoredPan(_map, _silently)
      ..apply(
        GestureCameraUpdate(
          panFrom: _start,
          panTo: _start + const Offset(5, 0),
        ),
      );
    // Something else moved the camera far away mid-gesture.
    _map.jumpTo(
      interop.JumpToOptions(center: interop.LngLat(lng: 9000, lat: 9000)),
    );
    final from = _start + const Offset(5, 0);
    final under = _groundAt(from);
    pan.apply(
      GestureCameraUpdate(panFrom: from, panTo: from + const Offset(10, 10)),
    );
    expect(
      _miss(under, from + const Offset(10, 10)),
      lessThanOrEqualTo(_tolerance),
    );
  });

  test('over the sky the flat plane follows the pointer, then the ground', () {
    _mock(kx: 2, ky: 2, horizon: 60);
    final pan = AnchoredPan(_map, _silently);
    final before = _map.getCenter();
    pan.apply(
      const GestureCameraUpdate(
        panFrom: Offset(200, 40),
        panTo: Offset(200, 50),
      ),
    );
    final after = _map.getCenter();
    expect(after.lat.toDouble().isFinite, isTrue);
    expect(after.lat.toDouble(), closeTo(before.lat.toDouble() - 10, 1e-6));
    // Onto the ground: from the move that starts there, it holds the ground
    // under the pointer.
    pan.apply(
      const GestureCameraUpdate(
        panFrom: Offset(200, 50),
        panTo: Offset(200, 70),
      ),
    );
    final under = _groundAt(const Offset(200, 70));
    pan.apply(
      const GestureCameraUpdate(
        panFrom: Offset(200, 70),
        panTo: Offset(200, 90),
      ),
    );
    expect(_miss(under, const Offset(200, 90)), lessThanOrEqualTo(_tolerance));
  });

  test('at the bounds it stops without a runaway gain, then follows again', () {
    _mock(kx: 2.5, ky: 2.5, bounds: [990, 990, 1010, 1010]);
    final pan = AnchoredPan(_map, _silently);
    _drag(pan, _start, const Offset(120, 0));
    final c = _map.getCenter();
    expect(c.lng.toDouble(), inInclusiveRange(990, 1010));
    // A clamped step may teach a smaller gain, never one past the limits,
    // so the next step is at most a few times what is left to go.
    for (final axis in const [Offset(1, 0), Offset(0, 1)]) {
      expect(
        pan.gainAlong(axis),
        inInclusiveRange(AnchoredPan.minGain, AnchoredPan.maxGain),
      );
    }
    // Back inside the bounds the ground follows the pointer again.
    pan.reset();
    final misses = _drag(pan, const Offset(200, 150), const Offset(-20, 0));
    expect(misses.last, lessThanOrEqualTo(_tolerance));
  });

  test('a ground that moves against the step never ends further away', () {
    _mock(kx: -1.5, ky: 2);
    final pan = AnchoredPan(_map, _silently);
    final grabbed = _groundAt(_start);
    const to = Offset(290, 230);
    final before = _miss(grabbed, to);
    pan.apply(const GestureCameraUpdate(panFrom: _start, panTo: to));
    expect(_miss(grabbed, to), lessThanOrEqualTo(before));
    expect(pan.gainAlong(const Offset(1, 0)), greaterThan(0));
    final c = _map.getCenter();
    expect(c.lng.toDouble().isFinite && c.lat.toDouble().isFinite, isTrue);
  });

  group('zoom, rotate and tilt around a point keep the ground there', () {
    const around = Offset(300, 220);
    for (final (name, update) in const [
      ('a wheel zoom', GestureCameraUpdate(zoomBy: 0.6, around: around)),
      ('a rotation', GestureCameraUpdate(rotateBy: 30, around: around)),
      ('a tilt', GestureCameraUpdate(pitchBy: 15, around: around)),
    ]) {
      test(name, () {
        _mock(kx: 1.8, ky: 3.2, q: 0.002);
        final held = _groundAt(around);
        AnchoredPan(_map, _silently).apply(update);
        expect(_miss(held, around), lessThanOrEqualTo(_tolerance));
        expect(_shown, 1);
      });
    }

    test('cameraAround works out the camera and leaves the map as it was', () {
      _mock(kx: 1.8, ky: 3.2, q: 0.002);
      final pan = AnchoredPan(_map, _silently);
      final before = pan.camera();
      final target = pan.cameraAround(around, zoomBy: 1);
      expect(target.zoom, before.zoom + 1);
      expect(_map.getCenter().lng, before.center.lng);
      expect(_shown, 0);
    });
  });
  group('a fling measures the ground at the release', () {
    test('after a terrain drag, on a flat map, it measures 1', () {
      _mock(kx: 2.5, ky: 2.5);
      final pan = AnchoredPan(_map, _silently);
      _drag(pan, _start, _by);
      expect(pan.gainAlong(const Offset(1, 0)), closeTo(2.5, 0.05));
      // The style or the pitch changed: the ground is flat now.
      _setGain(1, 1);
      final before = _map.getCenter();
      expect(pan.flingGain(const Offset(3, 1)), closeTo(1, 1e-6));
      // The probe is undone and reported nowhere.
      expect(_map.getCenter().lng, before.lng);
      expect(_map.getCenter().lat, before.lat);
      expect(_shown, 10);
    });

    test('over steep ground it measures the ground along the fling', () {
      _mock(kx: 1.8, ky: 3.2);
      final pan = AnchoredPan(_map, _silently);
      expect(pan.flingGain(const Offset(1, 0)), closeTo(1.8, 1e-6));
      expect(pan.flingGain(const Offset(0, -1)), closeTo(3.2, 1e-6));
    });

    test('over the sky it measures nothing and takes 1', () {
      _mock(kx: 2, ky: 2, horizon: 1e9);
      expect(AnchoredPan(_map, _silently).flingGain(const Offset(1, 0)), 1);
    });
  });

  test('a step that moves nothing writes nothing', () {
    _mock(kx: 2.5, ky: 2.5);
    AnchoredPan(_map, _silently).apply(const GestureCameraUpdate());
    expect(_log, isEmpty);
  });
}
