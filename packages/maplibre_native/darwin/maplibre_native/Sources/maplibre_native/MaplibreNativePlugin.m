#import "MaplibreNativePlugin.h"

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <os/lock.h>

#include <string.h>

/// The deepest ring the C library allocates.
enum { kMaxSlots = 8 };

/// Writes |message| into the caller's |error| buffer, when there is one.
static void WriteError(NSString *message, char *error, size_t error_size) {
  if (error == NULL || error_size == 0) return;
  strlcpy(error, message.UTF8String ?: "unknown error", error_size);
}

/// The listener that shows frames once their GPU work ends, on one serial
/// queue for every texture.
static MTLSharedEventListener *FrameListener(void) {
  static MTLSharedEventListener *listener;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    listener = [[MTLSharedEventListener alloc]
        initWithDispatchQueue:dispatch_queue_create("maplibre_native.frames", attributes)];
  });
  return listener;
}

/// Runs |block| on the main thread and waits for it. Dart's UI thread is the
/// main thread when the platform and UI threads are merged, and then this runs
/// inline.
static void RunOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

/// A Flutter texture that shows the frames of a ring of IOSurfaces, which the
/// C library allocates and renders into through Metal. Flutter samples the
/// surface of the shown frame directly, without a copy. A presented frame is
/// shown once its MTLSharedEvent says that its GPU work ended, so Flutter never
/// samples a surface still being drawn, and the session renders the next frame
/// meanwhile. Dart keeps every frame acquired until -isSlotInUse: reports its
/// slot free, so MapLibre renders into the other surfaces.
@interface MLNGpuTexture : NSObject <FlutterTexture>

@property(nonatomic) int64_t textureId;

- (instancetype)initWithFrameShown:(nullable MaplibreNativeFrameShown)frameShown
                          registry:(NSObject<FlutterTextureRegistry> *)registry;

/// Makes the frame in |surface|, at |slot|, the one Flutter shows next once
/// |event| reaches |value|, or at once without an event, and writes the
/// present's number to |presented|.
- (BOOL)presentSlot:(uint32_t)slot
            surface:(IOSurfaceRef)surface
              event:(nullable id<MTLSharedEvent>)event
              value:(uint64_t)value
          presented:(uint64_t *)presented
              error:(NSString *_Nullable *_Nonnull)error;

/// Ends the ring before the library replaces its surfaces.
- (void)endRing;

/// Whether Flutter may still sample |slot|: its present waits for its GPU
/// work, or Flutter shows it next, or it is one of the last two that Flutter
/// took.
- (BOOL)isSlotInUse:(uint32_t)slot;

/// Stops calling back and telling Flutter about new frames.
- (void)stopCallbacks;

@end

@implementation MLNGpuTexture {
  /// The pixel buffers of the current ring's surfaces, by slot, which retain
  /// the surfaces. Only Dart's calls touch them.
  CVPixelBufferRef _buffers[kMaxSlots];
  /// Guard the fields below, which Flutter's raster thread and the frame
  /// listener's queue read.
  os_unfair_lock _lock;
  /// The buffer of the shown frame, retained, and its slot, or -1.
  CVPixelBufferRef _latest;
  int64_t _latestSlot;
  /// The slot that Flutter took last, whose buffer it holds until it takes
  /// the next one, and the slot it took before, which a frame still on the
  /// GPU may read. Neither IOSurfaceIsInUse nor the use count see Flutter's
  /// reads: the ring's buffers keep every surface in use, and Flutter's
  /// texture adds nothing.
  int64_t _takenSlot;
  int64_t _previousTakenSlot;
  /// The present of each slot whose GPU work hasn't ended: its number (0 for
  /// none), the event and value it waits for, and its buffer, retained. The
  /// event is retained until the present settles, so the plugin never uses a
  /// session's event after the session let go of it.
  uint64_t _pendingPresent[kMaxSlots];
  __strong id<MTLSharedEvent> _pendingEvent[kMaxSlots];
  uint64_t _pendingValue[kMaxSlots];
  CVPixelBufferRef _pendingBuffer[kMaxSlots];
  /// Counts presents, and the number of the one shown last, so a frame that
  /// ends after a newer one is never shown.
  uint64_t _presented;
  uint64_t _shown;
  /// The block every event wait calls, made once rather than per frame.
  void (^_eventReached)(id<MTLSharedEvent>, uint64_t);
  /// Settles presents; null once the texture is disposed, as is |_registry|,
  /// which _registryLock guards so that no textureFrameAvailable: runs once
  /// disposal unregistered the texture.
  MaplibreNativeFrameShown _frameShown;
  os_unfair_lock _registryLock;
  __weak NSObject<FlutterTextureRegistry> *_registry;
}

