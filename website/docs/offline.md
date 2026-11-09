---
icon: lucide/database
---

# Offline & Cache

!!! note

    The `OfflineManager` runs on Android, iOS, macOS, Windows and Linux. On
    web, `OfflineManager.createInstance()` throws an `UnsupportedError`; a
    service worker cache is the alternative there.

Maps and the `OfflineManager` share one database, `maplibre_native.db` in the
app support directory. Maps cache the resources they load in it, and show the
regions you downloaded without network access.

The `OfflineManager` provides a set of tools to manage the cache and handle
offline maps. It enables users to download and interact with map data in areas
with limited or no internet access. Here, we’ll cover key features, usage
concepts, and API details for `OfflineManager`.

The download manager needs to be created asynchronous by
using `OfflineManager.createInstance()`. You can store the instance for later
use.

```dart

Future<OfflineManager> futureManager = OfflineManager.createInstance();
```

Don't forget to call `manager.dispose()` when you no longer need it. You
can do this for example in the `dispose` override of a flutter widget:

```dart hl_lines="3"
@override
void dispose() {
  manager.dispose();
  super.dispose();
}
```

## Cache Management

There are mutliple methods to manage and control the cache, ensuring efficient
use of storage. Head over to
the [API docs](https://pub.dev/documentation/maplibre/latest/maplibre/OfflineManager-class.html)
to learn more.

## Downloading Map Regions

Using OfflineManager, you can bulk-download specific map regions for offline
access. An `OfflineRegionDefinition` says what a region covers:

- `OfflineTilePyramidRegionDefinition` downloads every tile within a
  `GeoBox`.
- `OfflineGeometryRegionDefinition` downloads only the tiles that a geometry
  touches, such as a route as a `LineString` or an area as a `Polygon`. It
  needs far fewer tiles than the bounding box of a long or diagonal route.

Both download the tiles from `minZoom` to `maxZoom`, or to the maximum zoom
level of each tile source if that is lower.

```dart
Future<void> downloadMyMap() async {
  final stream = manager.downloadRegion(
    definition: OfflineTilePyramidRegionDefinition(
      bounds: GeoBox(/* ... */),
      styleUrl: '...',
      minZoom: 10,
      maxZoom: 14,
      pixelRatio: 1,
    ),
    metadata: {'name': 'Bregenz'},
  );
  await for (final update in stream) {
    if (update.downloadCompleted) {
      print('region downloaded: ${update.region}');
    } else {
      final status = update.status;
      print(
        '${status.completedResourceCount} / ${status.requiredResourceCount} '
            '(${((update.progress ?? 0) * 100).toStringAsFixed(0)}%)',
      );
    }
  }
}

final route = OfflineGeometryRegionDefinition(
  geometry: LineString.from(const [
    Geographic(lon: 9.7471, lat: 47.5031),
    Geographic(lon: 9.6838, lat: 47.5459),
  ]),
  styleUrl: '...',
  minZoom: 10,
  maxZoom: 15,
  pixelRatio: 1,
);
```

Resources that fail to load arrive as `OfflineResourceException` errors on
the stream, with the `reason` they failed, and the download retries them. A
region with more tiles than the offline database allows stops with an
`OfflineTileCountLimitException`. Cancelling the subscription pauses the
download; `manager.resumeDownload(regionId: id)` continues it.

`manager.getRegionStatus(regionId: id)` reports how far the download of a
region got, also while no download runs: the downloaded and required resources
and tiles, their size, and whether it is complete.

## Without a Network

Tell the maps when the device has no network, from your app's connectivity
monitor:

```dart
MapLibreNetwork.status = NetworkStatus.offline;
// ... and once the connection is back:
MapLibreNetwork.status = NetworkStatus.online;
```

While the status is offline, no request goes to the network. Maps show what
the cache and the downloaded regions hold, and draw a tile that a region
lacks from a lower zoom level of the region, or leave it out. The requests
that wait for the network are made once the status is online again.

This matters most for still images of a map, such as one to share. Offline,
a still image of a region that lacks some tiles finishes with the tiles it
has. A still image needs every resource it shows, though: without the style,
a sprite or a glyph range, it fails. If the status stays online while the
device has no network, the image fails too, because its tiles fail to load.

The status applies to the whole app, also to maps and downloads that the app
creates through `maplibre_native_ffi` itself. `MapLibreNetwork.reset()` sets
it back to online. On web, it does nothing: the browser decides when a
request can reach the network.

## Still Images

`StillImageRenderer` draws a map into a PNG without showing one, for example
to share it. Not on web, where `StillImageRenderer.isSupported` is false.

```dart
final renderer = await StillImageRenderer.createInstance();
final png = await renderer.render(
  style: const MapStyle.url('https://example.com/style.json'),
  size: const Size(512, 512),
  pixelRatio: 2,
  camera: const CameraUpdate.position(
    center: Geographic(lon: 11.4, lat: 47.3),
    zoom: 13,
    pitch: 50,
  ),
  terrain: const Terrain(sourceId: 'dem'),
  timeout: const Duration(seconds: 20),
);
renderer.dispose();
```

With a `terrain`, whose source must be in the style, the center of the camera
moves onto the ground, as on a map with `centerClampedToGround`, which takes at
least one more render. Without that, an image over high ground would have its
camera under the terrain and show only the style's background. Pass
`centerAltitude`, in meters above sea level, to place the center yourself.

An image that can't be drawn fails with a `StillImageException`: a style, sprite
or glyph range it needs is missing, or the renderer was disposed. One that takes
longer than `timeout` fails with a `TimeoutException`. Requests may overlap.

## Managing Offline Regions

After regions are downloaded, they can be managed using methods to list, merge,
or retrieve specific region details:

### Listing Offline Regions

Get a list of all downloaded regions for management or display purposes by
using `manager.listOfflineRegions()`.

### Retrieving a Specific Region

Fetch a region’s details with `manager.getOfflineRegion(regionId: 1)`, which is
useful for managing or displaying region-specific data. It returns null when
there is no region with that id.

### Merging Regions

Use `manager.mergeOfflineRegions(path: 'path/to/database')` to merge offline
regions from a secondary offline database into the main offline database.
This is typically used when you have multiple MapLibre offline databases that you
want to consolidate.

### Updating and Deleting Regions

`manager.updateRegionMetadata(regionId: 1, metadata: {...})` replaces the
metadata of a region, `manager.invalidateRegion(regionId: 1)` loads its
resources again once they are needed, and `manager.deleteRegion(regionId: 1)`
removes it.