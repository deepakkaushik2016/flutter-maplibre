// Draws the vendored DEM tiles of the 3D terrain tests from the formula in
// integration_test/shared/alps_dem.dart. Run it from examples/ after changing
// that formula:
//
//   dart run tool/alps_dem.dart
import 'dart:io';
import 'dart:typed_data';

import '../integration_test/shared/alps_dem.dart';

const _size = 256;

void main() {
  final (:x, :y) = alpsDemTiles;
  for (var tileX = x.$1; tileX <= x.$2; tileX++) {
    for (var tileY = y.$1; tileY <= y.$2; tileY++) {
      final file = File('assets/terrain/alps/$alpsDemZoom/$tileX/$tileY.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png(_terrarium(tileX, tileY)));
      stdout.writeln('${file.path}: ${file.lengthSync()} bytes');
    }
  }
}

/// The RGB rows of a Terrarium tile. MapLibre (Native and GL JS) places
/// pixel `i` at its centre, `(i + 0.5) / 256` of the tile, and reads whole
/// meters, so each pixel holds the rounded height at that point.
Uint8List _terrarium(int tileX, int tileY) {
  final rgb = Uint8List(_size * _size * 3);
  for (var row = 0; row < _size; row++) {
    for (var column = 0; column < _size; column++) {
      final (:lat, :lng) = tilePointLatLng(
        alpsDemZoom,
        tileX,
        tileY,
        (column + 0.5) / _size,
        (row + 0.5) / _size,
      );
      final value = alpsHeight(lat, lng).round() + 32768;
      final i = (row * _size + column) * 3;
      rgb[i] = value >> 8;
      rgb[i + 1] = value & 0xff;
    }
  }
  return rgb;
}

/// An 8-bit RGB PNG of [rgb], each row filtered with the PNG filter that
/// compresses it best.
Uint8List _png(Uint8List rgb) {
  const stride = _size * 3;
  final filtered = BytesBuilder();
  final previous = Uint8List(stride);
  for (var row = 0; row < _size; row++) {
    final line = rgb.sublist(row * stride, (row + 1) * stride);
    Uint8List? best;
    var bestCost = 1 << 62;
    for (var type = 0; type < 5; type++) {
      final candidate = Uint8List(stride + 1)..[0] = type;
      var cost = 0;
      for (var i = 0; i < stride; i++) {
        final a = i >= 3 ? line[i - 3] : 0;
        final b = previous[i];
        final c = i >= 3 ? previous[i - 3] : 0;
        final predicted = switch (type) {
          0 => 0,
          1 => a,
          2 => b,
          3 => (a + b) >> 1,
          _ => _paeth(a, b, c),
        };
        final value = (line[i] - predicted) & 0xff;
        candidate[i + 1] = value;
        cost += value < 128 ? value : 256 - value;
      }
      if (cost < bestCost) {
        bestCost = cost;
        best = candidate;
      }
    }
    filtered.add(best!);
    previous.setAll(0, line);
  }
  final header = ByteData(13)
    ..setUint32(0, _size)
    ..setUint32(4, _size)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  return (BytesBuilder()
        ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(
          _chunk('IDAT', ZLibEncoder(level: 9).convert(filtered.takeBytes())),
        )
        ..add(_chunk('IEND', const [])))
      .takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

List<int> _chunk(String type, List<int> data) {
  final typeAndData = [...type.codeUnits, ...data];
  return [
    ...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(),
    ...typeAndData,
    ...(ByteData(4)..setUint32(0, _crc32(typeAndData))).buffer.asUint8List(),
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 != 0 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