- (instancetype)initWithFrameShown:(nullable MaplibreNativeFrameShown)frameShown
                          registry:(NSObject<FlutterTextureRegistry> *)registry {
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _registryLock = OS_UNFAIR_LOCK_INIT;
    _frameShown = frameShown;
    _registry = registry;
    _latestSlot = -1;
    _takenSlot = -1;
    _previousTakenSlot = -1;
    __weak MLNGpuTexture *weakSelf = self;
    _eventReached = ^(id<MTLSharedEvent> event, uint64_t value) {
      [weakSelf eventReached:event value:value];
    };
  }
  return self;
}

- (void)dealloc {
  [self releaseBuffers];
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    if (_pendingBuffer[i] != NULL) CVPixelBufferRelease(_pendingBuffer[i]);
  }
  if (_latest != NULL) CVPixelBufferRelease(_latest);
}

- (void)releaseBuffers {
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    if (_buffers[i] != NULL) CVPixelBufferRelease(_buffers[i]);
    _buffers[i] = NULL;
  }
}

- (BOOL)presentSlot:(uint32_t)slot
            surface:(IOSurfaceRef)surface
              event:(nullable id<MTLSharedEvent>)event
              value:(uint64_t)value
          presented:(uint64_t *)presented
              error:(NSString *_Nullable *_Nonnull)error {
  if (slot >= kMaxSlots) {
    *error = [NSString stringWithFormat:@"Slot %u is beyond the ring", slot];
    return NO;
  }
  if (_buffers[slot] != NULL && CVPixelBufferGetIOSurface(_buffers[slot]) != surface) {
    CVPixelBufferRelease(_buffers[slot]);
    _buffers[slot] = NULL;
  }
  if (_buffers[slot] == NULL) {
    // BGRA8 is the layout of the surfaces and of Flutter's pixel buffer
    // textures, so Flutter samples the frames as MapLibre rendered them.
    CVReturn status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL,
                                                       &_buffers[slot]);
    if (status != kCVReturnSuccess) {
      _buffers[slot] = NULL;
      *error = [NSString stringWithFormat:@"CVPixelBufferCreateWithIOSurface failed (%d)", status];
      return NO;
    }
  }
  if (event == nil) value = 0;
  os_unfair_lock_lock(&_lock);
  if (_pendingPresent[slot] != 0) {
    os_unfair_lock_unlock(&_lock);
    *error = [NSString stringWithFormat:@"Slot %u has a present that hasn't settled", slot];
    return NO;
  }
  *presented = ++_presented;
  _pendingPresent[slot] = *presented;
  _pendingEvent[slot] = event;
  _pendingValue[slot] = value;
  _pendingBuffer[slot] = CVPixelBufferRetain(_buffers[slot]);
  os_unfair_lock_unlock(&_lock);
  if (event == nil || event.signaledValue >= value) {
    [self eventReached:event value:value];
  } else {
    // The block is the texture's own; the listener retains it until the
    // event reaches the value, which it does even after the session goes.
    [event notifyListener:FrameListener() atValue:value block:_eventReached];
  }
  return YES;
}

