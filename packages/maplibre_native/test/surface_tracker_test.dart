import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/android/surface_tracker.dart';
import 'package:maplibre_native/src/frame_target.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart';

final class _Host implements FrameTargetHost {
  @override
  bool disposed = false;

  int demands = 0;

  @override
  LogicalExtent get extent =>
      const LogicalExtent(width: 1, height: 1, scaleFactor: 1);

  @override
  Future<T> onGpuQueue<T>(Future<T> Function() action) => action();

  @override
  void demandFrame() => demands++;

  @override
  void showFrame(RenderFrameResult frame) {}
}

void main() {
  late List<String> calls;
  late _Host host;
  late SurfaceTracker tracker;
  late bool retargetFails;
  Completer<void>? holdRetarget;

  setUp(() {
    calls = [];
    host = _Host();
    retargetFails = false;
    holdRetarget = null;
    tracker = SurfaceTracker(
      setSurface: (_) async {
        calls.add('setSurface');
        await holdRetarget?.future;
        if (retargetFails) throw StateError('no surface');
      },
      releaseTarget: () async => calls.add('releaseTarget'),
    );
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('the surface going and coming back retargets and demands', () async {
    tracker
      ..attached()
      ..host = host
      ..lost();
    expect(tracker.available, isFalse);
    expect(calls, ['releaseTarget']);
    tracker.back();
    await settle();
    expect(tracker.available, isTrue);
    expect(calls, ['releaseTarget', 'setSurface']);
    expect(host.demands, 1);
  });

  test('a flip before the session exists leaves it available', () {
    tracker
      ..lost()
      ..back();
    expect(tracker.available, isTrue);
  });

  test('a later attach recovers a surface that was reported lost', () {
    tracker
      ..lost()
      ..attached();
    expect(tracker.available, isTrue);
  });

  test('a flip after attach but before the host retargets later', () async {
    tracker
      ..attached()
      ..lost()
      ..back();
    expect(tracker.available, isFalse);
    expect(calls, isEmpty);
    tracker.host = host;
    await settle();
    expect(calls, ['setSurface']);
    expect(tracker.available, isTrue);
    expect(host.demands, 1);
  });

  test('a failing retarget does not leave the map refusing frames', () async {
    tracker
      ..attached()
      ..host = host
      ..lost();
    retargetFails = true;
    tracker.back();
    await settle();
    expect(tracker.available, isTrue);
    expect(host.demands, 1);
  });

  test('a surface lost again during the retarget stays lost', () async {
    tracker
      ..attached()
      ..host = host;
    final hold = holdRetarget = Completer<void>();
    tracker
      ..lost()
      ..back();
    await settle();
    tracker.lost();
    hold.complete();
    await settle();
    expect(tracker.available, isFalse);
    expect(host.demands, 0);
  });

  test('a disposed renderer is not retargeted', () async {
    tracker
      ..attached()
      ..host = host
      ..lost();
    calls.clear();
    host.disposed = true;
    tracker.back();
    await settle();
    expect(calls, isEmpty);
    expect(host.demands, 0);
  });
}
