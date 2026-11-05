// A 10-minute soak of the 3D terrain, kept out of all_test.dart because of
// its length. Run it on its own, in profile mode on a device:
//
//   cd examples && flutter drive --profile \
//     --driver test_driver/integration_test.dart \
//     --target integration_test/terrain_soak_test.dart -d <device>
//
// The RSS series and frame times land in build/integration_response_data.json.
// --dart-define=TERRAIN_SOAK_MINUTES=<n> (3 or more) shortens the soak, for
// checking that the test itself fails on a leak or a hitch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/terrain_load.dart';
import 'shared/test_map.dart';

/// How long the soak runs. RSS is sampled once a minute.
const _minutes = int.fromEnvironment('TERRAIN_SOAK_MINUTES', defaultValue: 10);

/// How often the terrain turns off or on.
const _toggleEvery = Duration(seconds: 30);

/// The exaggerations that the terrain steps through, one each time it turns
/// on.
const _exaggerations = [0.5, 1.0, 1.5, 2.0];

/// The RSS sample that the final one is compared with: after the first
/// tiles, shaders and caches settled.
const _baselineMinute = 2;

/// How much RSS may grow from the baseline sample to the final one.
const _maxGrowth = 1.15;

/// Frames before this are not checked: the first tiles, shaders and terrain
/// toggle.
const _warmUp = Duration(minutes: 1);

/// A hitch: a frame after [_warmUp] longer than this, in ms.
const _hitchMs = 250.0;

/// How many hitches the soak allows: one, which an OS interruption (a
/// notification, a backgrounded process, a thermal step) can cause on its
/// own. A hitch of the map's own recurs, at the terrain toggles every 30 s
/// or along the flight, so it shows up at least twice.
const _maxHitches = 1;

/// The longest frame allowed at all after [_warmUp], in ms: a stall no
/// interruption explains.
const _maxFrameMs = 1000.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests(binding);
}

void runTests(IntegrationTestWidgetsFlutterBinding binding) {
  testWidgets('terrain soak: no leak and no hitch over $_minutes minutes', (
    tester,
  ) async {
    expect(
      _minutes,
      greaterThan(_baselineMinute),
      reason: 'the final RSS sample must follow the baseline one',
    );
    // Every frame that the map's texture or the framework requests runs,
    // as in an app.
    final policy = binding.framePolicy;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    addTearDown(() => binding.framePolicy = policy);
    final fixture = await AlpsFixture.start();
    addTearDown(fixture.close);

    var exaggeration = 0;
    Terrain terrain() => Terrain(
      sourceId: 'alps',
      exaggeration: _exaggerations[exaggeration++ % _exaggerations.length],
    );
    final map = await pumpMap(
      tester,
      options: MapOptions(
        style: MapStyle.json(jsonEncode(trailStyle(fixture.style()))),
        initCamera: alpsCamera,
      ),
    );
    await map.style.setTerrain(terrain());
    await map.pumpUntil(
      () => fixture.demRequests > 0,
      reason: () => 'the terrain never loaded the DEM',
    );

    final recorder = MapFrameRecorder(map.controller);
    addTearDown(recorder.dispose);
    final stop = Completer<void>();
    final flight = flyOverRidge(map.controller, pitch: 60, stop: stop.future);

    final rss = <int>[ProcessInfo.currentRss];
    final clock = Stopwatch()..start();
    var terrainOn = true;
    var toggles = 0;
    var warm = false;
    while (clock.elapsed < const Duration(minutes: _minutes)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!warm && clock.elapsed >= _warmUp) {
        warm = true;
        recorder.start();
      }
      if (clock.elapsed >= _toggleEvery * (toggles + 1)) {
        toggles++;
        terrainOn = !terrainOn;
        await map.style.setTerrain(terrainOn ? terrain() : null);
      }
      if (clock.elapsed >= Duration(minutes: rss.length)) {
        rss.add(ProcessInfo.currentRss);
        debugPrint(
          'terrain soak: minute ${rss.length - 1}, '
          'RSS ${_mb(rss.last)} MB, terrain ${terrainOn ? 'on' : 'off'}',
        );
      }
    }
    // The sample at the end of the last minute, unless the last pump
    // already took it.
    if (rss.length == _minutes) rss.add(ProcessInfo.currentRss);
    recorder.recording = false;
    stop.complete();
    await map.pumpFuture(flight, reason: 'the last flight leg never ended');

    final mapFrames = DurationStats.of(recorder.mapFrameMs);
    final flutterFrames = DurationStats.of(recorder.flutterFrameMs);
    final baseline = rss[_baselineMinute];
    final limit = (baseline * _maxGrowth).round();
    final report = {
      'minutes': _minutes,
      'mode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'rss_mb': [for (final sample in rss) _mb(sample)],
      'rss_limit_mb': _mb(limit),
      'terrain_toggles': toggles,
      'map_frames': mapFrames.toJson(),
      'flutter_frames': flutterFrames.toJson(),
      'map_hitches': recorder.mapFrameMs.where((ms) => ms > _hitchMs).length,
      'flutter_hitches': recorder.flutterFrameMs
          .where((ms) => ms > _hitchMs)
          .length,
    };
    binding.reportData = {...?binding.reportData, 'terrain_soak': report};
    debugPrint('terrain soak: ${jsonEncode(report)}');

    expect(
      toggles,
      greaterThanOrEqualTo(_minutes * 2 - 1),
      reason: 'the terrain turned off and on every 30 s',
    );
    expect(
      mapFrames.count,
      greaterThan(0),
      reason: 'the map showed new frames after the warm-up',
    );
    expect(
      rss.last,
      lessThanOrEqualTo(limit),
      reason:
          'RSS grew from ${_mb(baseline)} MB at minute $_baselineMinute '
          'to ${_mb(rss.last)} MB, more than ${((_maxGrowth - 1) * 100).round()} %: '
          '${report['rss_mb']}',
    );
    for (final (name, frames, stats) in [
      ('map', recorder.mapFrameMs, mapFrames),
      ('Flutter', recorder.flutterFrameMs, flutterFrames),
    ]) {
      final hitches = frames.where((ms) => ms > _hitchMs).toList();
      expect(
        hitches.length,
        lessThanOrEqualTo(_maxHitches),
        reason: '$name frames after the warm-up over $_hitchMs ms: $hitches',
      );
      expect(
        stats.max,
        lessThanOrEqualTo(_maxFrameMs),
        reason: 'a $name frame after the warm-up took ${stats.max} ms',
      );
    }
  }, timeout: const Timeout(Duration(minutes: _minutes + 5)));
}

int _mb(int bytes) => (bytes / (1 << 20)).round();
