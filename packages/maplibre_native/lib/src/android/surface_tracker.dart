import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maplibre_native/src/frame_target.dart';

/// Tracks whether the Surface of an Android map exists and moves the session
/// back onto it, whatever the order in which Flutter's Surface events, the
/// session and the renderer arrive.
///
/// Flutter takes the Surface away while the app is in the background, which
/// can happen while the renderer is still being created, so the flag follows
/// the events and doesn't depend on a renderer being there to receive them.
final class SurfaceTracker {
  /// Creates a tracker that moves the session to the current Surface through
  /// [setSurface] and has it let go of the Surface through [releaseTarget].
  SurfaceTracker({required this.setSurface, required this.releaseTarget});

  /// Moves the session to the Surface that exists now.
  final Future<void> Function(FrameTargetHost host) setSurface;

  /// Has the session let go of its Surface.
  final Future<void> Function() releaseTarget;

  FrameTargetHost? _host;
  var _hasSession = false;
  var _available = true;
  var _retargetOnHost = false;

  /// Counts the Surface events, so that a retarget that a newer event
  /// overtook leaves the flag to that event.
  var _generation = 0;

  /// Whether a Surface exists for the session to present to.
  bool get available => _available;

  /// The session attached, to the Surface that exists now.
  void attached() {
    _hasSession = true;
    _available = true;
    _retargetOnHost = false;
  }

  /// The renderer that owns the target, once it exists.
  FrameTargetHost? get host => _host;

  /// A Surface that came back before the renderer existed moves the session
  /// now.
  set host(FrameTargetHost? host) {
    _host = host;
    if (host != null && _retargetOnHost) {
      _retargetOnHost = false;
      _retarget(host);
    }
  }

  /// The Surface went away.
  void lost() {
    _generation++;
    _available = false;
    _retargetOnHost = false;
    final host = _host;
    if (host == null || host.disposed || !_hasSession) return;
    host.onGpuQueue(releaseTarget).ignore();
  }

  /// The Surface is back, maybe as a new one.
  void back() {
    _generation++;
    if (!_hasSession) {
      // The attach takes the Surface that exists then.
      _available = true;
      return;
    }
    final host = _host;
    if (host == null) {
      _retargetOnHost = true;
      return;
    }
    if (!host.disposed) _retarget(host);
  }

  /// Moves the session to the Surface on the GPU queue, and takes frames
  /// again even when that failed: the demand then ends as not ready and the
  /// renderer retries, where a false flag would refuse frames for good.
  void _retarget(FrameTargetHost host) {
    final generation = _generation;
    host.onGpuQueue(() async {
      if (host.disposed || generation != _generation) return;
      try {
        await setSurface(host);
      } on Object catch (error) {
        debugPrint('maplibre_native: moving to the Surface failed: $error');
      }
      if (host.disposed || generation != _generation) return;
      _available = true;
      host.demandFrame();
    }).ignore();
  }
}
