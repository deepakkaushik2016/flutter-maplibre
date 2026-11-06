import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre/maplibre.dart';
import 'package:maplibre_example/utils/map_styles.dart';
import 'package:maplibre_example/utils/simulated_locations.dart';
import 'package:maplibre_geolocator/maplibre_geolocator.dart';

@immutable
class UserLocationPage extends StatefulWidget {
  const UserLocationPage({super.key});

  static const location = '/user-location';

  @override
  State<UserLocationPage> createState() => _UserLocationPageState();
}

class _UserLocationPageState extends State<UserLocationPage> {
  /// The user locations, once the location permission was granted, or a
  /// simulated walk.
  Stream<UserLocation>? _locations;

  /// Whether [_locations] is a simulated walk, for devices without a
  /// location source, such as simulators and emulators.
  var _simulated = false;
  UserLocationTracking _tracking = UserLocationTracking.position;

  @override
  void initState() {
    super.initState();
    unawaited(_requestPermission());
  }

  /// Asks for the location permission. On Windows, geolocator gets no
  /// positions until the app asked, and permission_handler does not ask there.
  Future<void> _requestPermission() async {
    String? error;
    if (!await Geolocator.isLocationServiceEnabled()) {
      error = 'The location services are turned off.';
    } else {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        error = 'The location permission was denied.';
      }
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error Showing a simulated walk.')),
      );
      _simulate();
      return;
    }
    setState(
      () => _locations = geolocatorUserLocations().handleError((Object error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }),
    );
  }

  /// Shows a walk around Innsbruck instead of the device's location.
  void _simulate() => setState(() {
    _simulated = true;
    _locations = simulatedLocations(
      center: const Geographic(lon: 11.39085, lat: 47.27574),
    );
  });

  @override
  Widget build(BuildContext context) {
    final locations = _locations;
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Location'),
        actions: [
          if (!_simulated)
            TextButton(onPressed: _simulate, child: const Text('Simulate')),
        ],
      ),
      body: MapLibreMap(
        options: MapOptions(
          style: MapStyles.protomapsLight.style,
          initCamera: const CameraUpdate.position(zoom: 1),
        ),
        children: [
          if (locations != null)
            UserLocationLayer(
              locations: locations,
              tracking: _tracking,
              trackingZoom: 15,
              onTrackingChanged: (tracking) =>
                  setState(() => _tracking = tracking),
            ),
          MapControlButtons(
            tracking: _tracking,
            // Cycles through the tracking modes.
            onTrackingPressed: () => setState(
              () => _tracking = switch (_tracking) {
                UserLocationTracking.none => UserLocationTracking.position,
                UserLocationTracking.position =>
                  UserLocationTracking.positionAndHeading,
                UserLocationTracking.positionAndHeading =>
                  UserLocationTracking.none,
              },
            ),
          ),
        ],
      ),
    );
  }
}
