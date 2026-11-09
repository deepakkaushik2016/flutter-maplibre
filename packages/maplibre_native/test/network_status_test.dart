import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_native/src/database.dart';
import 'package:maplibre_native/src/extensions.dart';
import 'package:maplibre_native_ffi/maplibre_native_ffi.dart' as mln;
import 'package:maplibre_platform_interface/maplibre_platform_interface.dart';

/// Sets [MapLibreNetwork.status] in the C library that this test loads, which
/// keeps one network status for the whole process.
void main() {
  tearDown(MapLibreNetwork.reset);

  test('converts the network status', () {
    expect(NetworkStatus.online.toMln(), mln.NetworkStatus.online);
    expect(NetworkStatus.offline.toMln(), mln.NetworkStatus.offline);
  });

  test('applies the status that was set before', () {
    MapLibreNetwork.status = .offline;
    expect(mln.getNetworkStatus(), mln.NetworkStatus.online);

    // As creating the first runtime does.
    watchNetworkStatusForTesting();
    expect(mln.getNetworkStatus(), mln.NetworkStatus.offline);
  });

  test('applies each change at once', () {
    watchNetworkStatusForTesting();
    MapLibreNetwork.status = .offline;
    expect(mln.getNetworkStatus(), mln.NetworkStatus.offline);
    MapLibreNetwork.status = .online;
    expect(mln.getNetworkStatus(), mln.NetworkStatus.online);

    // A second watch adds no second listener and keeps the status.
    watchNetworkStatusForTesting();
    MapLibreNetwork.status = .offline;
    expect(mln.getNetworkStatus(), mln.NetworkStatus.offline);
    MapLibreNetwork.reset();
    expect(mln.getNetworkStatus(), mln.NetworkStatus.online);
  });

  test('sets the status again after the app set it in the library', () {
    watchNetworkStatusForTesting();
    MapLibreNetwork.status = .offline;
    // An app that also calls the C API directly.
    mln.setNetworkStatus(mln.NetworkStatus.online);
    MapLibreNetwork.status = .online;
    MapLibreNetwork.status = .offline;
    expect(mln.getNetworkStatus(), mln.NetworkStatus.offline);
  });
}
