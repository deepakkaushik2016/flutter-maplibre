// The performance gate of the 3D terrain, kept out of all_test.dart because
// it measures, in a profile or release build on a device:
//
//   cd examples && flutter drive --profile \
//     --driver test_driver/integration_test.dart \
//     --target integration_test/terrain_perf_test.dart -d <device>
//
// The numbers land in build/integration_response_data.json.
// --dart-define=TERRAIN_PERF_INFORMATIONAL=true reports them without the
// gate, as on an emulator, whose GPU says nothing about a phone's.
// --dart-define=TERRAIN_PERF_DEM=<TileJSON URL> flies over that DEM from
// the network instead of the vendored fixture, as over Mapterhorn's.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/terrain_load.dart';
import 'shared/test_map.dart';

const _informational = bool.fromEnvironment('TERRAIN_PERF_INFORMATIONAL');

/// A TileJSON URL of a Terrarium DEM to fly over instead of the fixture.
const _networkDem = String.fromEnvironment('TERRAIN_PERF_DEM');

/// The gate: the map's median frame time, its 95th percentile and its
/// longest frame after the warm-up, and the 95th percentile of the latency
/// from a scrub position to its elevation, in ms.
const _medianMs = 16.7;
const _p95Ms = 25.0;
const _worstMs = 250.0;
const _scrubP95Ms = 16.0;

/// The frame time of a 120 Hz display, which the median is also reported
/// against.
const double _proMotionMs = 1000 / 120;

/// How long the measured flight at each pitch lasts, after [_warmUp].
const _flight = Duration(seconds: 60);
const _warmUp = Duration(seconds: 10);

/// How far a fixture elevation may be from the synthetic DEM's height, in
/// meters, as in the terrain tests.
const _elevationTolerance = 2.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests(binding);
}

void runTests(IntegrationTestWidgetsFlutterBinding binding) {
  testWidgets(
    'terrain performance gate: flights at pitch 50 and 60, and a scrub',
    (tester) async {
      if (!_informational) {
        expect(
          kDebugMode,
          isFalse,
          reason:
              'the gate measures a profile or release build; debug builds '
              'are slower by design',
        );
      }
      final policy = binding.framePolicy;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      addTearDown(() => binding.framePolicy = policy);
      final fixture = await AlpsFixture.start();
      addTearDown(fixture.close);

      final network = _networkDem.isNotEmpty;
      final base = fixture.style();
      final style = network
          ? {
              ...base,
              'sources': {
                'alps': {
                  'type': 'raster-dem',
                  'url': _networkDem,
                  'encoding': 'terrarium',
                },
              },
            }
          : base;
      const exaggeration = alpsExaggeration;
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(trailStyle(style))),
          initCamera: alpsCamera,
        ),
      );
      await map.style.setTerrain(
        const Terrain(sourceId: 'alps', exaggeration: exaggeration),
      );
      final recorder = MapFrameRecorder(map.controller);
      addTearDown(recorder.dispose);

      final report = <String, Object>{
        'mode': kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        'dem': network ? _networkDem : 'fixture',
      };
      // What the map got wrong, and the numbers that missed the gate.
      final failures = <String>[];
      final missed = <String>[];
      void gate(String name, double value, double limit) {
        if (value > limit) missed.add('$name: $value ms > $limit ms');
      }

      for (final pitch in [50.0, 60.0]) {
        final stop = Completer<void>();
        final flight = flyOverRidge(
          map.controller,
          pitch: pitch,
          stop: stop.future,
        );
        await tester.pump(_warmUp);
        recorder.start();
        await tester.pump(_flight);
        recorder.recording = false;
        stop.complete();
        await map.pumpFuture(flight, reason: 'the last flight leg never ended');

        final mapFrames = DurationStats.of(recorder.mapFrameMs);
        final flutterFrames = DurationStats.of(recorder.flutterFrameMs);
        report['pitch_${pitch.round()}'] = {
          'map_frames': mapFrames.toJson(),
          'flutter_frames': flutterFrames.toJson(),
          'median_fps': mapFrames.medianFps.toStringAsFixed(1),
          'median_within_120hz': mapFrames.median <= _proMotionMs + 0.1,
        };
        debugPrint('terrain perf: pitch $pitch map frames $mapFrames');
        debugPrint('terrain perf: pitch $pitch Flutter frames $flutterFrames');
        expect(
          mapFrames.count,
          greaterThan(_flight.inSeconds),
          reason: 'the map showed new frames during the flight at $pitch',
        );
        gate('pitch $pitch median', mapFrames.median, _medianMs);
        gate('pitch $pitch p95', mapFrames.p95, _p95Ms);
        gate('pitch $pitch worst', mapFrames.max, _worstMs);
        gate('pitch $pitch worst Flutter frame', flutterFrames.max, _worstMs);
      }

      // The path of a scrub along an elevation profile: one position per
      // frame, each asking the map for its elevation, once with the camera
      // still and once while the map renders every frame, its camera
      // zooming in and out over the trail so that its ground stays loaded.
      Future<DurationStats> scrub({required bool rendering}) async {
        await map.controller.moveCamera(
          const CameraUpdate.position(
            center: trailCenter,
            zoom: 13,
            bearing: 0,
            pitch: 60,
          ),
        );
        await map.waitForLatestFrame();
        final stop = Completer<void>();
        final animation = rendering
            ? zoomOverTrail(map.controller, stop: stop.future)
            : Future<void>.value();
        final latencies = <double>[];
        final stopwatch = Stopwatch();
        for (final point in scrubPath()) {
          stopwatch
            ..reset()
            ..start();
          final elevation = await map.controller.queryTerrainElevation(point);
          stopwatch.stop();
          latencies.add(stopwatch.elapsedMicroseconds / 1000);
          if (elevation == null) {
            failures.add('no elevation at $point (rendering: $rendering)');
          } else if (!network) {
            final expected = alpsHeight(point.lat, point.lon) * exaggeration;
            if ((elevation - expected).abs() > _elevationTolerance) {
              failures.add('elevation $elevation at $point, not $expected');
            }
          }
          await tester.pump();
        }
        stop.complete();
        await map.pumpFuture(
          animation,
          reason: 'the last zoom over the trail never ended',
        );
        return DurationStats.of(latencies);
      }

      for (final rendering in [false, true]) {
        final latency = await scrub(rendering: rendering);
        final name = rendering ? 'scrub_rendering' : 'scrub_still';
        report[name] = latency.toJson();
        debugPrint('terrain perf: $name latency $latency');
        gate('$name p95', latency.p95, _scrubP95Ms);
      }

      binding.reportData = {...?binding.reportData, 'terrain_perf': report};
      debugPrint('terrain perf: ${jsonEncode(report)}');
      expect(failures, isEmpty);
      if (_informational) {
        debugPrint('terrain perf: informational, gate not applied: $missed');
      } else {
        expect(missed, isEmpty, reason: 'the gate');
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
