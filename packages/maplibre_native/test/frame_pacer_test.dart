import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/frame_pacer.dart';

/// A display of [refreshMs] that drives a [FramePacer] whose map keeps
/// changing, with frames that take [frameMs] from demand to done.
final class _Simulation {
  _Simulation(this.refreshMs, this.frameMs) {
    pacer = FramePacer(
      schedule: (tick) {
        expect(
          _pendingTick,
          isNull,
          reason: 'the pacer asks for one tick at a time',
        );
        _pendingTick = tick;
        ticksRequested++;
      },
      demand: () {
        demands++;
        _busyUntil = _now + frameMs;
      },
    );
  }

  final double refreshMs;
  final double frameMs;
  late final FramePacer pacer;
  int demands = 0;
  int refreshes = 0;
  int ticksRequested = 0;

  double _now = 0;
  double? _busyUntil;
  void Function()? _pendingTick;

  /// Flies for [durationMs]: the pacer's first demand starts it, and each
  /// finished frame tells the pacer, until the flight ends.
  void fly(double durationMs) {
    var nextRefresh = refreshMs;
    pacer.frameEnded();
    while (_now < durationMs) {
      final frameEnd = _busyUntil;
      if (frameEnd != null && frameEnd <= nextRefresh) {
        _now = frameEnd;
        _busyUntil = null;
        pacer.frameEnded();
        continue;
      }
      _now = nextRefresh;
      nextRefresh += refreshMs;
      refreshes++;
      final tick = _pendingTick;
      _pendingTick = null;
      tick?.call();
    }
  }
}

void main() {
  group('FramePacer', () {
    for (final frameMs in const [1.0, 8.0, 15.0, 16.0]) {
      test('a frame of $frameMs ms renders once per 60 Hz refresh', () {
        final sim = _Simulation(1000 / 60, frameMs)..fly(2000);
        expect(
          sim.demands,
          inInclusiveRange(sim.refreshes - 2, sim.refreshes + 1),
        );
      });
    }

    for (final frameMs in const [17.0, 21.0, 30.0, 40.0]) {
      test('a frame of $frameMs ms renders back to back, without halving', () {
        final sim = _Simulation(1000 / 60, frameMs)..fly(2000);
        expect(sim.demands, lessThanOrEqualTo(sim.refreshes + 1));
        // At most one refresh is lost between two long frames. Without the
        // credit a frame of 21 ms halves the rate to one per two refreshes.
        final backToBack = 2000 / frameMs;
        expect(sim.demands, greaterThanOrEqualTo(backToBack * 0.9));
      });
    }

    test('a frame of 8 ms renders once per 120 Hz refresh', () {
      final sim = _Simulation(1000 / 120, 8)..fly(2000);
      expect(
        sim.demands,
        inInclusiveRange(sim.refreshes - 2, sim.refreshes + 1),
      );
    });

    test('the first frame after rest is demanded at once', () {
      var demands = 0;
      final pacer = FramePacer(schedule: (_) {}, demand: () => demands++);
      pacer.frameEnded();
      expect(demands, 1);
    });

    test('at rest it asks for one tick and then none', () {
      final ticks = <void Function()>[];
      var demands = 0;
      final pacer = FramePacer(schedule: ticks.add, demand: () => demands++);
      pacer.frameEnded();
      expect(demands, 1);
      expect(ticks, hasLength(1));
      // No frame ends: the refresh grants the next demand and asks no more.
      ticks.removeAt(0)();
      expect(ticks, isEmpty);
      expect(demands, 1);
      // The next change renders at once, from the granted demand.
      pacer.frameEnded();
      expect(demands, 2);
    });

    test('a refresh that a frame waited for demands it at once', () {
      final ticks = <void Function()>[];
      var demands = 0;
      final pacer = FramePacer(schedule: ticks.add, demand: () => demands++)
        ..frameEnded(); // Rendered at once; its next demand has no credit.
      pacer.frameEnded();
      expect(demands, 1);
      expect(ticks, hasLength(1));
      ticks.removeAt(0)();
      expect(demands, 2);
    });
  });
}
