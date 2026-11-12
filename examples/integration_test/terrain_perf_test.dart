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
// --dart-define=TERRAIN_PERF_BASEMAP=<style URL> also draws that basemap
// under the hillshade and the trail, as an app does, over Mapterhorn's DEM
// unless TERRAIN_PERF_DEM names another.
// --dart-define=TERRAIN_PERF_USER_LOCATION=true also shows a
// UserLocationLayer that stays in view, with its accuracy and a heading
// that turns, updated 30 times a second: the worst case of a compass.
// --dart-define=TERRAIN_PERF_SKY=on adds a sky to the style and also flies
// at pitch 30, where its horizon is off screen; =off flies at pitch 30
// without one. Compare the two runs' pitch_30 frames: the sky must cost
// nothing when no horizon is in view. Informational, not part of the gate.
// --dart-define=TERRAIN_PERF_STYLE=true-earth draws the style gallery's True
// Earth look instead (Sentinel-2 imagery, OpenFreeMap labels and paths, and
// its sky) over Mapterhorn's DEM, with the trail.
// --dart-define=TERRAIN_PERF_PITCHES=50,60,70 picks the pitches of the
// flights (default 50,60). The gate applies from pitch 50 up.
// --dart-define=TERRAIN_PERF_LOAD_MODE=quality, balanced or performance sets
// the terrain load mode first; empty keeps the map's default.
// The report also holds the map frames of the zoom over the trail during the
// rendering scrub (zoom_over_trail), which the gate leaves out.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/gallery_places.dart';
import 'shared/gallery_styles.dart';
import 'shared/terrain_load.dart';
import 'shared/test_map.dart';

const _informational = bool.fromEnvironment('TERRAIN_PERF_INFORMATIONAL');

/// A TileJSON URL of a Terrarium DEM to fly over instead of the fixture.
const _networkDem = String.fromEnvironment('TERRAIN_PERF_DEM');

/// A style URL of a basemap to draw under the terrain's hillshade and trail.
const _basemap = String.fromEnvironment('TERRAIN_PERF_BASEMAP');

const _mapterhorn = 'https://tiles.mapterhorn.com/tilejson.json';

const _userLocation = bool.fromEnvironment('TERRAIN_PERF_USER_LOCATION');

/// `on` or `off`: fly at pitch 30 too, with or without [_sky]. Empty: neither.
const _skyVariant = String.fromEnvironment('TERRAIN_PERF_SKY');

/// `true-earth`: the gallery's True Earth style. Empty: the trail style.
const _styleVariant = String.fromEnvironment('TERRAIN_PERF_STYLE');

/// The pitches of the flights.
final List<double> _pitches = const String.fromEnvironment(
  'TERRAIN_PERF_PITCHES',
  defaultValue: '50,60',
).split(',').map((pitch) => double.parse(pitch.trim())).toList();

/// `quality`, `balanced` or `performance`. Empty: the map's default.
const _loadMode = String.fromEnvironment('TERRAIN_PERF_LOAD_MODE');

/// The gallery's True Earth style over the synthetic ridge's real place, with
/// the trail of [trailStyle] on top, from the gallery's public sources.
Map<String, Object?> _trueEarthStyle() {
  final style = jsonDecode(
    galleryStyle(
      GalleryLook.trueEarth,
      const GalleryPlace(
        name: 'Ridge',
        center: Geographic(lon: alpsLng, lat: alpsLat),
        zoom: 13,
        pitch: 60,
        bearing: 0,
        terrainClass: TerrainClass.alpine,
        inUs: false,
      ),
      demUrl: 'https://tiles.mapterhorn.com/{z}/{x}/{y}.webp',
      basemapTileJson: 'https://tiles.openfreemap.org/planet',
      imageryUs: '',
      imageryWorld: 'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg',
    ),
  ) as Map<String, Object?>;
  final trail = trailStyle({
    'sources': <String, Object?>{},
    'layers': <Object?>[],
  }, demId: 'dem');
  return {
    ...style,
    'sources': {
      ...(style['sources']! as Map<String, Object?>),
      ...(trail['sources']! as Map<String, Object?>),
    },
    'layers': [
      ...(style['layers']! as List<Object?>),
      for (final layer in trail['layers']! as List<Object?>)
        if ((layer! as Map<String, Object?>)['type'] == 'line') layer,
    ],
  };
}

