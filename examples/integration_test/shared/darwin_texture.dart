/// The iOS and macOS plugin's texture ring and Metal shared events, for
/// `darwin_texture_test.dart`. Elsewhere these throw; the tests skip there.
library;

export 'darwin_texture_stub.dart'
    if (dart.library.ffi) 'darwin_texture_native.dart';
