/// Clears the browser's resource timing entries.
void clearResourceTimings() {}

/// How many requests the browser made for [url].
int resourceRequests(String url) => 0;

/// Answers maplibre-gl-js requests for `<scheme>://…` URLs with the JSON
/// that [respond] completes with.
void addJsonProtocol(
  String scheme,
  Future<String> Function(String url) respond,
) => throw UnsupportedError('Only maplibre-gl-js has custom protocols.');
