## Unreleased

Platform implementations and fakes of the controllers need the new members
below. See also the
[maplibre changelog](https://github.com/josxha/flutter-maplibre/blob/main/packages/maplibre/CHANGELOG.md).

### Breaking Changes

- `MapController` has five new members: `toLngLatOnTerrain`,
  `toScreenLocationOnTerrain`, `toScreenLocationsOnTerrain`,
  `setTerrainLoadMode` and `queryTerrainElevation`. A class that
  implements `MapController`, such as a hand-written fake in an app's
  tests, must implement them.
- `StyleController` has three new abstract members: `setTerrain`,
  `terrain` and `setGlobalState`. A class that extends or implements it
  must implement them.
- `MapGestureDetector` now also sets `GestureCameraUpdate.around` on steps
  that only pan, to the point the finger moved to, so a platform can keep
  the ground under the finger. A `GestureCameraSink` that took a non-null
  `around` to mean that the step zooms or rotates must check `zoomBy` and
  `rotateBy` instead.

### Features

- `StillImageRenderer` draws a map into a PNG without showing one, for
  example to share it, with an optional 3D terrain. Not on web.
- `MapController.maybeOf` and `MapController.of` take `camera: false` to
  look up the controller without rebuilding the widget on every camera
  change, only when the map hands out a new style.

## 0.4.0-pre.2

[Check the maplibre changelog](https://pub.dev/packages/maplibre/versions/0.4.0-pre.2/changelog#040-pre2)

## 0.4.0-pre.1

[Check the maplibre changelog](https://pub.dev/packages/maplibre/versions/0.4.0-pre.1/changelog#040-pre1)

## 0.3.7+1

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#0371)

## 0.3.7

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#037)

## 0.3.6

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#036)

## 0.3.5

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#035)

## 0.3.4+1

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#0341)

## 0.3.4

[Check the maplibre changelog](https://pub.dev/packages/maplibre/changelog#034)
