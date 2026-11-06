import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre_platform_interface/src/widget/inherited_model.dart';

class App extends StatelessWidget {
  const App({
    required this.camera,
    required this.controller,
    this.children = const [],
    this.style,
    super.key,
  });

  final List<Widget> children;
  final MapController controller;
  final CameraPosition? camera;
  final StyleController? style;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MapLibre Demo',
      home: Scaffold(
        body: MapLibreInheritedModel(
          cameraPosition: camera,
          mapController: controller,
          style: style,
          child: Stack(children: children),
        ),
      ),
    );
  }
}
