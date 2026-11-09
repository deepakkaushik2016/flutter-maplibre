import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Called at a refresh. [fromDisplay] is false for a stand-in that no display
/// frame timed.
typedef RefreshCallback = void Function({bool fromDisplay});

/// Asks for one call of the given function at the display's next refresh,
/// or after the given stand-in time if no Flutter frame comes first.
typedef ScheduleRefresh = void Function(
  RefreshCallback onRefresh,
  Duration standIn,
);

/// Runs a function after a duration.
typedef Delay = void Function(Duration duration, VoidCallback callback);

/// Paces a renderer to the display: at most one armed demand of a map frame
/// per display refresh, plus the one the renderer starts with.
///
/// A frame longer than a refresh demands the next one at once, so long
/// frames render back to back instead of waiting for a refresh, which would
/// halve the frame rate. A shorter frame's next demand goes out half a
/// refresh after the last refresh. Demanded at the refresh itself, 3D frames
/// on an iPhone 15 Plus (13.9 ms from demand to shown at the median, 18 ms at
/// p90) land on either side of the next one, so they miss it or bunch; from
/// the middle of a refresh they land on the same side. The cost is half a
/// refresh of age for the frames of an animation. [expedite] takes that out
/// for a gesture.
///
/// A demand the renderer could not arm, as while it is paused or has no
/// target, and a result that rendered nothing, are retried with a growing
/// delay, so the map recovers by itself and a failed session can't spin.
///
/// While the map is idle it asks for no refresh: the demand it has armed
/// renders the map's next change the moment it comes.
final class FramePacer {
  /// Creates a pacer that demands frames through [demand], asks for
  /// refreshes through [schedule], and times its demands with [now] and
  /// [delay]. [displayInterval] seeds the refresh interval, and
  /// [framesVisible] says whether Flutter draws frames at all.
  FramePacer({
    required this.schedule,
    required this.demand,
    required this.now,
    required this.delay,
    Duration? Function()? displayInterval,
    this.framesVisible,
  }) : _interval = displayInterval?.call() ?? _defaultInterval;

  /// Asks for a display refresh.
  final ScheduleRefresh schedule;

  /// Asks the renderer for the next frame. Returns whether a frame is armed.
  final bool Function() demand;

  /// The time on a monotonic clock.
  final Duration Function() now;

  /// Runs a function later.
  final Delay delay;

  /// Whether Flutter draws frames at all: false while the app or window is
  /// hidden. Null means it does.
  final bool Function()? framesVisible;

  /// The time between refreshes when the display's rate is unknown.
  static const _defaultInterval = Duration(microseconds: 16667);

  /// The longest wait between retries of a demand.
  static const _maxBackoff = Duration(seconds: 1);

  /// The shortest time a stand-in waits for a Flutter frame.
  static const _minStandIn = Duration(milliseconds: 20);

  /// The longest a stand-in waits while Flutter draws no frames.
  static const _maxStandIn = Duration(milliseconds: 500);

  /// How many stand-ins in a row come before they back off, when no frames
  /// are drawn.
  static const _standInsBeforeBackoff = 30;

  /// How many samples in a row outside the estimate's range replace it, so a
  /// display that changes its rate is relearned.
  static const _samplesToReseed = 8;

  /// A longer gap than this between two refreshes says nothing about the
  /// display's rate.
  static const _maxSample = Duration(milliseconds: 100);

  /// How many results in a row rendered nothing before retries back off.
  static const _skipsBeforeBackoff = 2;

  /// Whether a refresh passed since the last demand.
  var _credit = true;

  /// Whether a finished frame waits for a refresh to demand the next one.
  var _waiting = false;

  /// Whether a refresh is asked for.
  var _scheduled = false;

  /// Whether the next demand waits for its [delay].
  var _delaying = false;

  /// Tells a [delay] that was overtaken to do nothing.
  var _delayGeneration = 0;

  /// Whether a gesture's frame waits for the next demand, without a delay.
  var _expedited = false;

