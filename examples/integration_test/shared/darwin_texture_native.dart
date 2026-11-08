import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
// The tests drive the plugin's C API below the public API on purpose: no map
// call can make a frame's GPU work end late, or never.
import 'package:maplibre_native/src/darwin/darwin_plugin.dart';

import 'test_map.dart';

/// How one present settled.
typedef Settle = ({int slot, int present, bool shown});

final DynamicLibrary _process = DynamicLibrary.process();

final Pointer<Void> Function(Pointer<Utf8>) _selector = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('sel_registerName');

// objc_msgSend takes the signature of the method it calls.
final Pointer<Void> Function(Pointer<Void>, Pointer<Void>) _send = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
    >('objc_msgSend');

final void Function(Pointer<Void>, Pointer<Void>, int) _sendUint64 = _process
    .lookupFunction<
      Void Function(Pointer<Void>, Pointer<Void>, Uint64),
      void Function(Pointer<Void>, Pointer<Void>, int)
    >('objc_msgSend');

Pointer<Void> _sel(String name) =>
    using((arena) => _selector(name.toNativeUtf8(allocator: arena)));

/// The system's Metal device, retained for the process.
final Pointer<Void> _device = _process
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'MTLCreateSystemDefaultDevice',
    )();

final Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Void>,
  Pointer<Void>,
)
_dictionaryCreate = _process
    .lookupFunction<
      Pointer<Void> Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
        IntPtr,
        Pointer<Void>,
        Pointer<Void>,
      ),
      Pointer<Void> Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
        int,
        Pointer<Void>,
        Pointer<Void>,
      )
    >('CFDictionaryCreate');

final void Function(Pointer<Void>) _release = _process
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'CFRelease',
    );

final int Function(
  Pointer<Void>,
  int,
  int,
  int,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
)
_pixelBufferCreate = _process
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Size,
        Size,
        Uint32,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
      ),
      int Function(
        Pointer<Void>,
        int,
        int,
        int,
        Pointer<Void>,
        Pointer<Pointer<Void>>,
      )
    >('CVPixelBufferCreate');

final Pointer<Void> Function(Pointer<Void>) _pixelBufferSurface = _process
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('CVPixelBufferGetIOSurface');

/// kCVPixelFormatType_32BGRA, the layout of the C library's surfaces.
const _bgra = 0x42475241;

/// The attributes of an IOSurface-backed pixel buffer, made once.
final Pointer<Void> _surfaceAttributes = using((arena) {
  final keyCallbacks = _process.lookup<Void>('kCFTypeDictionaryKeyCallBacks');
  final valueCallbacks = _process.lookup<Void>(
    'kCFTypeDictionaryValueCallBacks',
  );
  final noProperties = _dictionaryCreate(
    nullptr,
    nullptr,
    nullptr,
    0,
    keyCallbacks,
    valueCallbacks,
  );
  final keys = arena<Pointer<Void>>()
    ..value = _process
        .lookup<Pointer<Void>>('kCVPixelBufferIOSurfacePropertiesKey')
        .value;
  final values = arena<Pointer<Void>>()..value = noProperties;
  final attributes = _dictionaryCreate(
    nullptr,
    keys,
    values,
    1,
    keyCallbacks,
    valueCallbacks,
  );
  _release(noProperties);
  return attributes;
});

/// A BGRA8 IOSurface, as the C library allocates for each slot of its ring.
final class TestSurface {
  /// Creates a surface of [width] x [height] pixels.
  factory TestSurface(int width, int height) => using((arena) {
    final buffer = arena<Pointer<Void>>();
    final status = _pixelBufferCreate(
      nullptr,
      width,
      height,
      _bgra,
      _surfaceAttributes,
      buffer,
    );
    if (status != 0) throw StateError('CVPixelBufferCreate failed ($status)');
    return TestSurface._(buffer.value);
  });

  TestSurface._(this._buffer);

  /// The pixel buffer, which retains the surface.
  final Pointer<Void> _buffer;

  /// The `IOSurfaceRef`, as the C API takes it.
  int get address => _pixelBufferSurface(_buffer).address;

  /// Releases the surface; the plugin keeps the ones it still shows.
  void release() => _release(_buffer);
}

/// A Metal shared event whose value the test raises, as the GPU raises a
/// frame's once its work ends.
final class SharedEvent {
  /// Creates an event at value 0.
  SharedEvent() : _event = _send(_device, _sel('newSharedEvent'));

  final Pointer<Void> _event;

  /// The `id<MTLSharedEvent>`, as the C API takes it.
  int get address => _event.address;

  /// Raises the event's value to [value].
  void signal(int value) =>
      _sendUint64(_event, _sel('setSignaledValue:'), value);

  /// Releases the event; the plugin keeps the ones it still waits on.
  void release() => _send(_event, _sel('release'));
}

/// A texture of the plugin with a ring of four 16 x 16 surfaces, and the
/// presents that settled.
final class TestRing {
  /// Registers a texture and allocates its first ring.
  TestRing(this._tester) {
    _frameShown = NativeCallable<FrameShownCallback>.listener(
      (int _, int slot, int present, bool shown) =>
          settles.add((slot: slot, present: present, shown: shown)),
    );
    textureId = DarwinPlugin.createGpuTexture(_frameShown.nativeFunction);
    _allocateRing();
  }

  final WidgetTester _tester;
  late final NativeCallable<FrameShownCallback> _frameShown;
  final _surfaces = <TestSurface>[];
  var _ring = <TestSurface>[];

  /// The texture's Flutter texture id.
  late final int textureId;

  /// The presents that settled, in order.
  final settles = <Settle>[];

  var _disposed = false;
  var _closed = false;

  void _allocateRing() {
    _ring = List.generate(4, (_) => TestSurface(16, 16));
    _surfaces.addAll(_ring);
  }

  /// Presents [slot] once [event] reaches [value], or at once without one,
  /// and returns the present's number.
  int present(int slot, SharedEvent? event, int value) =>
      DarwinPlugin.presentGpuTexture(
        textureId,
        slot: slot,
        surface: _ring[slot].address,
        event: event?.address ?? 0,
        value: value,
      );

  /// Whether Flutter may still sample [slot].
  bool slotInUse(int slot) => DarwinPlugin.slotInUse(textureId, slot);

  /// Ends the ring and allocates the next, as a resize does.
  void resize() {
    DarwinPlugin.endRing(textureId);
    _allocateRing();
  }

  /// Pumps frames until [count] presents settled.
  Future<void> waitForSettles(int count) async {
    final deadline = DateTime.now().add(defaultTimeout);
    while (settles.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $count settles, got $settles');
      }
      await _tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Unregisters the texture and keeps its callback open, so a callback
  /// after disposal would be counted rather than crash.
  void disposeTexture() {
    if (_disposed) return;
    _disposed = true;
    DarwinPlugin.disposeTexture(textureId);
  }

  /// Closes the callback of a disposed texture and releases its surfaces.
  void closeCallbacks() {
    if (_closed) return;
    _closed = true;
    _frameShown.close();
    for (final surface in _surfaces) {
      surface.release();
    }
    _surfaces.clear();
  }

  /// Disposes the texture and closes its callback.
  void dispose() {
    disposeTexture();
    closeCallbacks();
  }
}