/// Settles the presents that |event| reaching |value| ended: shows the newest
/// of them unless a newer present is shown already, and lets go of every
/// present older than the one shown, ended or not. Their slots are Flutter's
/// no more, and the session renders into them again only after its GPU work
/// in flight, which runs in order on the session's own queue.
- (void)eventReached:(nullable id<MTLSharedEvent>)event value:(uint64_t)value {
  CVPixelBufferRef released[kMaxSlots + 1] = {NULL};
  uint32_t releasedCount = 0;
  BOOL shown = NO;
  int64_t newest = -1;
  os_unfair_lock_lock(&_lock);
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    if (_pendingPresent[i] != 0 && _pendingEvent[i] == event && _pendingValue[i] <= value &&
        (newest < 0 || _pendingPresent[i] > _pendingPresent[newest])) {
      newest = i;
    }
  }
  if (newest >= 0 && _pendingPresent[newest] > _shown) {
    _shown = _pendingPresent[newest];
    released[releasedCount++] = _latest;
    _latest = _pendingBuffer[newest];
    _pendingBuffer[newest] = NULL;
    _latestSlot = newest;
    shown = YES;
  }
  // Under the lock, so no callback runs once disposal cleared it. It only
  // posts to Dart.
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    const uint64_t present = _pendingPresent[i];
    if (present == 0) continue;
    const BOOL ended = _pendingEvent[i] == event && _pendingValue[i] <= value;
    if (!ended && present >= _shown) continue;
    _pendingPresent[i] = 0;
    _pendingEvent[i] = nil;
    if (_pendingBuffer[i] != NULL) released[releasedCount++] = _pendingBuffer[i];
    _pendingBuffer[i] = NULL;
    if (_frameShown != NULL) _frameShown(_textureId, i, present, shown && (int64_t)i == newest);
  }
  os_unfair_lock_unlock(&_lock);
  for (uint32_t i = 0; i < releasedCount; i++) {
    if (released[i] != NULL) CVPixelBufferRelease(released[i]);
  }
  if (shown) {
    // The engine only marks the texture dirty and schedules a frame, which
    // is safe from any thread; the lock keeps it from running once disposal
    // unregistered the texture.
    os_unfair_lock_lock(&_registryLock);
    [_registry textureFrameAvailable:_textureId];
    os_unfair_lock_unlock(&_registryLock);
  }
}

- (void)endRing {
  // Flutter keeps showing the old ring's buffer, which it retains, until a
  // frame of the next ring is shown, and samples none of the next slots yet.
  [self releaseBuffers];
  CVPixelBufferRef released[kMaxSlots] = {NULL};
  os_unfair_lock_lock(&_lock);
  _latestSlot = -1;
  _takenSlot = -1;
  _previousTakenSlot = -1;
  // Dart lets go of every frame of the old ring, and a present of the old
  // ring that ends later is never shown.
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    _pendingPresent[i] = 0;
    _pendingEvent[i] = nil;
    released[i] = _pendingBuffer[i];
    _pendingBuffer[i] = NULL;
  }
  os_unfair_lock_unlock(&_lock);
  for (uint32_t i = 0; i < kMaxSlots; i++) {
    if (released[i] != NULL) CVPixelBufferRelease(released[i]);
  }
}

- (BOOL)isSlotInUse:(uint32_t)slot {
  if (slot >= kMaxSlots) return NO;
  os_unfair_lock_lock(&_lock);
  const BOOL held = slot == _latestSlot || slot == _takenSlot || slot == _previousTakenSlot ||
                    _pendingPresent[slot] != 0;
  os_unfair_lock_unlock(&_lock);
  return held;
}

- (void)stopCallbacks {
  os_unfair_lock_lock(&_lock);
  _frameShown = NULL;
  os_unfair_lock_unlock(&_lock);
  os_unfair_lock_lock(&_registryLock);
  _registry = nil;
  os_unfair_lock_unlock(&_registryLock);
}

// Runs on Flutter's raster thread. Flutter keeps the buffer it gets until it
// takes the next one.
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  os_unfair_lock_lock(&_lock);
  CVPixelBufferRef buffer = _latest;
  if (buffer != NULL) CVPixelBufferRetain(buffer);
  if (_latestSlot != _takenSlot) {
    _previousTakenSlot = _takenSlot;
    _takenSlot = _latestSlot;
  }
  os_unfair_lock_unlock(&_lock);
  return buffer;
}

@end

// State shared by the C API, guarded by gLock. Dart calls the API on its UI
// thread, and the plugin registers on the main thread.
static NSLock *gLock;
static __weak NSObject<FlutterTextureRegistry> *gRegistry;
static NSMutableDictionary<NSNumber *, MLNGpuTexture *> *gTextures;

