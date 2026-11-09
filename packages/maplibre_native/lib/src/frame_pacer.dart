import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Asks for one call of the given function at the display's next refresh.
typedef ScheduleRefresh = void Function(VoidCallback onRefresh);

/// Paces a renderer to the display: at most one demand of a map frame per
/// display refresh, plus the one the renderer starts with, and never a
/// refresh's wait for a frame that the map has not been asked for.
///
/// A frame that ends and finds a refresh since the previous demand demands
/// the next one at once, so a frame longer than a refresh renders back to
/// back instead of waiting for the next refresh, which would halve the frame
/// rate. A frame that ends within its refresh waits for the next one.
///
/// While the map is idle it asks for no refresh: the demand it has armed
/// renders the map's next change the moment it comes.
final class FramePacer {
  /// Creates a pacer that demands frames through [demand] and asks for
  /// refreshes through [schedule].
  FramePacer({required this.schedule, required this.demand});

  /// Asks for a display refresh.
  final ScheduleRefresh schedule;

  /// Asks the renderer for the next frame.
  final VoidCallback demand;

  /// Whether a refresh passed since the last demand.
  var _credit = true;

  /// Whether a finished frame waits for a refresh to demand the next one.
  var _waiting = false;

  /// Whether a refresh is asked for.
  var _scheduled = false;

  /// Tells the pacer that the frame it demanded last finished and that the
  /// next one is due.
  void frameEnded() {
    if (_credit) {
      _demandNext();
    } else {
      _waiting = true;
    }
    if (!_credit && !_scheduled) {
      _scheduled = true;
      schedule(_onRefresh);
    }
  }

  void _demandNext() {
    _credit = false;
    _waiting = false;
    demand();
  }

  void _onRefresh() {
    _scheduled = false;
    if (_waiting) {
      _demandNext();
      if (!_scheduled) {
        _scheduled = true;
        schedule(_onRefresh);
      }
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
/// all while frames are disabled, so a timer stands in after two refreshes
/// at 60 Hz.
final class FlutterFrameClock {
  int? _callbackId;
  Timer? _fallback;

  /// See [FlutterFrameClock].
  void schedule(VoidCallback onRefresh) {
    assert(_callbackId == null, 'one refresh at a time');
    void fire() {
      final callbackId = _callbackId;
      if (callbackId == null) return;
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
      _callbackId = null;
      _fallback?.cancel();
      _fallback = null;
      onRefresh();
    }

    _callbackId = SchedulerBinding.instance.scheduleFrameCallback(
      (_) => fire(),
    );
    _fallback = Timer(const Duration(milliseconds: 34), fire);
  }

  /// Forgets a requested refresh.
  void cancel() {
    final callbackId = _callbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
    }
    _callbackId = null;
    _fallback?.cancel();
    _fallback = null;
  }
}
