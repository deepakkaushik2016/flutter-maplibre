import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:geobase/geobase.dart' show Geographic;

/// pre compiled factor to convert a coordinate in radian to degrees.
const double degree2Radian = pi / 180;

/// A list of all color names that are listed by the World Wide Web Consortium
/// (W3C) as valid color names for HTML and CSS.
const htmlColorNames = <String, String>{
  'black': '#000000',
  'silver': '#C0C0C0',
  'gray': '#808080',
  'white': '#FFFFFF',
  'maroon': '#800000',
  'red': '#FF0000',
  'purple': '#800080',
  'fuchsia': '#FF00FF',
  'green': '#008000',
  'lime': '#00FF00',
  'olive': '#808000',
  'yellow': '#FFFF00',
  'navy': '#000080',
  'blue': '#0000FF',
  'teal': '#008080',
  'aqua': '#00FFFF',
};

/// Loads the image of [provider], resolved for the device pixel ratio of the
/// first view. The caller owns the returned image and must dispose it.
Future<ui.Image> resolveImageProvider(ImageProvider provider) {
  final view = ui.PlatformDispatcher.instance.implicitView;
  final stream = provider.resolve(
    ImageConfiguration(devicePixelRatio: view?.devicePixelRatio ?? 1),
  );
  final completer = Completer<ui.Image>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      if (completer.isCompleted) {
        info.dispose();
      } else {
        completer.complete(info.image);
      }
    },
    onError: (error, stackTrace) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Whether the terrain conversions take [point]: a latitude within
/// \[-90, 90\] and a finite longitude.
bool isConvertibleLngLat(Geographic point) =>
    point.lat.isFinite && point.lat.abs() <= 90 && point.lon.isFinite;

/// How many points one terrain conversion of a list answers at a time.
///
/// Measured for 5,000 points over the synthetic ridge: on a Pixel 8 Pro one
/// query of 500 points took 9 to 13 ms on the render thread, of 5,000 points
/// 61 to 100 ms; on web in Chrome on an M-series Mac, 500 points held the
/// main thread for 7 ms, 5,000 points for 84 to 89 ms. 400 keeps each part
/// near a frame of 8 ms.
const terrainQueryChunkSize = 400;

/// Answers each of [lngLats] with [query], in order, and null for each point
/// that [isConvertibleLngLat] rejects, so one bad point of a list costs only
/// its own answer.
///
/// [query] gets the convertible points, at most [chunkSize] at a time, one
/// list after the other with a turn of the event loop between them, so
/// frames render between the parts. It must answer one value for each point.
Future<List<T?>> queryConvertibleLngLats<T extends Object>(
  List<Geographic> lngLats,
  Future<List<T?>> Function(List<Geographic> lngLats) query, {
  int chunkSize = terrainQueryChunkSize,
}) async {
  final indices = <int>[
    for (var i = 0; i < lngLats.length; i++)
      if (isConvertibleLngLat(lngLats[i])) i,
  ];
  final answers = List<T?>.filled(lngLats.length, null);
  for (var start = 0; start < indices.length; start += chunkSize) {
    if (start > 0) await Future<void>.delayed(Duration.zero);
    final chunk = indices.sublist(
      start,
      min(start + chunkSize, indices.length),
    );
    final answered = await query([for (final i in chunk) lngLats[i]]);
    if (answered.length != chunk.length) {
      throw StateError(
        'The platform answered ${answered.length} points for ${chunk.length}.',
      );
    }
    for (var j = 0; j < chunk.length; j++) {
      answers[chunk[j]] = answered[j];
    }
  }
  return answers;
}
