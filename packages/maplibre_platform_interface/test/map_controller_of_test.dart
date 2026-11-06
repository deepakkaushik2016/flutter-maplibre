import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';
import 'package:maplibre_platform_interface/src/widget/inherited_model.dart';
import 'package:mocktail/mocktail.dart';

class _Controller extends Mock implements MapController {}

class _Style extends Mock implements StyleController {}

/// Counts its builds, with the controller it looks up.
class _Dependent extends StatelessWidget {
  const _Dependent({required this.camera, required this.builds});

  final bool camera;
  final List<MapController?> builds;

  @override
  Widget build(BuildContext context) {
    builds.add(MapController.maybeOf(context, camera: camera));
    return const SizedBox();
  }
}

/// Looks up the controller without the camera and, elsewhere in its build,
/// the camera.
class _MixedDependent extends StatelessWidget {
  const _MixedDependent({required this.builds, required this.cameraFirst});

  final List<CameraPosition?> builds;
  final bool cameraFirst;

  @override
  Widget build(BuildContext context) {
    final camera = cameraFirst ? CameraPosition.maybeOf(context) : null;
    MapController.maybeOf(context, camera: false);
    builds.add(camera ?? CameraPosition.maybeOf(context));
    return const SizedBox();
  }
}

void main() {
  group('MapController.maybeOf', () {
    final controller = _Controller();
    final style = _Style();
    final withCamera = <MapController?>[];
    final withoutCamera = <MapController?>[];
    final mixed = <CameraPosition?>[];
    final mixedCameraFirst = <CameraPosition?>[];
    // The same widgets in every frame, as MapLibreMap.children are.
    final children = Column(
      children: [
        _Dependent(camera: true, builds: withCamera),
        _Dependent(camera: false, builds: withoutCamera),
        _MixedDependent(builds: mixed, cameraFirst: false),
        _MixedDependent(builds: mixedCameraFirst, cameraFirst: true),
      ],
    );

    Widget map(double zoom, StyleController? style) => Directionality(
      textDirection: TextDirection.ltr,
      child: MapLibreInheritedModel(
        mapController: controller,
        cameraPosition: CameraPosition(
          center: const Geographic(lon: 0, lat: 0),
          zoom: zoom,
          bearing: 0,
          pitch: 0,
        ),
        style: style,
        child: children,
      ),
    );

    testWidgets('without the camera, rebuilds only for a new style', (
      tester,
    ) async {
      await tester.pumpWidget(map(1, null));
      expect(withCamera, [controller]);
      expect(withoutCamera, [controller]);
      // The camera moves.
      await tester.pumpWidget(map(2, null));
      await tester.pumpWidget(map(3, null));
      expect(withCamera, hasLength(3));
      expect(withoutCamera, hasLength(1));
      // A style loads.
      await tester.pumpWidget(map(3, style));
      expect(withCamera, hasLength(4));
      expect(withoutCamera, hasLength(2));
      await tester.pumpWidget(map(4, style));
      expect(withoutCamera, hasLength(2));
    });

    testWidgets('a widget that also reads the camera rebuilds with it', (
      tester,
    ) async {
      mixed.clear();
      mixedCameraFirst.clear();
      await tester.pumpWidget(map(1, style));
      await tester.pumpWidget(map(2, style));
      await tester.pumpWidget(map(3, style));
      expect(mixed.map((camera) => camera?.zoom), [1, 2, 3]);
      expect(mixedCameraFirst.map((camera) => camera?.zoom), [1, 2, 3]);
    });
  });
}
