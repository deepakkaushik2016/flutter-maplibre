// Renders the gallery styles with maplibre-gl-js in Chromium, as the web
// references for the native renders.
//
// The style JSON and the cameras come from the native test (manifest.json and
// styles/), so both engines draw exactly the same style.
//
//   GALLERY_NATIVE_DIR  where the test wrote them (default: the temp dir of
//                       the sandboxed macOS example app)
//   GLJS_DIR            the maplibre-gl 6.16.0 package (default: next to playwright)
//   PLAYWRIGHT_MODULE   path of the playwright node module
//   PLAYWRIGHT_BROWSERS_PATH  where the browsers are
//   GALLERY_ONLY        render only the names that contain this text
const fs = require('fs');
const os = require('os');
const path = require('path');

// maplibre-gl-js 6.16.0, from the node_modules next to playwright (or
// GLJS_DIR).
const GLJS = '6.16.0';
const nativeDir =
  process.env.GALLERY_NATIVE_DIR ||
  path.join(
    os.homedir(),
    'Library/Containers/com.github.josxha.maplibreExample/Data/tmp/gallery',
  );
const playwrightPath =
  process.env.PLAYWRIGHT_MODULE ||
  path.resolve(__dirname, '../../../../../.tools/gljs-harness/node_modules/playwright');
const gljsDir =
  process.env.GLJS_DIR || path.join(path.dirname(playwrightPath), 'maplibre-gl');
const outDir = path.resolve(__dirname, '../../build/style_gallery/web');

const { chromium } = require(playwrightPath);
const gljsVersion = JSON.parse(fs.readFileSync(path.join(gljsDir, 'package.json'))).version;
if (gljsVersion !== GLJS) throw new Error(`need maplibre-gl ${GLJS}, found ${gljsVersion}`);

(async () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(nativeDir, 'manifest.json')));
  fs.mkdirSync(outDir, { recursive: true });
  const browser = await chromium.launch({
    args: ['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'],
  });
  const only = process.env.GALLERY_ONLY || '';
  for (const entry of manifest) {
    if (only && !entry.name.includes(only)) continue;
    const style = JSON.parse(
      fs.readFileSync(path.join(nativeDir, 'styles', `${entry.name}.json`)),
    );
    const page = await browser.newPage({
      viewport: { width: 430, height: 760 },
      deviceScaleFactor: 2,
    });
    page.on('console', (m) => ['error', 'warning'].includes(m.type()) && console.error('console', m.text()));
    page.on('pageerror', (e) => console.error('pageerror', entry.name, e.message));
    // A module worker must come from the page's own origin, so the page and
    // the exact gl-js build are served from one fake origin.
    await page.route('http://gljs.local/**', (route) => {
      const url = new URL(route.request().url());
      if (url.pathname === '/') {
        return route.fulfill({
          contentType: 'text/html',
          body: `<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="/dist/maplibre-gl.css">
<script type="module">
import * as maplibregl from '/dist/maplibre-gl.mjs';
window.maplibregl = maplibregl;
</script>
<style>html,body,#map{margin:0;width:100%;height:100%;overflow:hidden}</style>
</head><body><div id="map"></div></body></html>`,
        });
      }
      const file = path.join(gljsDir, url.pathname.replace(/^\/dist\//, 'dist/'));
      if (!file.startsWith(gljsDir) || !fs.existsSync(file)) return route.fulfill({ status: 404 });
      const type = file.endsWith('.css') ? 'text/css' : 'text/javascript';
      return route.fulfill({ contentType: type, body: fs.readFileSync(file) });
    });
    await page.goto('http://gljs.local/');
    await page.waitForFunction(() => window.maplibregl, null, { timeout: 60000 });
    await page.evaluate(
      ({ style, entry }) =>
        new Promise((resolve, reject) => {
          const map = new maplibregl.Map({
            container: 'map',
            style,
            center: entry.center,
            zoom: entry.zoom,
            pitch: entry.pitch,
            bearing: entry.bearing,
            maxPitch: 85,
            fadeDuration: 0,
            attributionControl: false,
          });
          map.on('error', (e) => console.error('maplibre', e.error && e.error.message));
          map.once('idle', resolve);
          setTimeout(() => reject(new Error('idle timeout')), 120000);
        }),
      { style, entry },
    );
    await page.waitForTimeout(2000);
    const file = path.join(outDir, `${entry.name}.png`);
    await page.screenshot({ path: file });
    console.log('WEB', file);
    await page.close();
  }
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
