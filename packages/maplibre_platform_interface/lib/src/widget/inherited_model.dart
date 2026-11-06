import 'package:flutter/widgets.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// The [InheritedModel] makes it possible to call `MapController.of(context)`.
///
/// https://api.flutter.dev/flutter/widgets/InheritedModel-class.html
class MapLibreInheritedModel extends InheritedModel<Object> {
  /// Default constructor
  const MapLibreInheritedModel({
    required super.child,
    required this.mapController,
    required this.cameraPosition,
    this.style,
    super.key,
  });

  /// The aspect of a dependent that rebuilds only when [mapController] or
  /// [style] changes, not with the camera.
  static const Object styleAspect = _Aspect('style');

  /// The aspect of a dependent that rebuilds whenever the map does, with
  /// the camera.
  static const Object cameraAspect = _Aspect('camera');

  /// [MapController] instance.
  final MapController mapController;

  /// [CameraPosition] instance.
  final CameraPosition? cameraPosition;

  /// The style that [mapController] hands out, or null while none has
  /// loaded.
  final StyleController? style;

  /// Get the [InheritedModel] that is used to inject models into the widget
  /// tree that can referenced further down in the widget tree.
  static MapLibreInheritedModel? maybeOf(BuildContext context) =>
      InheritedModel.inheritFrom<MapLibreInheritedModel>(
        context,
        aspect: cameraAspect,
      );

  /// Get the in the widget tree injected [MapController].
  /// Used in [MapController.maybeOf].
  static MapController? maybeMapControllerOf(BuildContext context) =>
      maybeOf(context)?.mapController;

  /// Get the in the widget tree injected [CameraPosition].
  /// Used in [CameraPosition.maybeOf].
  static CameraPosition? maybeCameraPositionOf(BuildContext context) =>
      maybeOf(context)?.cameraPosition;

  /// The [MapController], for a dependent that rebuilds only when it or its
  /// style changes. Used in [MapController.maybeOf].
  static MapController? maybeMapControllerOfStyle(BuildContext context) =>
      InheritedModel.inheritFrom<MapLibreInheritedModel>(
        context,
        aspect: styleAspect,
      )?.mapController;

  @override
  bool updateShouldNotify(covariant MapLibreInheritedModel oldWidget) {
    return true;
  }

  @override
  bool updateShouldNotifyDependent(
    covariant MapLibreInheritedModel oldWidget,
    Set<Object> dependencies,
  ) {
    // Only a dependent of the style alone skips the camera: one that also
    // looked up the camera, in any order, rebuilds with it.
    if (dependencies.length == 1 && dependencies.contains(styleAspect)) {
      return !identical(oldWidget.mapController, mapController) ||
          !identical(oldWidget.style, style);
    }
    return true;
  }
}

class _Aspect {
  const _Aspect(this.name);

  final String name;

  @override
  String toString() => 'MapLibreInheritedModel.${name}Aspect';
}
