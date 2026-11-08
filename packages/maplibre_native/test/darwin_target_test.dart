import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/darwin/darwin_target.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart';

void main() {
  group('Darwin target', () {
    test('prefers the shared event and accepts CPU-complete frames', () {
      expect(
        darwinProducerSyncKinds.contains(GpuSyncKindFlag.metalSharedEvent),
        isTrue,
      );
      expect(
        darwinProducerSyncKinds.contains(GpuSyncKindFlag.cpuComplete),
        isTrue,
        reason: 'a session without the shared event must still attach',
      );
    });

    test('waits for the shared event of a frame that has one', () {
      expect(darwinFrameEvent(GpuSyncKind.metalSharedEvent, 0x1234), 0x1234);
    });

    test('shows a CPU-complete frame at once', () {
      expect(darwinFrameEvent(GpuSyncKind.cpuComplete, 0x1234), 0);
    });

    test('never shows a shared-event frame without its event at once', () {
      // A null event means "complete" to the plugin, so a frame that should
      // wait for one must not be presented at all.
      expect(
        () => darwinFrameEvent(GpuSyncKind.metalSharedEvent, 0),
        throwsStateError,
      );
    });
  });
}