static MLNGpuTexture *_Nullable FindTexture(int64_t texture_id, char *error, size_t error_size) {
  MLNGpuTexture *texture = gTextures[@(texture_id)];
  if (texture == nil) {
    WriteError([NSString stringWithFormat:@"No texture %lld", (long long)texture_id], error,
               error_size);
  }
  return texture;
}

int64_t maplibre_native_create_gpu_texture(MaplibreNativeFrameShown frame_shown, char *error,
                                           size_t error_size) {
  [gLock lock];
  NSObject<FlutterTextureRegistry> *registry = gRegistry;
  [gLock unlock];
  if (registry == nil) {
    WriteError(@"The maplibre_native plugin is not registered.", error, error_size);
    return -1;
  }
  MLNGpuTexture *texture = [[MLNGpuTexture alloc] initWithFrameShown:frame_shown
                                                            registry:registry];
  // Outside the lock, which the main thread may wait for.
  __block int64_t texture_id = -1;
  RunOnMain(^{
    texture_id = [registry registerTexture:texture];
  });
  texture.textureId = texture_id;
  [gLock lock];
  gTextures[@(texture_id)] = texture;
  [gLock unlock];
  return texture_id;
}

bool maplibre_native_present_gpu_texture(int64_t texture_id, uint32_t slot, void *surface,
                                         uint64_t shared_event, uint64_t value,
                                         uint64_t *out_present, char *error,
                                         size_t error_size) {
  [gLock lock];
  MLNGpuTexture *texture = FindTexture(texture_id, error, error_size);
  [gLock unlock];
  if (texture == nil) return false;
  // Retained from here on, while the caller's view of the event is open.
  id<MTLSharedEvent> event = (__bridge id<MTLSharedEvent>)(void *)(uintptr_t)shared_event;
  NSString *message = nil;
  if (![texture presentSlot:slot
                    surface:(IOSurfaceRef)surface
                      event:event
                      value:value
                  presented:out_present
                      error:&message]) {
    WriteError(message, error, error_size);
    return false;
  }
  return true;
}

void maplibre_native_end_gpu_texture_ring(int64_t texture_id) {
  [gLock lock];
  MLNGpuTexture *texture = gTextures[@(texture_id)];
  [gLock unlock];
  [texture endRing];
}

bool maplibre_native_gpu_texture_slot_in_use(int64_t texture_id, uint32_t slot) {
  [gLock lock];
  MLNGpuTexture *texture = gTextures[@(texture_id)];
  [gLock unlock];
  return texture != nil && [texture isSlotInUse:slot];
}

void maplibre_native_dispose_texture(int64_t texture_id) {
  [gLock lock];
  MLNGpuTexture *texture = gTextures[@(texture_id)];
  [gTextures removeObjectForKey:@(texture_id)];
  NSObject<FlutterTextureRegistry> *registry = gRegistry;
  [gLock unlock];
  if (texture == nil) return;
  [texture stopCallbacks];
  // The registry keeps the texture alive while Flutter may still copy it.
  RunOnMain(^{
    [registry unregisterTexture:texture_id];
  });
}

static const MaplibreNativeSymbol kSymbols[] = {
    {"maplibre_native_create_gpu_texture", (void *)&maplibre_native_create_gpu_texture},
    {"maplibre_native_present_gpu_texture", (void *)&maplibre_native_present_gpu_texture},
    {"maplibre_native_end_gpu_texture_ring", (void *)&maplibre_native_end_gpu_texture_ring},
    {"maplibre_native_gpu_texture_slot_in_use",
     (void *)&maplibre_native_gpu_texture_slot_in_use},
    {"maplibre_native_dispose_texture", (void *)&maplibre_native_dispose_texture},
    {NULL, NULL},
};

@implementation MaplibreNativePlugin

+ (void)initialize {
  if (self == [MaplibreNativePlugin class]) {
    gLock = [[NSLock alloc] init];
    gTextures = [NSMutableDictionary dictionary];
  }
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [gLock lock];
  gRegistry = [registrar textures];
  [gLock unlock];
}

+ (const MaplibreNativeSymbol *)symbols {
  return kSymbols;
}

@end
