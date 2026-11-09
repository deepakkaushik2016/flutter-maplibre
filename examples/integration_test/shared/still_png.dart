import 'dart:typed_data';
import 'dart:ui' as ui;

/// The RGBA pixels of a decoded still image.
class StillPixels {
  StillPixels(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final Uint8List bytes;

  /// The RGBA color at [x], [y].
  List<int> colorAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return bytes.sublist(offset, offset + 4);
  }

  /// The share of pixels whose channels differ from [other]'s by more than
  /// [tolerance].
  double differenceFrom(StillPixels other, {int tolerance = 3}) {
    assert(width == other.width && height == other.height, 'different sizes');
    var different = 0;
    for (var i = 0; i < bytes.length; i += 4) {
      for (var channel = 0; channel < 4; channel++) {
        if ((bytes[i + channel] - other.bytes[i + channel]).abs() > tolerance) {
          different++;
          break;
        }
      }
    }
    return different / (width * height);
  }
}

/// Decodes the PNG of a still image.
Future<StillPixels> decodeStill(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData();
  final pixels = StillPixels(
    image.width,
    image.height,
    data!.buffer.asUint8List(),
  );
  image.dispose();
  codec.dispose();
  return pixels;
}