/// The sky of the True Earth outdoor style.
const Map<String, Object> _sky = {
  'sky-color': '#3E7CC0',
  'horizon-color': '#DCE7EF',
  'fog-color': '#C6D4E0',
  'sky-horizon-blend': 0.85,
  'horizon-fog-blend': 0.75,
  'fog-ground-blend': 0.35,
  'atmosphere-blend': 0.9,
};

/// A location just ahead of the camera's center, so it stays in view
/// during the flights, turning 3° every 33 ms.
Stream<UserLocation> _locationsInView(MapController controller) =>
    Stream.periodic(const Duration(microseconds: 33334), (tick) {
      final center = controller.getCamera().center;
      return UserLocation(
        position: Geographic(lon: center.lon, lat: center.lat - 0.002),
        accuracy: 30,
        heading: tick * 3.0 % 360,
      );
    });

/// [basemap] with the raster DEM source `alps` of [dem], and the hillshade
/// and trail of [trailStyle] under its labels.
Map<String, Object?> _overBasemap(Map<String, Object?> basemap, String dem) {
  final layers = (basemap['layers']! as List<Object?>).toList();
  final labels = layers.indexWhere(
    (layer) => (layer! as Map<String, Object?>)['type'] == 'symbol',
  );
  final at = labels < 0 ? layers.length : labels;
  final trail = trailStyle({
    'sources': {
      'alps': {'type': 'raster-dem', 'url': dem, 'encoding': 'terrarium'},
    },
    'layers': <Object?>[],
  });
  return {
    ...basemap,
    'sources': {
      ...(basemap['sources']! as Map<String, Object?>),
      ...(trail['sources']! as Map<String, Object?>),
    },
    'layers': [
      ...layers.take(at),
      ...(trail['layers']! as List<Object?>),
      ...layers.skip(at),
    ],
  };
}

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
    'terrain performance gate: flights at pitch 50 and 60 (or the chosen '
    'pitches), and a scrub',
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

      const trueEarth = _styleVariant == 'true-earth';
      final basemap = _basemap.isEmpty
          ? null
          : jsonDecode((await http.get(Uri.parse(_basemap))).body)
                as Map<String, Object?>;
      final network = _networkDem.isNotEmpty || basemap != null || trueEarth;
      final base = fixture.style();
      final style = trueEarth
          ? _trueEarthStyle()
          : basemap != null
          ? _overBasemap(
              basemap,
              _networkDem.isEmpty ? _mapterhorn : _networkDem,
            )
          : network
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
      const exaggeration = trueEarth ? 1.0 : alpsExaggeration;
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(
            jsonEncode({
              ...(basemap != null || trueEarth ? style : trailStyle(style)),
              if (_skyVariant == 'on') 'sky': _sky,
            }),
          ),
          initCamera: alpsCamera,
        ),
        children: [
          if (_userLocation)
            Builder(
              builder: (context) => UserLocationLayer(
                locations: _locationsInView(
                  MapController.of(context, camera: false),
                ),
              ),
            ),
        ],
      );
      if (_loadMode.isNotEmpty) {
        await map.controller.setTerrainLoadMode(
          TerrainLoadMode.values.byName(_loadMode),
        );
      }
      await map.style.setTerrain(
        const Terrain(
          sourceId: trueEarth ? 'dem' : 'alps',
          exaggeration: exaggeration,
        ),
      );
      final recorder = MapFrameRecorder(map.controller);
      addTearDown(recorder.dispose);

      final report = <String, Object>{
        'mode': kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        'dem': network
            ? (_networkDem.isEmpty ? _mapterhorn : _networkDem)
            : 'fixture',
        'style': trueEarth ? 'true-earth' : 'trail',
        'load_mode': _loadMode.isEmpty ? 'default' : _loadMode,
        'basemap': basemap != null ? _basemap : 'none',
        'user_location': _userLocation,
        'sky': _skyVariant.isEmpty ? 'none' : _skyVariant,
      };
      // What the map got wrong, and the numbers that missed the gate.
      final failures = <String>[];
      final missed = <String>[];
      void gate(String name, double value, double limit) {
        if (value > limit) missed.add('$name: $value ms > $limit ms');
      }

      for (final pitch in [if (_skyVariant.isNotEmpty) 30.0, ..._pitches]) {
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
        if (pitch < 50) continue;
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
        if (rendering) recorder.start();
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
        if (rendering) {
          recorder.recording = false;
          final frames = DurationStats.of(recorder.mapFrameMs);
          report['zoom_over_trail'] = {
            'map_frames': frames.toJson(),
            'median_fps': frames.medianFps.toStringAsFixed(1),
          };
          debugPrint('terrain perf: zoom over the trail map frames $frames');
        }
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
