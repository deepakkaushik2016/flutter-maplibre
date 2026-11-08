import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'shared/darwin_texture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runTests();
}

/// The iOS and macOS plugin's texture, driven through its C API with
/// IOSurfaces and Metal shared events of the test's own, so every order in
/// which frames end, rings change and textures go can be checked, including a
/// frame whose GPU work never ends.
void runTests() {
  final darwin =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);
  group('darwin texture ring', () {
    testWidgets('shows a frame once its GPU work ends', (tester) async {
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final event = SharedEvent();
      addTearDown(event.release);
      final present = ring.present(0, event, 1);
      expect(ring.slotInUse(0), isTrue);
      // Long enough for a settle to reach Dart, had the frame been shown.
      await tester.pump(const Duration(milliseconds: 50));
      expect(ring.settles, isEmpty, reason: 'the GPU work has not ended');
      event.signal(1);
      await ring.waitForSettles(1);
      expect(ring.settles, [(slot: 0, present: present, shown: true)]);
    });

    testWidgets('shows a frame without an event at once', (tester) async {
      // A session that hands frames over complete on the CPU gives no event.
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final present = ring.present(0, null, 0);
      await ring.waitForSettles(1);
      expect(ring.settles, [(slot: 0, present: present, shown: true)]);
      expect(ring.slotInUse(0), isTrue, reason: 'Flutter shows it next');
    });

    testWidgets('never shows a frame that ends after a newer one', (
      tester,
    ) async {
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final older = SharedEvent();
      final newer = SharedEvent();
      addTearDown(older.release);
      addTearDown(newer.release);
      final first = ring.present(0, older, 1);
      final second = ring.present(1, newer, 1);
      newer.signal(1);
      await ring.waitForSettles(2);
      expect(
        ring.settles,
        unorderedEquals([
          (slot: 1, present: second, shown: true),
          (slot: 0, present: first, shown: false),
        ]),
      );
      // The older frame ends late; a frame after it on the same listener
      // queue proves that its end was handled, and showed nothing.
      older.signal(1);
      final third = ring.present(2, older, 2);
      older.signal(2);
      await ring.waitForSettles(3);
      expect(ring.settles.last, (slot: 2, present: third, shown: true));
      expect(ring.settles.where((settle) => settle.slot == 0), hasLength(1));
      expect(ring.slotInUse(0), isFalse, reason: 'slot 0 was never shown');
    });

    testWidgets('a frame whose GPU work never ends leaks no slot', (
      tester,
    ) async {
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final stuck = SharedEvent();
      addTearDown(stuck.release);
      final lost = ring.present(0, stuck, 1);
      expect(ring.slotInUse(0), isTrue);
      final next = ring.present(1, null, 0);
      await ring.waitForSettles(2);
      expect(
        ring.settles,
        unorderedEquals([
          (slot: 1, present: next, shown: true),
          (slot: 0, present: lost, shown: false),
        ]),
      );
      expect(ring.slotInUse(0), isFalse);
      // The slot takes a frame again.
      final again = ring.present(0, null, 0);
      await ring.waitForSettles(3);
      expect(ring.settles.last, (slot: 0, present: again, shown: true));
    });

    testWidgets('a present that a resize replaced never settles', (
      tester,
    ) async {
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final event = SharedEvent();
      addTearDown(event.release);
      ring
        ..present(0, event, 1)
        ..resize();
      expect(ring.slotInUse(0), isFalse, reason: 'slot 0 of the new ring');
      event.signal(1);
      final next = ring.present(1, event, 2);
      event.signal(2);
      await ring.waitForSettles(1);
      expect(ring.settles, [(slot: 1, present: next, shown: true)]);
      expect(ring.slotInUse(0), isFalse);
    });

    testWidgets('a frame shown before a resize reports it before resizing '
        'returns', (tester) async {
      // The Darwin target forgets its presents once the session moved to
      // the new ring, after a reply that the library posts later than the
      // resize. A frame that Flutter shows from the old ring must have its
      // settle posted by then, so it reaches Dart first.
      final ring = TestRing(tester);
      addTearDown(ring.dispose);
      final present = ring.present(0, null, 0);
      ring.resize();
      // A message posted after the resize arrives after every one posted
      // before it.
      final later = ReceivePort();
      addTearDown(later.close);
      later.sendPort.send(null);
      await later.first;
      expect(ring.settles, [(slot: 0, present: present, shown: true)]);
    });

    testWidgets(
      'a texture disposed with a present waiting calls back no more',
      (tester) async {
        final disposed = TestRing(tester);
        final sentinel = TestRing(tester);
        addTearDown(sentinel.dispose);
        final event = SharedEvent();
        addTearDown(event.release);
        disposed
          ..present(0, event, 1)
          ..disposeTexture();
        event.signal(1);
        // The sentinel's frame ends on the same listener queue, after the
        // disposed texture's.
        final present = sentinel.present(0, event, 2);
        event.signal(2);
        await sentinel.waitForSettles(1);
        expect(sentinel.settles, [(slot: 0, present: present, shown: true)]);
        expect(disposed.settles, isEmpty);
        disposed.closeCallbacks();
      },
    );
  }, skip: !darwin);
}
