import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_web/src/loader.dart';
import 'package:maplibre_web/src/map_state.dart';
import 'package:maplibre_web/src/still_image.dart';

/// Web implementation of the federated MapLibre plugin.
final class MapLibrePlugin extends MapLibrePlatform {
  /// This static method registers [MapLibrePlugin] when running on web.
  static void registerWith(Registrar registrar) =>
      MapLibrePlatform.instance = MapLibrePlugin();

  @override
  MapLibreMapState createWidgetState() => MapLibreMapStateWeb();

  @override
  Future<OfflineManager> createOfflineManager() =>
      throw UnsupportedError('The OfflineManager can not be used on web.');

  @override
  Future<StillImageRenderer> createStillImageRenderer() async {
    await loadMapLibreGlJs();
    return StillImageRendererWeb();
  }

  @override
  bool get stillImageRendererIsSupported => true;
}
