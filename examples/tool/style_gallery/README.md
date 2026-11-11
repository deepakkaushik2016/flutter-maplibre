# Style gallery

Eight landscapes in two outdoor looks (Field Topo and True Earth), drawn by the
native engine and by maplibre-gl-js side by side. It is a review tool and is
not part of `all_test.dart`. It uses public sources: Mapterhorn terrain,
OpenFreeMap vector tiles, USGS National Map imagery in the US and EOX
Sentinel-2 cloudless 2016 elsewhere.

Run these from `examples/`:

```bash
# 1. Native renders (macOS). Writes PNGs, the style JSON and manifest.json to
#    the temp dir of the sandboxed app:
#    ~/Library/Containers/com.github.josxha.maplibreExample/Data/tmp/gallery
flutter test integration_test/style_gallery_test.dart -d macos

# 2. Web references: 860x1520 PNGs in build/style_gallery/web. Reads the style
#    JSON of step 1, so both engines draw the same style.
node tool/style_gallery/reference.cjs

# 3. Copies the native PNGs to build/style_gallery/native and writes
#    build/style_gallery/index.html with the mean absolute RGB difference.
python3 -I tool/style_gallery/report.py
```

Environment:

- `GALLERY_ONLY=<text>`: render only the names that contain it. For the test,
  pass `--dart-define=GALLERY_ONLY=<text>`.
- `GALLERY_NATIVE_DIR`: where step 1 wrote its files, if not on macOS.
- `PLAYWRIGHT_MODULE` and `PLAYWRIGHT_BROWSERS_PATH`: the playwright node
  module (default `.tools/gljs-harness/node_modules/playwright` of the
  workspace) and its browsers.

The difference is not a gate. Until the native engine draws the sky, True Earth
differs most at the top of the image.

`integration_test/shared/gallery_data.dart` holds the OpenFreeMap Liberty layers
that the styles keep and the Yosemite trails.
