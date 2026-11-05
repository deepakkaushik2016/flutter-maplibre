import 'dart:async';

import 'package:maplibre_platform_interface/src/style/terrain.dart';

/// Holds a [Terrain] that is set while a map loads a new style, until the
/// last requested style has loaded. Loading a style replaces its terrain, so
/// a terrain set meanwhile would be lost.
///
/// The platform packages share it, so this package exports it; the
/// app-facing `maplibre` package doesn't, and apps don't use it.
///
/// Each requested style gets a generation from [styleLoading]. A platform
/// reports the end of a load with the generation that was the latest when
/// the load ended, so the load of a style that a newer request replaces ends
/// nothing.
class DeferredTerrain {
  /// The generation of the latest requested style.
  var _requested = 0;

  /// The latest generation whose load ended, by loading or failing.
  var _ended = 0;

  var _disposed = false;
  Terrain? _terrain;
  final _pending = <Completer<void>>[];

  /// The generation of the latest requested style.
  int get generation => _requested;

  /// Whether a requested style is still loading, so calls wait for it.
  bool get loading => _ended < _requested && !_disposed;

  /// Called when the map starts to load a new style. Returns its generation.
  int styleLoading() => ++_requested;

  /// Keeps [terrain] while a style loads, and returns a future that completes
  /// once [styleLoaded] applied it. Returns null when no style loads, so the
  /// caller applies it at once.
  ///
  /// Only the last terrain is applied, and the future of every call completes
  /// with its result.
  Future<void>? defer(Terrain? terrain) {
    if (_disposed) return Future.error(StateError('The map was disposed.'));
    if (_ended >= _requested) return null;
    _terrain = terrain;
    final applied = Completer<void>();
    _pending.add(applied);
    return applied.future;
  }

  /// Called once the style of [generation] has loaded, before it is handed
  /// out. If no newer style was requested meanwhile, applies the deferred
  /// terrain, if any, with [apply], and completes the future of every
  /// deferred call with the result.
  ///
  /// Returns a future if [apply] does, and null otherwise, when the calls
  /// have completed already.
  Future<void>? styleLoaded(
    int generation,
    FutureOr<void> Function(Terrain? terrain) apply,
  ) {
    if (generation != _requested || _disposed) return null;
    _ended = generation;
    if (_pending.isEmpty) return null;
    final pending = List.of(_pending);
    _pending.clear();
    final terrain = _terrain;
    _terrain = null;
    try {
      if (apply(terrain) case final Future<void> applying) {
        return applying.then(
          (_) => _complete(pending),
          onError: (Object error, StackTrace stackTrace) =>
              _fail(pending, error, stackTrace),
        );
      }
    } on Object catch (error, stackTrace) {
      _fail(pending, error, stackTrace);
      return null;
    }
    _complete(pending);
    return null;
  }

  /// Called when the style of [generation] failed to load: fails the deferred
  /// calls with [error], unless a newer style was requested meanwhile.
  void styleLoadFailed(int generation, Object error) {
    if (generation != _requested || _disposed) return;
    _ended = generation;
    _terrain = null;
    _fail(List.of(_pending), error, StackTrace.current);
    _pending.clear();
  }

  /// Called when the map is disposed: fails the deferred calls, and every
  /// later one.
  void dispose() {
    _disposed = true;
    _terrain = null;
    _fail(
      List.of(_pending),
      StateError('The map was disposed before its style loaded.'),
      StackTrace.current,
    );
    _pending.clear();
  }

  static void _complete(List<Completer<void>> pending) {
    for (final applied in pending) {
      applied.complete();
    }
  }

  static void _fail(
    List<Completer<void>> pending,
    Object error,
    StackTrace stackTrace,
  ) {
    for (final applied in pending) {
      applied.completeError(error, stackTrace);
    }
  }
}
