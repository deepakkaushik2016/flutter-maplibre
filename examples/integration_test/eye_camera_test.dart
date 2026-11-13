import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/alps_fixture.dart';
import 'shared/browser.dart';
import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

/// The eye of the tests without a terrain: 2400 m above sea level.
const _eye = Geographic(lon: 11.4, lat: 47.3);
const _altitude = 2400.0;

/// Options of a map without the network that may look above the horizon.
MapOptions _skywardOptions({
  double zoom = 12,
  double minZoom = 0,
  double maxZoom = 22,
  CameraUpdate? initCamera,
}) {
  final options = offlineOptions(center: _eye, zoom: zoom, pitch: 40);
  return MapOptions(
    style: options.style,
    initCamera: initCamera ?? options.initCamera,
    minZoom: minZoom,
    maxZoom: maxZoom,
    maxPitch: 180,
  );
}

/// Expects the gl-js camera of [map] at [eye], [altitude] meters above sea
/// level, within [meters].
Future<MapEye> _expectEyeAt(
  TestMap map,
  Geographic eye,
  double altitude, {
  double meters = 1,
}) async {
  await map.waitForLatestFrame();
  final shown = lastMapEye()!;
  const metersPerDegree = 111320.0;
  expect(
    (shown.lat - eye.lat).abs() * metersPerDegree,
    lessThan(meters),
    reason: 'latitude ${shown.lat}',
  );
  expect(
    (shown.lon - eye.lon).abs() * metersPerDegree * 0.68,
    lessThan(meters),
    reason: 'longitude ${shown.lon}',
  );
  expect(shown.altitude, closeTo(altitude, meters));
  return shown;
}

