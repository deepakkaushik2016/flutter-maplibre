import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/frame_pacer.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  void frame() => binding
    ..handleBeginFrame(Duration.zero)
    ..handleDrawFrame();

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  group('FlutterFrameClock', () {
    late FlutterFrameClock clock;
    late List<bool> refreshes;

    setUp(() {
      clock = FlutterFrameClock();
      refreshes = [];
    });
    tearDown(() => clock.cancel());

    void schedule({int standInMs = 30}) => clock.schedule(
      ({fromDisplay = true}) => refreshes.add(fromDisplay),
      Duration(milliseconds: standInMs),
    );

    test('a Flutter frame is the refresh, and the stand-in goes', () async {
      schedule();
      frame();
      expect(refreshes, [true]);
      await wait(45);
      expect(refreshes, [true]);
    });

    test('without a Flutter frame the stand-in calls back', () async {
      schedule();
      await wait(45);
      expect(refreshes, [false]);
    });

    test('a display frame after a stand-in reports only a sample', () async {
      var samples = 0;
      clock.onDisplayFrame = () => samples++;
      schedule();
      await wait(45);
      expect(refreshes, [false]);
      frame();
      expect(refreshes, [false]);
      expect(samples, 1);
    });

    test(
      'the next schedule reuses the display callback a stand-in left',
      () async {
        schedule();
        await wait(45);
        expect(refreshes, [false]);
        schedule(standInMs: 200);
        frame();
        expect(refreshes, [false, true]);
        await wait(20);
        expect(refreshes, [false, true]);
      },
    );

    test('cancel forgets the refresh and the delay', () async {
      var delayed = 0;
      schedule();
      clock
        ..delay(const Duration(milliseconds: 5), () => delayed++)
        ..cancel();
      frame();
      await wait(45);
      expect(refreshes, isEmpty);
      expect(delayed, 0);
    });
  });
}
