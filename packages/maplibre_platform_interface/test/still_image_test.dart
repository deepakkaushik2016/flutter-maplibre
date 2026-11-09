import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Renderer implements StillImageRenderer {
  @override
  void dispose() {}

  @override
  Future<Uint8List> render({
    required MapStyle style,
    required Size size,
    required CameraUpdate camera,
    double pixelRatio = 1,
    Terrain? terrain,
    double? centerAltitude,
    Duration timeout = const Duration(seconds: 30),
  }) async => Uint8List(0);
}

class _Platform extends MapLibrePlatform with MockPlatformInterfaceMixin {
  final renderer = _Renderer();

  @override
  Future<StillImageRenderer> createStillImageRenderer() async => renderer;

  @override
  bool get stillImageRendererIsSupported => true;
}

void main() {
  final original = MapLibrePlatform.instance;
  tearDown(() => MapLibrePlatform.instance = original);

  test('still images are not supported without a platform', () {
    expect(StillImageRenderer.isSupported, isFalse);
    expect(StillImageRenderer.createInstance, throwsA(isA<UnsupportedError>()));
  });

  test('the platform creates the renderer', () async {
    final platform = _Platform();
    MapLibrePlatform.instance = platform;
    expect(StillImageRenderer.isSupported, isTrue);
    expect(await StillImageRenderer.createInstance(), same(platform.renderer));
  });

  test('a still image exception names its failure', () {
    expect(
      const StillImageException('no style').toString(),
      'StillImageException: no style',
    );
  });
}
