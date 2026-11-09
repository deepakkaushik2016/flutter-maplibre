import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/frame_pacer.dart';

/// A display of [refreshMs] that drives a [FramePacer] whose map keeps
/// changing, with frames that take [frameMs] from demand to done.
final class _Simulation {
  _Simulation(this.refreshMs, this.frameMs, {double? seedMs}) {
    pacer = FramePacer(
      displayInterval: seedMs == null
          ? null
          : () => Duration(microseconds: (seedMs * 1000).round()),
      schedule: (tick, _) {
        expect(_tick, isNull, reason: 'the pacer asks for one tick at a time');
        _tick = tick;
      },
      demand: () {
        demands++;
        demandTimes.add(_now);
        _frameEnd = _now + frameMs;
        return true;
      },
      now: () => Duration(microseconds: (_now * 1000).round()),
      delay: (duration, callback) {
        expect(_delayed, isNull);
        _delayEnd = _now + duration.inMicroseconds / 1000;
        _delayed = callback;
      },
    );
  }

  double refreshMs;
  final double frameMs;
  late final FramePacer pacer;
  int demands = 0;
  int refreshes = 0;
  final demandTimes = <double>[];
  final refreshTimes = <double>[];

  /// When, and to what, the display's refresh interval changes.
  (double, double)? refreshChange;

