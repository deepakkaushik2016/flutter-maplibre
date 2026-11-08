import 'package:flutter_test/flutter_test.dart';

/// How one present settled.
typedef Settle = ({int slot, int present, bool shown});

/// A Metal shared event, only on iOS and macOS.
final class SharedEvent {
  /// Creates an event at value 0.
  SharedEvent() {
    throw UnsupportedError('Metal shared events need iOS or macOS.');
  }

  /// Raises the event's value to [value].
  void signal(int value) {}

  /// Releases the event.
  void release() {}
}

/// A texture of the iOS and macOS plugin, only on iOS and macOS.
final class TestRing {
  /// Creates a ring.
  TestRing(WidgetTester _) {
    throw UnsupportedError('The texture ring needs iOS or macOS.');
  }

  /// The presents that settled, in order.
  final settles = <Settle>[];

  /// Presents [slot] once [event] reaches [value], or at once without one.
  int present(int slot, SharedEvent? event, int value) => 0;

  /// Whether Flutter may still sample [slot].
  bool slotInUse(int slot) => false;

  /// Ends the ring and allocates the next, as a resize does.
  void resize() {}

  /// Pumps frames until [count] presents settled.
  Future<void> waitForSettles(int count) async {}

  /// Unregisters the texture and keeps its callback open.
  void disposeTexture() {}

  /// Closes the callback of a disposed texture.
  void closeCallbacks() {}

  /// Disposes the texture and closes its callback.
  void dispose() {}
}
