---
title: 'Installation'
icon: lucide/sparkles
---

# Installation

## Add the dependency

!!! info "Pre-release"

    Version 0.4.0 is available as a pre-release,
    `0.4.0-pre.2`, while it is being tested. Please
    [report bugs](https://github.com/josxha/flutter-maplibre/issues/new?labels=bug&template=1-bug.yml)
    you find. If you upgrade from 0.3.x, read the
    [migration guide](../migrate/upgrade-from-v0.3.x.md).

=== "Run command"

    Add `maplibre` to your project by running this command:

    ```bash
    flutter pub add maplibre:^0.4.0-pre.2
    ```

=== "Edit `pubspec.yaml`"

    Alternatively, add it directly as a dependency to your `pubspec.yaml` file:

    ```yaml title="pubspec.yaml" hl_lines="2"
    dependencies:
      maplibre: ^0.4.0-pre.2
    ```

    and then run `flutter pub get` to install the package.

    ```bash
    flutter pub get
    ```

The version constraint `^0.4.0-pre.2` also accepts the later 0.4 pre-releases
and 0.4.0 itself once it is out.

The packages need Dart 3.13 and Flutter 3.47 or newer. Some platforms need
setup steps, see [Platform setup](platforms.md).

## Plugins

| Package               | Used for                                                                                                    |
|-----------------------|-------------------------------------------------------------------------------------------------------------|
| `maplibre_geolocator` | Shows the positions of [geolocator](https://pub.dev/packages/geolocator) as [user location](../user-location.md) |

## Platform support

| Platform | Implementation    | Renderer        | Rendering backend                      | Minimum version         |
|----------|-------------------|-----------------|----------------------------------------|-------------------------|
| Web      | `maplibre_web`    | MapLibre GL JS  | WebGL 2                                | Browsers with WebGL 2   |
| Android  | `maplibre_native` | MapLibre Native | OpenGL ES 3.0 (default) or Vulkan      | Android 7.0 (API 24)    |
| iOS      | `maplibre_native` | MapLibre Native | Metal                                  | iOS 15                  |
| macOS    | `maplibre_native` | MapLibre Native | Metal                                  | macOS 14.3              |
| Windows  | `maplibre_native` | MapLibre Native | Vulkan, shared with Flutter via D3D11  | Vulkan 1.1 driver       |
| Linux    | `maplibre_native` | MapLibre Native | Vulkan, shared with Flutter via OpenGL | Vulkan 1.1 driver       |

!!! tip "120 Hz on iPhone"

    Flutter only draws more than 60 frames a second on an iPhone with a
    ProMotion display when the app's `ios/Runner/Info.plist` sets
    `CADisableMinimumFrameDurationOnPhone` to `true`, and a map shows at
    most one new frame per Flutter frame, so a map can't go above 60 Hz
    without it. The plugin runs no display link of its own. Whether a map
    then reaches 120 Hz depends on how long its frames take, and it hasn't
    been measured on a ProMotion iPhone yet:

    ```xml
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
    ```

!!! warning "Only on web"

    Projections other than Mercator and `VideoSource` are only supported on
    web. On every other platform, `setProjection` keeps Mercator.

## Development version

!!! warning

    The development version is not considered stable and shouldn't be
    used in production systems.

Depend on the packages from the Git repository. `maplibre` depends on
the other packages by version, so override them, too:

```yaml title="pubspec.yaml"
dependencies:
  maplibre:
    git:
      url: https://github.com/josxha/flutter-maplibre
      path: packages/maplibre

dependency_overrides:
  maplibre_native:
    git:
      url: https://github.com/josxha/flutter-maplibre
      path: packages/maplibre_native
  maplibre_platform_interface:
    git:
      url: https://github.com/josxha/flutter-maplibre
      path: packages/maplibre_platform_interface
  maplibre_web:
    git:
      url: https://github.com/josxha/flutter-maplibre
      path: packages/maplibre_web
```

### The terrain build of the C library

The development version needs a build of the MapLibre Native C library with
the terrain API, which no release of `maplibre_native_ffi` on pub.dev has yet.
`maplibre_native` therefore depends on the binding by Git, from the
[terrain fork](https://github.com/deepakkaushik2016/maplibre-native-ffi) at the
tag `terrain-3d-202611.5`.

The build hook of the binding downloads the C library for each target and
checks it against digests pinned at that tag. By default it looks on the
upstream release host, which has no terrain release, so an app has to name the
fork's releases in its own root `pubspec.yaml`:

```yaml title="pubspec.yaml"
hooks:
  user_defines:
    maplibre_native_ffi:
      release_url: https://github.com/deepakkaushik2016/maplibre-native-ffi/releases/download
```

- Hooks read user defines only from the root `pubspec.yaml` of the app or pub
  workspace, so the setting doesn't reach an app from a dependency.
- The URL is the base of the downloads; the hook adds the tag and the archive
  name.
- Without the setting, the build stops with `HTTP 404` on the download.
- The app needs no dependency on `maplibre_native_ffi`, unless it imports the
  binding itself. Then it has to name the same Git `url`, `ref` and `path`.
- The first build for each target needs network access.
