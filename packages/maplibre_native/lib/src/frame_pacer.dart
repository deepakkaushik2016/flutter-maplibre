import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Called at a refresh. [fromDisplay] is false for a stand-in that no display
/// frame timed.
typedef RefreshCallback = void Function({bool fromDisplay});

/// Asks for one call of the given function at the display's next refresh.
typedef ScheduleRefresh = void Function(RefreshCallback onRefresh);

/// Runs a function after a duration.
typedef Delay = void Function(Duration duration, VoidCallback callback);

/// Paces a renderer to the display: at most one demand of a map frame per
/// display refresh, plus the one the renderer starts with.
///
/// A frame longer than a refresh demands the next one at once, so long
/// frames render back to back instead of waiting for a refresh, which would
/// halve the frame rate. A shorter frame's next demand goes out half a
/// refresh after the last refresh. Demanded at the refresh itself, 3D frames
/// on an iPhone 15 Plus (13.9 ms from demand to shown at the median, 18 ms at
/// p90) land on either side of the next one, so they miss it or bunch; from
/// the middle of a refresh they land on the same side. The cost is half a
/// refresh of age for the frames of an animation. [expedite] takes that out
/// for a gesture, whose frame goes out as soon as the display can show it.
///
/// While the map is idle it asks for no refresh: the demand it has armed
/// renders the map's next change the moment it comes.
final class FramePacer {
  /// Creates a pacer that demands frames through [demand], asks for
  /// refreshes through [schedule], and times its demands with [now] and
  /// [delay].
  FramePacer({
    required this.schedule,
    required this.demand,
    required this.now,
    required this.delay,
  });

  /// Asks for a display refresh.
  final ScheduleRefresh schedule;

  /// Asks the renderer for the next frame.
  final VoidCallback demand;

  /// The time on a monotonic clock.
  final Duration Function() now;

  /// Runs a function later.
  final Delay delay;

  /// The time between refreshes when no two have been seen yet.
  static const _defaultInterval = Duration(microseconds: 16667);

  /// Whether a refresh passed since the last demand.
  var _credit = true;

  /// Whether a finished frame waits for a refresh to demand the next one.
  var _waiting = false;

  /// Whether a refresh is asked for.
  var _scheduled = false;

  /// Whether the next demand waits for its [delay].
  var _delaying = false;

  /// Tells a [delay] that was overtaken by a gesture to do nothing.
  var _delayGeneration = 0;

  /// Whether a gesture waits for the next refresh's demand.
  var _expedited = false;

  Duration? _lastRefresh;
  Duration? _lastDemand;
  Duration _interval = _defaultInterval;

  /// Tells the pacer that the frame it demanded last finished and that the
  /// next one is due.
  void frameEnded() {
    if (_delaying) return;
    final time = now();
    final last = _lastDemand;
    if (last == null || time - last >= _interval) {
      // A long frame, or the first after rest: at once.
      _demandNext();
      _askForRefresh();
    } else if (_credit) {
      // A refresh passed while the frame ran: the next demand keeps its
      // place ahead of the refresh after it, so frames don't bunch.
      _credit = false;
      _delayDemand(_lastRefresh == null ? Duration.zero : _lastRefresh! - time);
    } else {
      _waiting = true;
      _askForRefresh();
    }
  }

  /// Demands the next frame [fromNow] plus half a refresh from now.
  void _delayDemand(Duration fromNow) {
    final wait = fromNow + _interval ~/ 2;
    final generation = ++_delayGeneration;
    _delaying = true;
    delay(wait.isNegative ? Duration.zero : wait, () {
      if (generation != _delayGeneration) return;
      _delaying = false;
      _demandNext();
      _askForRefresh();
    });
  }

  /// Tells the pacer that a gesture changed the camera: its frame goes out
  /// as soon as the display can show one more, without the delay.
  void expedite() {
    if (_delaying) {
      _delayGeneration++;
      _delaying = false;
      _demandNext();
      _askForRefresh();
    } else if (_waiting) {
      _expedited = true;
    }
  }

  void _askForRefresh() {
    if (_scheduled) return;
    _scheduled = true;
    schedule(_onRefresh);
  }

  void _demandNext() {
    _credit = false;
    _waiting = false;
    _expedited = false;
    _lastDemand = now();
    demand();
  }

  void _onRefresh({bool fromDisplay = true}) {
    _scheduled = false;
    final time = now();
    if (fromDisplay) {
      final last = _lastRefresh;
      _lastRefresh = time;
      if (last != null) {
        // Not every refresh is asked for, so a longer gap says nothing about
        // the display. The estimate moves slowly past a Flutter frame's
        // jitter.
        final sample = time - last;
        if (sample >= _interval * 0.4 && sample <= _interval * 1.5) {
          _interval = _interval * 0.9 + sample * 0.1;
        }
      }
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
      _delayDemand(Duration.zero);
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
/// `flutter_test` frame policy without a pump or in the background, or at
/// all while frames are disabled, so a timer stands in after 20 ms.
final class FlutterFrameClock {
  int? _callbackId;
  Timer? _fallback;
  Timer? _delay;

  /// See [FlutterFrameClock].
  void schedule(RefreshCallback onRefresh) {
    assert(_callbackId == null, 'one refresh at a time');
    void fire({required bool fromDisplay}) {
      final callbackId = _callbackId;
      if (callbackId == null) return;
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
      _callbackId = null;
      _fallback?.cancel();
      _fallback = null;
      onRefresh(fromDisplay: fromDisplay);
    }

    _callbackId = SchedulerBinding.instance.scheduleFrameCallback(
      (_) => fire(fromDisplay: true),
    );
    _fallback = Timer(
      const Duration(milliseconds: 20),
      () => fire(fromDisplay: false),
    );
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
  }
}
