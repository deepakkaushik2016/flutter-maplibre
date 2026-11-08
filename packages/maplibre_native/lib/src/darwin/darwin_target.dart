import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:maplibre_native/src/darwin/darwin_plugin.dart';
import 'package:maplibre_native/src/darwin/pending_presents.dart';
import 'package:maplibre_native/src/frame_target.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart';

/// The producer syncs an iOS or macOS session may hand frames over with.
/// With the shared event, the session's core worker commits each frame
/// without waiting for its GPU work, and the plugin shows the frame once that
/// work ends. A session without it hands frames over complete on the CPU, and
/// the plugin shows them at once.
@visibleForTesting
final GpuSyncKindFlag darwinProducerSyncKinds =
    GpuSyncKindFlag.metalSharedEvent | GpuSyncKindFlag.cpuComplete;

/// The `MTLSharedEvent` that the plugin waits for before it shows a frame
/// handed over with a producer sync of [kind] and [handle], or 0 for a frame
/// complete on the CPU, which the plugin shows at once. Throws for a
/// shared-event sync without an event, so that such a frame is never shown
/// as complete.
@visibleForTesting
int darwinFrameEvent(GpuSyncKind kind, int handle) {
  if (kind != GpuSyncKind.metalSharedEvent) return 0;
  if (handle == 0) {
    throw StateError('The frame waits for a shared event but has none');
  }
  return handle;
}

/// Creates the target of an iOS or macOS map, which renders on its session's
/// core worker through Metal into a ring of BGRA8 IOSurfaces that the C
/// library allocates. Flutter samples the surface of the frame on screen
/// directly, without a copy.
FrameTarget createDarwinTarget(LogicalExtent extent) {
  late final _IoSurfaceRingTarget target;
  final frameShown = NativeCallable<FrameShownCallback>.listener(
    (int _, int slot, int present, bool shown) =>
        target._onFrameShown(slot, present, shown: shown),
  )..keepIsolateAlive = false;
  final int textureId;
  try {
    textureId = DarwinPlugin.createGpuTexture(frameShown.nativeFunction);
  } on Object {
    frameShown.close();
    rethrow;
  }
  return target = _IoSurfaceRingTarget(textureId, frameShown);
}

/// Flutter samples the surface of the frame on screen directly, so frames
/// are held until their slots are free. The plugin shows each frame once its
/// GPU work ends, so the CPU work of one frame overlaps the GPU work of the
/// one before.
final class _IoSurfaceRingTarget extends LibraryRingTarget {
  _IoSurfaceRingTarget(super.textureId, this._frameShown);

  /// Called by the plugin once a present settles.
  final NativeCallable<FrameShownCallback> _frameShown;

  /// The presents whose frames Flutter doesn't show yet, with their results.
  late final _pending = PendingPresents<RenderFrameResult>(slotCount);

  /// Whether a release of freed slots is queued already.
  var _releaseQueued = false;

  @override
  bool get holdsFrames => true;

  /// Four: with three, every slot is held right after a present (the
  /// presented frame, the one Flutter shows, and the one before, which a
  /// frame still on the GPU may read), so the next frame waits for Flutter's
  /// next vsync to free one and a frame longer than the rest of a vsync
  /// halves the frame rate. The C library allows rings of up to eight.
  @override
  int get slotCount => 4;

  @override
  RenderSessionHandle attach(
    MapHandle map,
    LogicalExtent extent,
    Wake frameWake,
  ) => map.attachIoSurfaceRing(
    IoSurfaceRingDescriptor(
      logicalSize: logicalSize(extent),
      bufferCount: slotCount,
    ),
    attachOptions(frameWake)
        .copyWith(producerSyncKinds: darwinProducerSyncKinds),
  );

  /// Shown once the plugin settles the present.
  @override
  bool get showsOnPresent => false;

  /// Hands the frame to the plugin with its shared event, inside the views
  /// that keep the surface and the event valid; the plugin retains both from
  /// then on and shows the slot once the event says the frame's GPU work
  /// ended. The present doesn't wait for that, so the session renders the
  /// next frame meanwhile. [FrameTargetHost.showFrame] reports the frame
  /// once the plugin shows it, and never when a newer frame was shown first.
  @override
  int presentFrame(AcquiredFrameHandle frame, RenderFrameResult result) {
    var slot = 0;
    final present = frame.withIoSurface((view) {
      slot = view.slot;
      // Before the plugin arms the present, which it would then show with no
      // entry here to report it.
      if (!_pending.holds(slot)) {
        throw StateError('Slot $slot is beyond the ring of $slotCount');
      }
      return frame.withProducerSync(
        (sync) => DarwinPlugin.presentGpuTexture(
          textureId,
          slot: slot,
          surface: view.surface.address,
          event: darwinFrameEvent(sync.kind, sync.handle),
          value: sync.value,
        ),
      );
    });
    _pending.add(slot, present, result);
    return slot;
  }

  /// The present numbered [present] in [slot] settled, and slots may be free:
  /// replaced frames go, so MapLibre can render into their slots, after the
  /// presentation or resize in flight. Settles that arrive meanwhile share
  /// one release. A settle of a present that a resize or the session's end
  /// forgot reports nothing.
  void _onFrameShown(int slot, int present, {required bool shown}) {
    final host = this.host;
    if (host == null || host.disposed) return;
    final result = _pending.settle(slot, present);
    if (shown && result != null) host.showFrame(result);
    if (_releaseQueued) return;
    _releaseQueued = true;
    host.onGpuQueue(() async {
      _releaseQueued = false;
      releaseFreeFrames();
    }).ignore();
  }

  @override
  bool slotInUse(int slot) => DarwinPlugin.slotInUse(textureId, slot);

  /// The plugin ends the ring first, so a frame of the old ring that ends
  /// later is never shown, and the old presents never settle. Flutter keeps
  /// the buffer it shows.
  ///
  /// The old presents are forgotten only after the session's reply to the
  /// resize, so no frame that Flutter shows loses its report: the plugin
  /// posts a present's settle under the texture lock in the call that shows
  /// its frame, and ends the ring under the same lock, so the settle of each
  /// old frame that Flutter shows is posted before the ring ends, and
  /// reaches this isolate before the reply, which the library posts later.
  /// `darwin_texture_test.dart` checks the plugin's half.
  @override
  Future<void> resize(RenderSessionHandle session, LogicalExtent extent) async {
    DarwinPlugin.endRing(textureId);
    try {
      await super.resize(session, extent);
    } finally {
      _pending.clear();
    }
  }

  @override
  Future<void> endSession(RenderSessionHandle session) {
    DarwinPlugin.endRing(textureId);
    _pending.clear();
    return super.endSession(session);
  }

  @override
  void disposeTexture() {
    DarwinPlugin.disposeTexture(textureId);
    _frameShown.close();
  }
}
