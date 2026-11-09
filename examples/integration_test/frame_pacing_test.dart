import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre/maplibre.dart';

import 'shared/engine_state.dart';
import 'shared/test_map.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

/// Waits until a window of [quiet] passes in which the map renders nothing.
Future<void> _settle(WidgetTester tester, Duration quiet) async {
  var before = engineRenderedFrames()!;
  while (true) {
    await tester.runAsync(() => Future<void>.delayed(quiet));
    final now = engineRenderedFrames()!;
    if (now == before) return;
    before = now;
  }
}

/// A two-second flight, far enough that every frame of it moves the camera.
Future<CameraAnimationResult> _fly(MapController controller, int leg) =>
    controller.animateCamera(
      CameraUpdate.position(
        center: Geographic(
          lon: leg.isOdd ? 40 : -40,
          lat: leg.isOdd ? 20 : -20,
        ),
        zoom: leg.isOdd ? 6 : 4,
        bearing: leg * 40.0 % 360,
      ),
      animation: const CameraAnimation.fly(duration: Duration(seconds: 2)),
    );

void runTests() {
  group('frame pacing', () {
    void pacingTest(
      String name, {
      LiveTestWidgetsFlutterBindingFramePolicy? policy,
    }) {
      testWidgets(name, (tester) async {
        final binding = IntegrationTestWidgetsFlutterBinding.instance;
        final previous = binding.framePolicy;
        if (policy != null) binding.framePolicy = policy;
        addTearDown(() => binding.framePolicy = previous);
        final map = await pumpMap(tester, options: offlineOptions());
        await _settle(tester, const Duration(milliseconds: 500));

        final refreshRate =
            binding.platformDispatcher.views.first.display.refreshRate;
        final rendered = engineRenderedFrames()!;
        final stopwatch = Stopwatch()..start();
        var flying = true;
        final flight = () async {
          for (var leg = 1; flying; leg++) {
            await _fly(map.controller, leg);
          }
        }();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        final count = engineRenderedFrames()! - rendered;
        final elapsed = stopwatch.elapsedMicroseconds / 1e6;
        flying = false;
        await map.controller.stopCamera();
        await tester.runAsync(
          () => flight.timeout(const Duration(seconds: 15)),
        );

        // Each demand waits for a display refresh, or a Flutter frame's
        // stand-in. Unpaced, iOS and Android render hundreds a second.
        expect(count, greaterThan(10));
        if (policy == LiveTestWidgetsFlutterBindingFramePolicy.fullyLive) {
          // A pacer limping along would pass the upper bound alone.
          expect(
            count,
            greaterThanOrEqualTo(0.7 * refreshRate * elapsed),
            reason: 'Only $count frames in $elapsed s at $refreshRate Hz',
          );
        }
        expect(
          count,
          lessThanOrEqualTo(refreshRate * elapsed + 2),
          reason: '$count frames in $elapsed s at $refreshRate Hz',
        );
        debugPrint(
          'frame pacing: $count frames in $elapsed s at $refreshRate Hz',
        );

        // At rest, once the flight's last frame is drawn: not one frame.
        await _settle(tester, const Duration(milliseconds: 500));
        final atRest = engineRenderedFrames()!;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        expect(engineRenderedFrames()! - atRest, 0);
      });
    }

    pacingTest(
      'the map renders at most once per display refresh, and not at all at rest',
      policy: LiveTestWidgetsFlutterBindingFramePolicy.fullyLive,
    );
    pacingTest(
      'the map is paced without Flutter frames as well, and renders nothing at rest',
    );
  }, skip: kIsWeb);
}
