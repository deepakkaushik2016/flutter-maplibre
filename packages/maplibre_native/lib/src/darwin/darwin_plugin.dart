import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:maplibre_native/src/darwin/bindings.g.dart';
import 'package:maplibre_native/src/plugin_error.dart';

/// Called by the plugin once a present settles, with the texture's id, the
/// present's slot and number, and whether Flutter shows its frame next.
typedef FrameShownCallback = Void Function(
  Int64 textureId,
  Uint32 slot,
  Uint64 present,
  Bool shown,
);

/// The maplibre_native iOS and macOS plugin, called through its C API in
/// `darwin/maplibre_native/Sources/maplibre_native/include/maplibre_native/maplibre_native_api.h`.
final class DarwinPlugin {
  DarwinPlugin._();

  static final _bindings = MaplibreNativeDarwinBindings.fromLookup(
    _symbolLookup(),
  );

  /// Looks the C API up in the table of `+[MaplibreNativePlugin symbols]`.
  ///
  /// The plugin may be linked statically into the app, whose release builds
  /// strip global symbols, so `DynamicLibrary.process()` can't find its
  /// functions. The Objective-C runtime finds the class by name regardless.
  static Pointer<T> Function<T extends NativeType>(String) _symbolLookup() {
    final process = DynamicLibrary.process();
    final getClass = process
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Utf8>)
        >('objc_getClass');
    final registerName = process
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Utf8>)
        >('sel_registerName');
    // objc_msgSend takes the signature of the method it calls.
    final sendSymbols = process
        .lookupFunction<
          Pointer<MaplibreNativeSymbol> Function(Pointer<Void>, Pointer<Void>),
          Pointer<MaplibreNativeSymbol> Function(Pointer<Void>, Pointer<Void>)
        >('objc_msgSend');

    final symbols = using((arena) {
      final pluginClass = getClass(
        'MaplibreNativePlugin'.toNativeUtf8(allocator: arena),
      );
      if (pluginClass == nullptr) {
        throw StateError('The maplibre_native plugin is not linked.');
      }
      final table = sendSymbols(
        pluginClass,
        registerName('symbols'.toNativeUtf8(allocator: arena)),
      );
      return {
        for (var i = 0; table[i].name != nullptr; i++)
          table[i].name.cast<Utf8>().toDartString(): table[i].address,
      };
    });
    return <T extends NativeType>(String name) {
      final address = symbols[name];
      if (address == null) {
        throw ArgumentError.value(name, 'name', 'Not in the plugin C API');
      }
      return address.cast<T>();
    };
  }

  /// Registers a zero-copy texture that shows a ring of IOSurfaces, which
  /// the C library allocates, and returns its Flutter texture id. Until
  /// [disposeTexture] returns, the plugin calls [frameShown] once a present
  /// of [presentGpuTexture] settles, from other threads.
  static int createGpuTexture(
    Pointer<NativeFunction<FrameShownCallback>> frameShown,
  ) => using((arena) {
    final error = arena<Char>(pluginErrorSize);
    final id = _bindings.maplibre_native_create_gpu_texture(
      frameShown,
      error,
      pluginErrorSize,
    );
    if (id < 0) throw StateError(_message(error));
    return id;
  });

  /// Makes the frame in the IOSurfaceRef [surface], at [slot] of the current
  /// ring, the one Flutter shows next, without a copy, once the
  /// `MTLSharedEvent` [event] reaches [value], or at once when [event] is 0.
  /// The plugin retains the event, so it only needs to be valid during this
  /// call, and doesn't wait for the GPU. Returns the present's number, which
  /// the texture's frame-shown callback receives once the present settles.
  /// The frame stays acquired until [slotInUse] reports its slot free.
  static int presentGpuTexture(
    int textureId, {
    required int slot,
    required int surface,
    required int event,
    required int value,
  }) {
    // Called for every frame, so it reuses buffers of its own; the C API is
    // only called from the UI isolate.
    if (!_bindings.maplibre_native_present_gpu_texture(
      textureId,
      slot,
      Pointer.fromAddress(surface),
      event,
      value,
      _present,
      _presentError,
      pluginErrorSize,
    )) {
      throw StateError(_message(_presentError));
    }
    return _present.value;
  }

  static final Pointer<Uint64> _present = calloc<Uint64>();
  static final Pointer<Char> _presentError = calloc<Char>(pluginErrorSize);

  /// Ends a texture's current ring, before the session resizes: its presents
  /// that wait for their GPU work never settle, and no slot of the next ring
  /// is in use.
  static void endRing(int textureId) =>
      _bindings.maplibre_native_end_gpu_texture_ring(textureId);

  /// Whether Flutter may still sample [slot] of a texture.
  static bool slotInUse(int textureId, int slot) =>
      _bindings.maplibre_native_gpu_texture_slot_in_use(textureId, slot);

  /// Unregisters a texture. Its callback is not called anymore once this
  /// returns.
  static void disposeTexture(int textureId) =>
      _bindings.maplibre_native_dispose_texture(textureId);

  static String _message(Pointer<Char> error) => pluginErrorMessage(error);
}
