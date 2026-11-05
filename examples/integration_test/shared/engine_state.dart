/// What MapLibre Native applied to a map, read below the public API, for
/// tests that check a call reached the engine. On web these return null.
library;

export 'engine_state_stub.dart'
    if (dart.library.ffi) 'engine_state_native.dart';
