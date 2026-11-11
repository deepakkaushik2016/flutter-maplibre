// A review tool, not part of all_test.dart: renders the two outdoor looks at
// eight landscapes with the native engine and public tile sources.
//
// Run with `flutter test integration_test/style_gallery_test.dart -d macos`.
// The PNGs, the style JSON and a manifest go to `<temp>/gallery`; see
// tool/style_gallery/README.md for collecting them.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/gallery_places.dart';
import 'shared/gallery_styles.dart';

const _demUrl = 'https://tiles.mapterhorn.com/{z}/{x}/{y}.webp';
const _basemap = 'https://tiles.openfreemap.org/planet';
const _imageryUs =
    'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}';
const _imageryWorld =
    'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg';

const _size = Size(430, 760);
const _fovDegrees = 36.87;

/// The first row below the horizon of a camera at [pitch] degrees.
int _horizonRow(double pitch, int height) {
  final up = (90 - pitch) * math.pi / 180;
  final y =
      height /
      2 *
      (1 - math.tan(up) / math.tan(_fovDegrees / 2 * math.pi / 180));
  return y.isFinite ? y.clamp(0, height).ceil() : 0;
}

/// The share of pixels below the horizon whose RGB equals [background].
Future<double> _backgroundShare(
  List<int> png,
  double pitch,
  int background,
) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData())!.buffer.asUint8List();
  var match = 0;
  var total = 0;
  for (var y = _horizonRow(pitch, image.height); y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final i = (y * image.width + x) * 4;
      final rgb = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
      if (rgb == background) match++;
      total++;
    }
  }
  image.dispose();
  return total == 0 ? 0 : match / total;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('style gallery on the native engine', (tester) async {
    final renderer = await StillImageRenderer.createInstance();
    addTearDown(renderer.dispose);
    final dir = Directory('${Directory.systemTemp.path}/gallery')
      ..createSync(recursive: true);
    Directory('${dir.path}/styles').createSync();
    const only = String.fromEnvironment('GALLERY_ONLY');
    final manifest = <Map<String, Object?>>[];
    for (final look in GalleryLook.values) {
      for (final place in galleryPlaces) {
        final name = '${look.slug}-${place.slug}';
        if (only.isNotEmpty && !name.contains(only)) continue;
        final style = galleryStyle(
          look,
          place,
          demUrl: _demUrl,
          basemapTileJson: _basemap,
          imageryUs: _imageryUs,
          imageryWorld: _imageryWorld,
        );
        File('${dir.path}/styles/$name.json').writeAsStringSync(style);
        final png = await tester.runAsync(
          () => renderer.render(
            style: MapStyle.json(style),
            size: _size,
            pixelRatio: 2,
            terrain: const Terrain(sourceId: 'dem'),
            camera: place.camera,
            timeout: const Duration(seconds: 90),
          ),
        );
        final file = File('${dir.path}/$name.png')..writeAsBytesSync(png!);
        // The path is how the report collects the file.
        // ignore: avoid_print
        print('GALLERY ${file.path}');
        manifest.add({
          'name': name,
          'look': look.slug,
          'place': place.name,
          'center': [place.center.lon, place.center.lat],
          'zoom': place.zoom,
          'pitch': place.pitch,
          'bearing': place.bearing,
        });
        final background = look == GalleryLook.fieldTopo ? 0xf2efe6 : 0x2b2f2a;
        final share = await tester.runAsync(
          () => _backgroundShare(png, place.pitch, background),
        );
        expect(share, lessThan(0.02), reason: '$name is empty or flat');
      }
    }
    File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode(manifest));
  });
}
