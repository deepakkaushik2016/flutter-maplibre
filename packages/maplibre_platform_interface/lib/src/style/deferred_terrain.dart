import 'dart:async';

import 'package:maplibre_platform_interface/src/style/terrain.dart';

/// Holds a [Terrain] that is set while a map loads a new style, until the
/// style has loaded. Loading a style replaces its terrain, so a terrain set
/// meanwhile would be lost. This is an internal class that doesn't get
/// exposed publicly.
class DeferredTerrain {
  var _styleLoading = false;
  Terrain? _terrain;
  Completer<void>? _applied;

  /// Called when the map starts to load a new style.
  void styleLoading() => _styleLoading = true;

  /// Keeps [terrain] while a style loads, and returns a future that completes
  /// once [styleLoaded] applied it. Returns null when no style loads, so the
  /// caller applies it at once.
  ///
  /// Only the last terrain is applied; the futures of earlier ones complete
  /// then too, as if they had been applied and replaced.
  Future<void>? defer(Terrain? terrain) {
    if (!_styleLoading) return null;
    final previous = _applied;
    final applied = _applied = Completer<void>();
    _terrain = terrain;
    previous?.complete();
    return applied.future;
  }

  /// Called once the new style has loaded, before it is handed out: applies
  /// the deferred terrain, if any, with [apply], and completes its future
  /// with the result.
  Future<void> styleLoaded(
    FutureOr<void> Function(Terrain? terrain) apply,
  ) async {
    _styleLoading = false;
    final applied = _applied;
    if (applied == null) return;
    _applied = null;
    final terrain = _terrain;
    _terrain = null;
    try {
      await apply(terrain);
      applied.complete();
    } on Object catch (error, stackTrace) {
      applied.completeError(error, stackTrace);
    }
  }
}
