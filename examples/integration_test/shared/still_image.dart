/// Still images of a static map, the kind an app renders to share a map,
/// made below the public API on the database that every map shares. Not on
/// web.
library;

export 'still_image_stub.dart' if (dart.library.ffi) 'still_image_native.dart';