  double _now = 0;
  double? _frameEnd;
  double? _delayEnd;
  RefreshCallback? _tick;
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
        final change = refreshChange;
        if (change != null && _now >= change.$1) {
          refreshMs = change.$2;
          refreshChange = null;
        }
        nextRefresh += refreshMs;
        refreshes++;
        refreshTimes.add(_now);
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
      // Past the warm-up, each demand falls about half a refresh after a
      // refresh, so the frame lands well clear of the refreshes around it.
      for (final time in sim.demandTimes.skip(4)) {
        final phase = time % (1000 / 60);
        expect(phase, inInclusiveRange(7.5, 9.5), reason: 'at $time ms');
      }
    });

    test('the first frame after rest is demanded at once', () {
      var demands = 0;
      final pacer = FramePacer(
        schedule: (_, _) {},
        demand: () {
          demands++;
          return true;
        },
        now: () => Duration.zero,
        delay: (_, callback) => callback(),
      );
      pacer.frameEnded();
      expect(demands, 1);
    });

    test('at rest it stops asking for refreshes and renders nothing', () {
      final ticks = <RefreshCallback>[];
      var demands = 0;
      var time = Duration.zero;
      final pacer = FramePacer(
        schedule: (tick, _) => ticks.add(tick),
        demand: () {
          demands++;
          return true;
        },
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

    group('a gesture', () {
      late List<RefreshCallback> ticks;
      late List<void Function()> delays;
      late int demands;
      late Duration time;
      late FramePacer pacer;

      setUp(() {
        ticks = [];
        delays = [];
        demands = 0;
        time = const Duration(seconds: 1);
        pacer = FramePacer(
          schedule: (tick, _) => ticks.add(tick),
          demand: () {
            demands++;
            return true;
          },
          now: () => time,
          delay: (_, callback) => delays.add(callback),
        )..frameEnded();
        expect(demands, 1);
      });

      test('during the delay demands at once, and the delay does nothing', () {
        time += const Duration(milliseconds: 4);
        pacer.frameEnded(); // Waits for the refresh.
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        expect(delays, hasLength(1));
        expect(demands, 1);
        pacer.expedite();
        expect(demands, 2);
        delays.removeAt(0)();
        expect(demands, 2);
      });

      test('before the refresh demands at the refresh, without a delay', () {
        time += const Duration(milliseconds: 4);
        pacer
          ..frameEnded()
          ..expedite();
        expect(demands, 1, reason: 'no refresh passed since the last demand');
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        expect(demands, 2);
        expect(delays, isEmpty);
      });

      test('with a frame in flight latches for the frame that ends', () {
        pacer.expedite();
        expect(demands, 1);
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)(); // A refresh passes while the frame runs.
        pacer.frameEnded();
        expect(demands, 2, reason: 'the gesture has no delay to sit through');
        expect(delays, isEmpty);
      });
    });

    test('a refresh without a display frame demands without a delay', () {
      final ticks = <RefreshCallback>[];
      final delays = <void Function()>[];
      var demands = 0;
      var time = const Duration(seconds: 1);
      final pacer = FramePacer(
        schedule: (tick, _) => ticks.add(tick),
        demand: () {
          demands++;
          return true;
        },
        now: () => time,
        delay: (_, callback) => delays.add(callback),
      )..frameEnded();
      time += const Duration(milliseconds: 4);
      pacer.frameEnded();
      time += const Duration(milliseconds: 16);
      ticks.removeAt(0)(fromDisplay: false);
      expect(demands, 2);
      expect(delays, isEmpty);
    });

    group('the display changes rate in flight', () {
      for (final (from, to) in const [(120, 60), (90, 60), (60, 120)]) {
        for (final frameMs in const [4.0, 10.0]) {
          test('$from to $to Hz with frames of $frameMs ms', () {
            final sim = _Simulation(1000 / from, frameMs)
              ..refreshChange = (1000.0, 1000.0 / to)
              ..fly(3000);
            expect(sim.demands, lessThanOrEqualTo(sim.refreshes + 1));
          });
        }
      }

      test('a slower display is learned, and paced half way through it', () {
        final sim = _Simulation(1000 / 120, 4)
          ..refreshChange = (500.0, 1000.0 / 60)
          ..fly(2000);
        final late = sim.demandTimes.where((time) => time > 1500).toList();
        for (var i = 1; i < late.length; i++) {
          expect(late[i] - late[i - 1], closeTo(1000 / 60, 3));
        }
        // Half a 60 Hz refresh after the refresh before each demand.
        for (final time in late) {
          final refresh = sim.refreshTimes.lastWhere((tick) => tick <= time);
          expect(time - refresh, closeTo(1000 / 120, 1.5), reason: 'at $time');
        }
      });

      test('a seed faster than the display cannot outrun it', () {
        // A 120 Hz seed on a 60 Hz display: frames of 10 ms look long.
        final sim = _Simulation(1000 / 60, 10, seedMs: 1000 / 120)..fly(130);
        expect(sim.demands, lessThanOrEqualTo(sim.refreshes + 1));
      });
    });

    test('a disposed pacer starts nothing', () {
      final ticks = <RefreshCallback>[];
      final delays = <void Function()>[];
      var demands = 0;
      final pacer = FramePacer(
        schedule: (tick, _) => ticks.add(tick),
        demand: () {
          demands++;
          return true;
        },
        now: () => Duration.zero,
        delay: (_, callback) => delays.add(callback),
      )..frameEnded();
      // Waits for the refresh, then for the delay after it.
      pacer.frameEnded();
      ticks.removeAt(0)();
      expect(delays, hasLength(1));
      ticks.clear();
      pacer.dispose();

      delays.removeAt(0)();
      pacer
        ..expedite()
        ..resync()
        ..frameEnded()
        ..frameSkipped();
      expect(demands, 1);
      expect(ticks, isEmpty);
      expect(delays, isEmpty);
    });

    group('lost demands', () {
      late List<RefreshCallback> ticks;
      late List<(Duration, void Function())> delays;
      late int demands;
      late bool armed;
      late Duration time;
      late FramePacer pacer;

      setUp(() {
        ticks = [];
        delays = [];
        demands = 0;
        armed = true;
        time = const Duration(seconds: 1);
        pacer = FramePacer(
          schedule: (tick, _) => ticks.add(tick),
          demand: () {
            if (!armed) return false;
            demands++;
            return true;
          },
          now: () => time,
          delay: (duration, callback) => delays.add((duration, callback)),
        )..frameEnded();
      });

      void runDelay() => delays.removeAt(0).$2();

      test('a demand that could not arm retries, longer each time', () {
        armed = false;
        time += const Duration(milliseconds: 4);
        pacer.frameEnded();
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        runDelay(); // The half-refresh delay: the demand finds no target.
        expect(demands, 1);
        expect(pacer.idle, isFalse, reason: 'the pacer keeps trying');
        final first = delays.first.$1;
        runDelay();
        expect(delays.first.$1, greaterThan(first));
        expect(demands, 1);
        armed = true;
        runDelay();
        expect(demands, 2);
        expect(pacer.idle, isTrue);
      });

      test('a target turning back on during the wait lands a demand', () {
        armed = false;
        time += const Duration(milliseconds: 4);
        pacer.frameEnded();
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        expect(delays, hasLength(1));
        armed = true;
        runDelay();
        expect(demands, 2);
      });

      test('a target turning off then on during the delay lands a demand', () {
        time += const Duration(milliseconds: 4);
        pacer.frameEnded();
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        armed = false;
        runDelay();
        expect(demands, 1);
        armed = true;
        for (var i = 0; i < 8 && demands == 1; i++) {
          runDelay();
        }
        expect(demands, 2);
      });

      test('a retry stops backing off once a demand arms', () {
        armed = false;
        pacer.resync();
        final first = delays.first.$1;
        runDelay();
        armed = true;
        runDelay();
        armed = false;
        pacer.resync();
        expect(delays.first.$1, first);
      });

      test('a frame that rendered nothing is paced like one that did', () {
        time += const Duration(milliseconds: 4);
        pacer.frameSkipped();
        expect(demands, 1, reason: 'no refresh passed since the last demand');
        time += const Duration(milliseconds: 12);
        ticks.removeAt(0)();
        expect(delays, hasLength(1));
        runDelay();
        expect(demands, 2);
      });

      test('repeated results that render nothing back off', () {
        final waits = <Duration>[];
        for (var i = 0; i < 8; i++) {
          time += const Duration(seconds: 1);
          ticks.clear();
          pacer.frameSkipped();
          if (delays.isNotEmpty) {
            waits.add(delays.first.$1);
            runDelay();
          }
        }
        expect(waits, isNotEmpty);
        expect(waits.last, greaterThan(waits.first));
        expect(waits.last, lessThanOrEqualTo(const Duration(seconds: 1)));
      });

      test('a resync demands when the renderer lost its frame', () {
        expect(pacer.idle, isTrue);
        pacer.resync();
        expect(demands, 2);
      });
    });

    group('the stand-in', () {
      late List<(RefreshCallback, Duration)> ticks;
      late Duration time;
      var visible = true;
      late FramePacer pacer;

      setUp(() {
        ticks = [];
        visible = true;
        time = const Duration(seconds: 1);
        pacer = FramePacer(
          schedule: (tick, standIn) => ticks.add((tick, standIn)),
          demand: () => true,
          now: () => time,
          delay: (_, callback) => callback(),
          framesVisible: () => visible,
        )..frameEnded();
      });

      test('waits at least 20 ms and 1.5 times the interval', () {
        expect(ticks.single.$2, const Duration(microseconds: 25000));
      });

      test('backs off while frames are off, and not while they are on', () {
        void standInTicks(int count) {
          for (var i = 0; i < count; i++) {
            time += const Duration(milliseconds: 20);
            pacer.frameEnded();
            ticks.removeAt(0).$1(fromDisplay: false);
          }
        }

        standInTicks(40);
        final on = ticks.first.$2;
        expect(on, const Duration(microseconds: 25000));
        visible = false;
        standInTicks(40);
        expect(ticks.first.$2, greaterThan(on));
        expect(
          ticks.first.$2,
          lessThanOrEqualTo(const Duration(milliseconds: 500)),
        );
      });

      test('a display frame resets the back-off', () {
        visible = false;
        for (var i = 0; i < 40; i++) {
          time += const Duration(milliseconds: 20);
          pacer.frameEnded();
          ticks.removeAt(0).$1(fromDisplay: false);
        }
        expect(ticks.first.$2, greaterThan(const Duration(milliseconds: 25)));
        pacer.frameEnded();
        ticks.removeAt(0).$1();
        expect(ticks.first.$2, const Duration(microseconds: 25000));
      });
    });

    test('a refresh that a frame waited for demands it', () {
      final ticks = <RefreshCallback>[];
      var demands = 0;
      final pacer = FramePacer(
        schedule: (tick, _) => ticks.add(tick),
        demand: () {
          demands++;
          return true;
        },
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
