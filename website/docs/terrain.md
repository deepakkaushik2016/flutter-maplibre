---
icon: lucide/mountain
---

# 3D Terrain

A terrain raises the map by the heights of a raster DEM source, on web and
on native. Add the source, then set the terrain on the style:

```dart
Future<void> onStyleLoaded(StyleController style) async {
  await style.sources.add(
    const RasterDemSource.url(
      id: 'terrain',
      url: 'https://demotiles.maplibre.org/terrain-tiles/tiles.json',
      tileSize: 256,
    ),
  );
  await style.setTerrain(
    const Terrain(sourceId: 'terrain', exaggeration: 1.5),
  );
}
```

`setTerrain(null)` removes it, and `style.terrain` reads it back. A style
document can also carry a `terrain` of its own. Loading a new style replaces
the terrain with that style's; a terrain set while a new style loads is
applied once it has loaded. `setTerrain` fails with a `StateError` when the
style has no raster DEM source with that ID, and on a style that a newer one
replaced: use the current one, from `onStyleLoaded` or
`MapController.style`.

Pitch the camera to see the relief, for example with
`InitialCamera.position(…, pitch: 60)` and a higher `MapOptions.maxPitch`.
By default the camera's center follows the ground, so a pitched camera stays
above it; `MapOptions(centerClampedToGround: false)` keeps it at sea level.
On native, drags and pinches keep the ground they grab under the fingers.

## Height of the ground

`MapController.queryTerrainElevation` reads the height of the terrain at a
point, as the map draws it:

```dart
final drawn = await controller.queryTerrainElevation(point);
if (drawn != null) {
  // The drawn height includes the exaggeration.
  final meters = drawn / terrain.exaggeration;
}
```

It is null without a terrain, and where no DEM tile that the map has loaded
covers the point: before its tile arrives, beyond the source's tiles, and
before the first frame. Each call is one query of the map's latest frame.

## Screen points on the ground

`toLngLat` and `toScreenLocation` answer at once. On native they project at
sea level, also over a terrain, so over high ground they can be kilometres
off; the point of a `MapEventClick` is one of them. Use the terrain
conversions where the ground matters, such as for a tap over mountains or a
widget placed on a summit:

```dart
// The ground that the map draws under a tap.
final ground = await controller.toLngLatOnTerrain(event.screenPoint);

// Where a point of the ground is drawn, and whether a ridge hides it.
final location = await controller.toScreenLocationOnTerrain(summit);
if (location != null && !location.occluded) {
  // Show a marker at location.offset.
}
```

`toLngLatOnTerrain` is null where the line of sight meets no loaded ground,
such as in the sky. `toScreenLocationOnTerrain` is null where no loaded DEM
tile covers the point, and on native for a point behind the camera. On web,
gl-js has no occlusion test, so `occluded` compares heights: it can read a
point hidden by lower ground near the top of a view pitched past about 70°
as visible.

## Load mode

On native, `MapController.setTerrainLoadMode` trades the detail of the
terrain for loading speed. It applies to every style of the map:

| Mode          | Effect                                                                  |
|---------------|-------------------------------------------------------------------------|
| `quality`     | The default. Builds every revealed tile at once; the sharpest.          |
| `balanced`    | Spreads new tiles over frames and keeps fewer of them.                  |
| `performance` | Builds the fewest tiles a frame; smoothest on a weak GPU, shortest view |

maplibre-gl-js has no load modes, so on web it does nothing.

## Frame rate

A map shows at most one new frame per Flutter frame. On iPhones with a
ProMotion display, Flutter only goes above 60 Hz when the app sets
`CADisableMinimumFrameDurationOnPhone`, see
[Installation](getting-started/setup.md). Terrain frames cost more than flat
ones, so whether a map reaches 120 Hz there depends on the device and the
view.
