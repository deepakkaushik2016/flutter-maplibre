import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/frame_pacer.dart';

/// A display of [refreshMs] that drives a [FramePacer] whose map keeps
/// changing, with frames that take [frameMs] from demand to done.
final class _Simulation {
  _Simulation(this.refreshMs, this.frameMs) {
    pacer = FramePacer(
      schedule: (tick) {
        expect(_tick, isNull, reason: 'the pacer asks for one tick at a time');
        _tick = tick;
      },
      demand: () {
        demands++;
        demandTimes.add(_now);
        _frameEnd = _now + frameMs;
      },
      now: () => Duration(microseconds: (_now * 1000).round()),
      delay: (duration, callback) {
        expect(_delayed, isNull);
        _delayEnd = _now + duration.inMicroseconds / 1000;
        _delayed = callback;
      },
    );
  }

  final double refreshMs;
  final double frameMs;
  late final FramePacer pacer;
  int demands = 0;
  int refreshes = 0;
  final demandTimes = <double>[];

  double _now = 0;
  double? _frameEnd;
  double? _delayEnd;
  void Function()? _tick;
  void Function()? _delayed;

  void fly(double durationMs) {
    var nextRefresh = refreshMs;
    pacer.frameEnded();
    while (_now < durationMs) {
      final frame = _frameEnd ?? double.infinity;
      final delay = _delayEnd ?? double.infinity;
      if (frame <= nextRefresh && frame <= delay) {
        _now = frame;
        _frameEnd = null;
        pacer.frameEnded();
      } else if (delay <= nextRefresh) {
        _now = delay;
        _delayEnd = null;
        final callback = _delayed!;
        _delayed = null;
        callback();
      } else {
        _now = nextRefresh;
        nextRefresh += refreshMs;
        refreshes++;
        final tick = _tick;
        _tick = null;
        tick?.call();
      }
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
      // The pacer starts from 60 Hz and learns the display's rate over the
      // first refreshes.
      expect(
        sim.demands,
        inInclusiveRange(sim.refreshes - 30, sim.refreshes + 1),
      );
    });

    test('a short frame starts before the coming refresh, not at it', () {
      final sim = _Simulation(1000 / 60, 4)..fly(1000);
      // Past the warm-up, each demand falls about a third of a refresh ahead
      // of a refresh, so the frame ends well before the refresh after it.
      for (final time in sim.demandTimes.skip(4)) {
        final phase = time % (1000 / 60);
        expect(phase, inInclusiveRange(10.0, 12.0), reason: 'at $time ms');
      }
    });

    test('the first frame after rest is demanded at once', () {
      var demands = 0;
      final pacer = FramePacer(
        schedule: (_) {},
        demand: () => demands++,
        now: () => Duration.zero,
        delay: (_, callback) => callback(),
      );
      pacer.frameEnded();
      expect(demands, 1);
    });

    test('at rest it stops asking for refreshes and renders nothing', () {
      final ticks = <void Function()>[];
      var demands = 0;
      var time = Duration.zero;
      final pacer = FramePacer(
        schedule: ticks.add,
        demand: () => demands++,
        now: () => time,
        delay: (_, callback) => callback(),
      )..frameEnded();
      expect(demands, 1);
      // No frame ends, as no change comes: a few refreshes, then none.
      for (var i = 0; i < 6 && ticks.isNotEmpty; i++) {
        time += const Duration(microseconds: 16667);
        ticks.removeAt(0)();
      }
      expect(ticks, isEmpty);
      expect(demands, 1);
      // The next change, long after, renders at once.
      time += const Duration(seconds: 1);
      pacer.frameEnded();
      expect(demands, 2);
    });

    test('a refresh that a frame waited for demands it', () {
      final ticks = <void Function()>[];
      var demands = 0;
      final pacer = FramePacer(
        schedule: ticks.add,
        demand: () => demands++,
        now: () => Duration.zero,
        delay: (_, callback) => callback(),
      )..frameEnded(); // Rendered at once; its next demand has no credit.
      pacer.frameEnded();
      expect(demands, 1);
      expect(ticks, hasLength(1));
      ticks.removeAt(0)();
      expect(demands, 2);
    });
  });
}
