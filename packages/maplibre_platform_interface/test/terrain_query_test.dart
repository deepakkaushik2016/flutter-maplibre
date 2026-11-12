import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

void main() {
  group('queryConvertibleLngLats', () {
    const good = Geographic(lon: 11.4, lat: 47.2);

    /// Answers each point with its longitude, and records each call.
    Future<List<double?>> Function(List<Geographic>) recorder(
      List<List<Geographic>> calls,
    ) => (points) async {
      calls.add(points);
      return [for (final point in points) point.lon];
    };

    test('answers an empty list without a query', () async {
      final calls = <List<Geographic>>[];
      expect(await queryConvertibleLngLats(const [], recorder(calls)), isEmpty);
      expect(calls, isEmpty);
    });

    test(
      'answers null for bad points and queries only the good ones',
      () async {
        // Geographic clamps the latitude and wraps the longitude, so the bad
        // points that reach a platform hold NaN.
        final calls = <List<Geographic>>[];
        final points = [
          const Geographic(lon: 1, lat: double.nan),
          const Geographic(lon: 2, lat: 10),
          const Geographic(lon: double.nan, lat: 10),
          const Geographic(lon: 4, lat: 91),
          const Geographic(lon: double.infinity, lat: 10),
          const Geographic(lon: 186, lat: -90),
        ];
        expect(await queryConvertibleLngLats(points, recorder(calls)), [
          null,
          2,
          null,
          4,
          null,
          -174,
        ]);
        expect(calls, [
          [points[1], points[3], points[5]],
        ]);
      },
    );

    test('a list of only bad points makes no query', () async {
      final calls = <List<Geographic>>[];
      expect(
        await queryConvertibleLngLats(const [
          Geographic(lon: 0, lat: double.nan),
        ], recorder(calls)),
        [null],
      );
      expect(calls, isEmpty);
    });

    test('queries in chunks, in order', () async {
      final calls = <List<Geographic>>[];
      final points = [
        for (var i = 0; i < 10; i++)
          Geographic(lon: i.toDouble(), lat: i == 4 ? double.nan : 0),
      ];
      final answers = await queryConvertibleLngLats(
        points,
        recorder(calls),
        chunkSize: 4,
      );
      expect(answers, [0, 1, 2, 3, null, 5, 6, 7, 8, 9]);
      expect(calls.map((call) => call.length), [4, 4, 1]);
    });

    test('chunks of the default size', () async {
      final calls = <List<Geographic>>[];
      await queryConvertibleLngLats(
        List.filled(terrainQueryChunkSize * 2 + 1, good),
        recorder(calls),
      );
      expect(calls.map((call) => call.length), [
        terrainQueryChunkSize,
        terrainQueryChunkSize,
        1,
      ]);
    });

    test('fails when the platform answers another number of points', () {
      expect(
        queryConvertibleLngLats(const [good, good], (points) async => [1.0]),
        throwsStateError,
      );
    });
  });
}
