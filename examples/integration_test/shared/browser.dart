/// What the tests read from or add to the browser that runs the web map.
/// Elsewhere these do nothing, or throw where nothing could stand in.
library;

export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