void runTests() {
  group('CameraUpdate.fromEye', () {
    testWidgets('puts the camera at the eye above the horizon', (tester) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.controller.moveCamera(
        CameraUpdate.fromEye(
          _eye,
          bearing: 30,
          pitch: 115,
          altitude: _altitude,
        ),
      );
      final camera = map.controller.getCamera();
      expect(camera.pitch, closeTo(115, 1e-6));
      expect(camera.bearing, closeTo(30, 1e-6));
      final shown = await _expectEyeAt(map, _eye, _altitude);
      expect(shown.centerClampedToGround, isFalse);
      // The center lies along the view, above the eye, not on the ground.
      expect(shown.centerElevation, greaterThan(_altitude));
    }, skip: !kIsWeb);

    testWidgets('animates to the eye', (tester) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      final result = await map.pumpFuture(
        map.controller.animateCamera(
          CameraUpdate.fromEye(
            _eye,
            bearing: -20,
            pitch: 100,
            altitude: _altitude,
          ),
        ),
        reason: 'the animation never ended',
      );
      expect(result, CameraAnimationResult.completed);
      expect(map.controller.getCamera().pitch, closeTo(100, 1e-6));
      await _expectEyeAt(map, _eye, _altitude);
    }, skip: !kIsWeb);

    testWidgets('limits the pitch to the map and keeps the eye', (
      tester,
    ) async {
      // The default maxPitch of 60.
      final map = await pumpMap(
        tester,
        options: offlineOptions(center: _eye, zoom: 12),
      );
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.controller.moveCamera(
        CameraUpdate.fromEye(_eye, bearing: 0, pitch: 115, altitude: _altitude),
      );
      expect(map.controller.getCamera().pitch, closeTo(60, 1e-6));
      await _expectEyeAt(map, _eye, _altitude);
    }, skip: !kIsWeb);

    testWidgets('a later camera update clamps the center again', (
      tester,
    ) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.controller.moveCamera(
        CameraUpdate.fromEye(_eye, bearing: 0, pitch: 80, altitude: _altitude),
      );
      await map.waitForLatestFrame();
      expect(lastMapEye()!.centerClampedToGround, isFalse);
      await map.controller.moveCamera(const CameraUpdate.position(zoom: 10));
      await map.waitForLatestFrame();
      expect(lastMapEye()!.centerClampedToGround, isTrue);
    }, skip: !kIsWeb);

    testWidgets('a map takes a maxPitch of 180 on web', (tester) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      // A camera pitched over 90 at a center on the ground would be under
      // it, so gl-js lowers the pitch of such a position; an eye keeps it.
      await map.controller.moveCamera(
        CameraUpdate.fromEye(_eye, bearing: 0, pitch: 170, altitude: _altitude),
      );
      expect(map.controller.getCamera().pitch, closeTo(170, 1e-6));
      await _expectEyeAt(map, _eye, _altitude);
    }, skip: !kIsWeb);

    // gl-js would put the center 400 m ahead, at zoom 17 or so, which the
    // map's maxZoom of 14 would pull the camera back from.
    testWidgets('keeps the eye under a low maxZoom', (tester) async {
      final map = await pumpMap(tester, options: _skywardOptions(maxZoom: 14));
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.controller.moveCamera(
        CameraUpdate.fromEye(_eye, bearing: 0, pitch: 60, altitude: 200),
      );
      final camera = map.controller.getCamera();
      expect(camera.zoom, lessThanOrEqualTo(14));
      expect(camera.pitch, closeTo(60, 1e-6));
      await _expectEyeAt(map, _eye, 200);
    }, skip: !kIsWeb);

    // gl-js would put the center 10 km ahead, at zoom 13 or so, which the
    // map's minZoom of 15 would push the camera forward from.
    testWidgets('keeps the eye over a high minZoom', (tester) async {
      final map = await pumpMap(
        tester,
        options: _skywardOptions(zoom: 16, minZoom: 15),
      );
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.controller.moveCamera(
        CameraUpdate.fromEye(_eye, bearing: 0, pitch: 115, altitude: _altitude),
      );
      final camera = map.controller.getCamera();
      expect(camera.zoom, greaterThanOrEqualTo(15));
      expect(camera.pitch, closeTo(115, 1e-6));
      await _expectEyeAt(map, _eye, _altitude);
    }, skip: !kIsWeb);

    testWidgets('a camera update ends an eye animation', (tester) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      final eye = map.controller.animateCamera(
        CameraUpdate.fromEye(
          _eye,
          bearing: 60,
          pitch: 110,
          altitude: _altitude,
        ),
        animation: const CameraAnimation.ease(duration: Duration(seconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      const center = Geographic(lon: 11.5, lat: 47.4);
      await map.controller.moveCamera(
        const CameraUpdate.position(center: center, zoom: 10, pitch: 30),
      );
      expect(
        await map.pumpFuture(eye, reason: 'the animation never ended'),
        CameraAnimationResult.cancelled,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final camera = map.controller.getCamera();
      expect(camera.center.lon, closeTo(center.lon, 1e-6));
      expect(camera.center.lat, closeTo(center.lat, 1e-6));
      expect(camera.zoom, closeTo(10, 1e-6));
      expect(camera.pitch, closeTo(30, 1e-6));
      await map.waitForLatestFrame();
      final shown = lastMapEye()!;
      expect(shown.centerClampedToGround, isTrue);
      // Without a terrain, the clamp puts the center at sea level.
      expect(shown.centerElevation, 0);
    }, skip: !kIsWeb);

    testWidgets('a later eye animation takes over from an earlier one', (
      tester,
    ) async {
      final map = await pumpMap(tester, options: _skywardOptions());
      // Watches the map's camera from its next frame on.
      lastMapEye();
      final first = map.controller.animateCamera(
        CameraUpdate.fromEye(
          _eye,
          bearing: 60,
          pitch: 110,
          altitude: _altitude,
        ),
        animation: const CameraAnimation.ease(duration: Duration(seconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      const later = Geographic(lon: 11.45, lat: 47.32);
      final second = map.controller.animateCamera(
        CameraUpdate.fromEye(later, bearing: -30, pitch: 95, altitude: 1800),
      );
      expect(
        await map.pumpFuture(first, reason: 'the first never ended'),
        CameraAnimationResult.completed,
      );
      expect(
        await map.pumpFuture(second, reason: 'the second never ended'),
        CameraAnimationResult.completed,
      );
      final camera = map.controller.getCamera();
      expect(camera.bearing, closeTo(-30, 1e-6));
      expect(camera.pitch, closeTo(95, 1e-6));
      final shown = await _expectEyeAt(map, later, 1800);
      expect(shown.centerClampedToGround, isFalse);
    }, skip: !kIsWeb);

    testWidgets('is not supported on native', (tester) async {
      final map = await pumpMap(tester);
      final eye = CameraUpdate.fromEye(
        _eye,
        bearing: 0,
        pitch: 80,
        altitude: 1,
      );
      await expectLater(
        map.controller.moveCamera(eye),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        map.controller.animateCamera(eye),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        map.controller.cameraFor(eye),
        throwsA(isA<UnsupportedError>()),
      );
      final renderer = await StillImageRenderer.createInstance();
      addTearDown(renderer.dispose);
      await expectLater(
        renderer.render(
          style: MapStyle.json(offlineStyle),
          size: const Size(64, 64),
          camera: eye,
        ),
        throwsA(isA<UnsupportedError>()),
      );
    }, skip: kIsWeb);

    testWidgets('as the initial camera on native, is reported and the map '
        'starts', (tester) async {
      final map = await pumpMap(
        tester,
        options: _skywardOptions(
          initCamera: CameraUpdate.fromEye(
            _eye,
            bearing: 0,
            pitch: 80,
            altitude: 1,
          ),
        ),
      );
      expect(tester.takeException(), isA<UnsupportedError>());
      await map.waitForStyleLoad(since: 0);
    }, skip: kIsWeb);
  });

  group('CameraUpdate.fromEye above the terrain', () {
    // Started by each test rather than in a setUp: on web, a failure in a
    // setUp is not reported, and the test would pass without running.
    late AlpsFixture fixture;

    Future<TestMap> pumpAlpsMap(WidgetTester tester) async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
      addTearDown(fixture.close);
      return pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: alpsCamera,
          maxPitch: 180,
        ),
      );
    }

    const eye = Geographic(lon: alpsLng, lat: alpsLat);
    const aboveTerrain = 100.0;

    testWidgets('puts the eye above the drawn terrain', (tester) async {
      final map = await pumpAlpsMap(tester);
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.style.setTerrain(
        const Terrain(sourceId: 'alps', exaggeration: alpsExaggeration),
      );
      await fixture.waitUntilSettled(map, GroundView(map));
      final ground = await map.controller.queryTerrainElevation(eye);
      expect(ground, isNotNull);
      // The crest, drawn with the exaggeration.
      expect(
        ground,
        closeTo(alpsHeight(alpsLat, alpsLng) * alpsExaggeration, 5),
      );
      await map.controller.moveCamera(
        CameraUpdate.fromEye(
          eye,
          bearing: 0,
          pitch: 115,
          aboveTerrain: aboveTerrain,
        ),
      );
      expect(map.controller.getCamera().pitch, closeTo(115, 1e-6));
      final shown = await _expectEyeAt(map, eye, ground! + aboveTerrain);
      expect(shown.centerClampedToGround, isFalse);
    }, skip: !kIsWeb);

    testWidgets('a gesture below the horizon clamps the center again in '
        'place', (tester) async {
      final map = await pumpAlpsMap(tester);
      lastMapEye();
      await map.style.setTerrain(
        const Terrain(sourceId: 'alps', exaggeration: alpsExaggeration),
      );
      await fixture.waitUntilSettled(map, GroundView(map));
      // South of the crest, looking down at its slope.
      const below = Geographic(lon: alpsLng, lat: alpsLat - 0.02);
      await map.controller.moveCamera(
        CameraUpdate.fromEye(below, bearing: 0, pitch: 70, aboveTerrain: 300),
      );
      await map.waitForLatestFrame();
      final before = lastMapEye()!;
      expect(before.centerClampedToGround, isFalse);

      // Past the touch slop, then a step there and back, which starts the
      // gesture and pans the map back to where it was.
      final finger = await tester.startGesture(
        map.toGlobal(map.center + const Offset(30, 0)),
      );
      await finger.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await finger.moveBy(const Offset(-2, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await finger.moveBy(const Offset(2, 0));
      // Lifted at rest, so it does not fling.
      await tester.pump(const Duration(milliseconds: 200));
      await finger.up();
      await map.waitForLatestFrame();
      final after = await _expectEyeAt(
        map,
        Geographic(lon: before.lon, lat: before.lat),
        before.altitude,
        meters: 2,
      );
      expect(after.centerClampedToGround, isTrue);
      // The center moved along the view onto the ground.
      final center = map.controller.getCamera().center;
      final ground = await map.controller.queryTerrainElevation(center);
      expect(after.centerElevation, closeTo(ground!, 5));
    }, skip: !kIsWeb);

    // A trail scrub: each eye 2 m above the ground, where the center of the
    // last one stays. gl-js would put the center about 11 m ahead, past
    // zoom 22, which would pull the camera back.
    testWidgets('keeps eyes just above the terrain in place', (tester) async {
      final map = await pumpAlpsMap(tester);
      // Watches the map's camera from its next frame on.
      lastMapEye();
      await map.style.setTerrain(
        const Terrain(sourceId: 'alps', exaggeration: alpsExaggeration),
      );
      await fixture.waitUntilSettled(map, GroundView(map));
      for (final point in const [
        eye,
        // 50 m further along the crest.
        Geographic(lon: alpsLng + 0.00066, lat: alpsLat),
      ]) {
        final ground = await map.controller.queryTerrainElevation(point);
        expect(ground, isNotNull, reason: '$point');
        await map.controller.moveCamera(
          CameraUpdate.fromEye(point, bearing: 0, pitch: 80, aboveTerrain: 2),
        );
        final camera = map.controller.getCamera();
        expect(camera.zoom, lessThanOrEqualTo(22), reason: '$point');
        expect(camera.pitch, closeTo(80, 1e-6), reason: '$point');
        await _expectEyeAt(map, point, ground! + 2);
      }
    }, skip: !kIsWeb);

    testWidgets('as the initial camera before a terrain, is reported and '
        'the map starts', (tester) async {
      clearResourceTimings();
      fixture = await AlpsFixture.start();
      addTearDown(fixture.close);
      final map = await pumpMap(
        tester,
        options: MapOptions(
          style: MapStyle.json(jsonEncode(fixture.style())),
          initCamera: CameraUpdate.fromEye(
            eye,
            bearing: 0,
            pitch: 80,
            aboveTerrain: aboveTerrain,
          ),
          maxPitch: 180,
        ),
      );
      expect(
        tester.takeException(),
        isA<TerrainElevationUnavailableException>(),
      );
      await map.waitForStyleLoad(since: 0);
    }, skip: !kIsWeb);

    testWidgets('fails without a terrain and keeps the camera', (tester) async {
      final map = await pumpAlpsMap(tester);
      await map.waitForLatestFrame();
      final before = map.controller.getCamera();
      await expectLater(
        map.controller.moveCamera(
          CameraUpdate.fromEye(
            eye,
            bearing: 0,
            pitch: 115,
            aboveTerrain: aboveTerrain,
          ),
        ),
        throwsA(isA<TerrainElevationUnavailableException>()),
      );
      await expectLater(
        map.controller.animateCamera(
          CameraUpdate.fromEye(
            eye,
            bearing: 0,
            pitch: 115,
            aboveTerrain: aboveTerrain,
          ),
        ),
        throwsA(isA<TerrainElevationUnavailableException>()),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(map.controller.getCamera(), before);
    }, skip: !kIsWeb);
  });
}
