// C API of the maplibre_native iOS and macOS plugin, which Dart calls through
// the ffigen bindings in lib/src/darwin/bindings.g.dart. Regenerate them with
// `cd tool/codegen && dart run ffigen.dart` after changing this file.
//
// Dart finds the functions through +[MaplibreNativePlugin symbols], which it
// calls through the Objective-C runtime, rather than through dlsym: the plugin
// can be linked statically into the app, whose release builds strip global
// symbols.
//
// Functions that can fail return false or -1 and write a null-terminated
// message to |error|, of |error_size| bytes, when it is not null. Dart calls
// them on its UI thread.

#ifndef MAPLIBRE_NATIVE_API_H_
#define MAPLIBRE_NATIVE_API_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// A function of this API and its name, as +[MaplibreNativePlugin symbols]
// lists them. The list ends with an entry whose name is null.
typedef struct MaplibreNativeSymbol {
  const char* name;
  void* address;
} MaplibreNativeSymbol;

// Settles the present numbered |present|, of |slot| of the texture
// |texture_id|: |shown| when Flutter shows its frame next, and false when a
// newer frame was shown first. Each present settles once, unless
// maplibre_native_end_gpu_texture_ring or maplibre_native_dispose_texture
// ended it first. Called on the thread that showed the frame: Dart's UI
// thread for a frame whose GPU work had ended when it was presented, and the
// plugin's frame queue otherwise. Pass a NativeCallable.listener.
typedef void (*MaplibreNativeFrameShown)(int64_t texture_id, uint32_t slot,
                                         uint64_t present, bool shown);

// Registers a zero-copy texture that shows the frames of a ring of IOSurfaces,
// which the C library allocates and renders into, and returns its Flutter
// texture id, or -1 on failure. |frame_shown| settles its presents.
int64_t maplibre_native_create_gpu_texture(MaplibreNativeFrameShown frame_shown,
                                           char* error, size_t error_size);

// Makes the frame in the IOSurfaceRef |surface|, at |slot| of the current
// ring, the one Flutter shows next, without a copy, once the MTLSharedEvent
// |shared_event| reaches |value|: when the frame's GPU work has ended. Without
// an event (0), the frame is complete and shows at once. The plugin retains
// the event until the present settles, so pass it while the producer sync's
// view is open. The present doesn't wait for the GPU. Writes the present's
// number, which MaplibreNativeFrameShown settles with, to |out_present|. The
// plugin wraps each surface of a ring in a pixel buffer once. The frame stays
// acquired until maplibre_native_gpu_texture_slot_in_use reports the slot
// free.
bool maplibre_native_present_gpu_texture(int64_t texture_id, uint32_t slot,
                                         void* surface, uint64_t shared_event,
                                         uint64_t value, uint64_t* out_present,
                                         char* error, size_t error_size);

// Ends the current ring, before the session resizes and gives the ring new
// surfaces: its presents that wait for their GPU work never settle and are
// never shown, and no slot of the next ring is in use. Flutter keeps showing
// the frame it shows until a frame of the next ring is shown.
void maplibre_native_end_gpu_texture_ring(int64_t texture_id);

// Whether Flutter may still sample |slot|, so its frame must stay acquired:
// the slot's present waits for its GPU work, or Flutter shows it next, or it
// is one of the last two slots that Flutter took.
bool maplibre_native_gpu_texture_slot_in_use(int64_t texture_id,
                                             uint32_t slot);

// Unregisters a texture. Its presents never settle.
void maplibre_native_dispose_texture(int64_t texture_id);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // MAPLIBRE_NATIVE_API_H_