  /// How many demands in a row could not arm.
  var _unarmed = 0;

  /// How many results in a row rendered nothing.
  var _skipped = 0;

  /// How many stand-in refreshes came in a row.
  var _standIns = 0;

  /// How many samples in a row fell outside the estimate's range.
  var _outOfWindow = 0;

  Duration? _lastRefresh;
  Duration? _lastDemand;
  Duration _interval;

  /// Whether [dispose] ended the pacer, which starts nothing from then on.
  var _disposed = false;

  /// Stops the pacer: no later call demands a frame or starts a timer.
  void dispose() {
    _disposed = true;
    _delayGeneration++;
  }

  /// Whether the pacer has no demand waiting to go out.
  bool get idle => !_waiting && !_delaying;

  /// Tells the pacer that the frame it demanded last rendered and ended, and
  /// that the next one is due.
  void frameEnded() {
    if (_disposed) return;
    _skipped = 0;
    _next();
  }

  /// Tells the pacer that the demand ended without a frame. Paced like one
  /// that rendered, and after a few in a row with a growing delay.
  void frameSkipped() {
    if (_disposed) return;
    if (_delaying) return;
    _skipped++;
    if (_skipped > _skipsBeforeBackoff) {
      _delayDemand(_backoff(_skipped - _skipsBeforeBackoff));
    } else {
      _next();
    }
  }

  void _next() {
    if (_delaying) return;
    final time = now();
    final last = _lastDemand;
    if (_credit && (_expedited || last == null || time - last >= _interval)) {
      // A long frame, a gesture's, or the first after rest: at once. It must
      // have seen a refresh, so a wrong estimate can't outrun the display.
      _demandNext();
      _askForRefresh();
    } else if (_credit) {
      // A refresh passed while the frame ran: the next demand keeps its
      // place ahead of the refresh after it, so frames don't bunch.
      _credit = false;
      final target = (_lastRefresh ?? time) + _phase;
      _delayDemand(target > time ? target - time : Duration.zero);
    } else {
      _waiting = true;
      _askForRefresh();
    }
  }

  /// The time after a refresh at which a paced demand goes out.
  Duration get _phase => _interval ~/ 2;

  Duration _backoff(int attempt) {
    final backoff = _interval * (1 << attempt.clamp(0, 16));
    return backoff > _maxBackoff ? _maxBackoff : backoff;
  }

  /// Demands the next frame after [wait].
  void _delayDemand(Duration wait) {
    final generation = ++_delayGeneration;
    _delaying = true;
    delay(wait, () {
      if (generation != _delayGeneration) return;
      _delaying = false;
      _demandNext();
      _askForRefresh();
    });
  }

  /// Tells the pacer that a gesture changed the camera: its frame goes out
  /// as soon as the display can show one more, without the delay, also when
  /// the gesture arrives with a frame in flight.
  void expedite() {
    if (_disposed) return;
    if (_delaying) {
      _delayGeneration++;
      _delaying = false;
      _demandNext();
      _askForRefresh();
    } else {
      _expedited = true;
    }
  }

  /// Demands a frame for a renderer that has none in flight and nothing
  /// armed, so a touch or an event always gets the map going again.
  void resync() {
    if (_disposed) return;
    _demandNext();
    _askForRefresh();
  }

  void _askForRefresh() {
    if (_scheduled) return;
    _scheduled = true;
    schedule(_onRefresh, _standInTime);
  }

  /// How long a stand-in waits for a Flutter frame: longer than a refresh,
  /// so a slow Flutter frame is rarely taken over, and growing while no
  /// frames are drawn, so a hidden map doesn't render frames nobody sees.
  Duration get _standInTime {
    final standIn = _interval * 3 ~/ 2;
    final base = standIn > _minStandIn ? standIn : _minStandIn;
    if (_standIns <= _standInsBeforeBackoff ||
        (framesVisible?.call() ?? true)) {
      return base;
    }
    final doublings = (_standIns - _standInsBeforeBackoff).clamp(0, 16);
    final backedOff = base * (1 << doublings);
    return backedOff > _maxStandIn ? _maxStandIn : backedOff;
  }

  void _demandNext() {
    if (!demand()) {
      _unarmed++;
      _waiting = false;
      _delayDemand(_backoff(_unarmed));
      return;
    }
    _unarmed = 0;
    _credit = false;
    _waiting = false;
    _expedited = false;
    _lastDemand = now();
  }

  /// A Flutter frame arrived with no refresh asked for: only its time counts.
  void noteDisplayFrame() {
    if (_disposed) return;
    _standIns = 0;
    _learn(now());
  }

  void _learn(Duration time) {
    final last = _lastRefresh;
    _lastRefresh = time;
    if (last == null) return;
    final sample = time - last;
    if (sample >= _interval * 0.4 && sample <= _interval * 1.5) {
      // The estimate moves slowly past a Flutter frame's jitter.
      _interval = _interval * 0.9 + sample * 0.1;
      _outOfWindow = 0;
    } else if (sample <= _maxSample && ++_outOfWindow >= _samplesToReseed) {
      // Several in a row: the display changed its rate.
      _interval = sample;
      _outOfWindow = 0;
    } else if (sample > _maxSample) {
      _outOfWindow = 0;
    }
  }

  void _onRefresh({bool fromDisplay = true}) {
    _scheduled = false;
    if (_disposed) return;
    final time = now();
    if (fromDisplay) {
      _standIns = 0;
      _learn(time);
    } else {
      _standIns++;
    }
    // Consecutive refreshes are what tell the display's rate, so keep asking
    // while frames were demanded lately. A map at rest stops asking.
    final lastDemand = _lastDemand;
    if (lastDemand != null && time - lastDemand < _interval * 2) {
      _askForRefresh();
    }
    if (_waiting && (_expedited || !fromDisplay)) {
      // Without a display frame there is no refresh to keep a place ahead of.
      _demandNext();
    } else if (_waiting) {
      _waiting = false;
      _delayDemand(_phase);
    } else {
      _credit = true;
    }
  }
}

/// The display refreshes of a [FramePacer], from Flutter's frame clock:
/// [schedule] requests a frame and runs its callback there, at the display's
/// real rate, 60 Hz on most phones and 120 Hz on ProMotion.
///
/// A Flutter frame need not come while the app draws none, as under a
/// `flutter_test` frame policy without a pump, or at all while frames are
/// disabled, so a timer stands in after the time the pacer gives. A display
/// callback outlives a stand-in, so its frame still tells the pacer the
/// display's rate.
final class FlutterFrameClock {
  int? _callbackId;
  Timer? _fallback;
  Timer? _delay;
  RefreshCallback? _onRefresh;

  /// Called for a Flutter frame that came with no refresh asked for.
  VoidCallback? onDisplayFrame;

  /// See [FlutterFrameClock].
  void schedule(RefreshCallback onRefresh, Duration standIn) {
    assert(_onRefresh == null, 'one refresh at a time');
    _onRefresh = onRefresh;
    _callbackId ??= SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
    _fallback = Timer(standIn, _onStandIn);
  }

  void _onFrame(Duration _) {
    _callbackId = null;
    _fallback?.cancel();
    _fallback = null;
    final onRefresh = _onRefresh;
    _onRefresh = null;
    if (onRefresh != null) {
      onRefresh(fromDisplay: true);
    } else {
      onDisplayFrame?.call();
    }
  }

  void _onStandIn() {
    _fallback = null;
    final onRefresh = _onRefresh;
    _onRefresh = null;
    onRefresh?.call(fromDisplay: false);
  }

  /// See [Delay].
  void delay(Duration duration, VoidCallback callback) {
    _delay?.cancel();
    _delay = Timer(duration, callback);
  }

  /// Forgets a requested refresh and a running delay.
  void cancel() {
    _delay?.cancel();
    _delay = null;
    final callbackId = _callbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    _callbackId = null;
    _fallback?.cancel();
    _fallback = null;
    _onRefresh = null;
  }
}
