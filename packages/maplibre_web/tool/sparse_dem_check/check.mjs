// The sparse raster-dem check of maplibre_web: the scenes of MapLibre Native's
// terrain_sparse_dem.test.cpp, in headless Chromium against the pinned maplibre-gl, with
// maplibre_web's sparse-dem routing (the compiled test/sparse_dem/page.dart) wired as
// map_state.dart wires it. Exits non-zero when a check fails. Run it through run.sh.
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import { start, requests, tilePoint, coneMeters, apexX, apexY } from './server.mjs';

const here = path.dirname(new URL(import.meta.url).pathname);
const require = createRequire(path.join(process.env.SPARSE_DEM_TOOLS, 'node_modules') + '/');
const { chromium } = require('playwright');
const pins = JSON.parse(fs.readFileSync(path.join(here, 'package.json'))).dependencies;

let failures = 0;
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures++;
};

const server = await start();
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage({ viewport: { width: 400, height: 600 }, deviceScaleFactor: 1 });
let errorEvents = 0;
await page.exposeFunction('onMapError', () => errorEvents++);
const load = async () => { await page.goto(origin); await page.waitForFunction(() => window.ready); };
await load();
const version = await page.evaluate(() => maplibregl.getVersion());
check(version === pins['maplibre-gl'], `maplibre-gl is the pinned ${pins['maplibre-gl']} (${version})`);

const apex = tilePoint(apexX + 0.5, apexY + 0.5);
const flank = tilePoint(apexX - 0.5, apexY + 1.5);
const kmPerDegree = 6371.0088 * Math.PI / 180, kmPerLng = kmPerDegree * Math.cos(flank[1] * Math.PI / 180);
const flankPoints = [];
for (const n of [-0.4, 0, 0.5, 1]) for (const e of [-0.5, 0, 0.5]) flankPoints.push([flank[0] + e / kmPerLng, flank[1] + n / kmPerDegree]);
const pitch = 50;
const pixels = () => page.evaluate(() => window.pixels());
// The share of pixels that differ by more than 8 in a channel, leaving out a band of columns
// round the vertical centre line.
const mismatch = (a, b, band = -1) => {
  let n = 0, t = 0;
  for (let y = 0; y < a.h; y++) for (let x = 0; x < a.w; x++) {
    if (Math.abs(x + 0.5 - a.w / 2) <= band) continue;
    t++; const i = (y * a.w + x) * 4;
    for (let c = 0; c < 4; c++) if (Math.abs(a.data[i + c] - b.data[i + c]) > 8) { n++; break; }
  }
  return n / t;
};
const make = async (o) => {
  await page.evaluate((o) => window.makeMap(o), { apex, pitch, ...o });
  await page.evaluate(() => map.on('error', () => window.onMapError()));
};
const jump = (o) => page.evaluate((o) => window.jumpTo(o), o);
// The worst elevation error over the flank, with every point on loaded DEM.
const coneError = async () => {
  const r = await page.evaluate((p) => window.query(p), flankPoints);
  return Math.max(...r.map((q, i) => (q.state === 'loaded' ? Math.abs((q.e ?? 0) - coneMeters(flankPoints[i])) : Infinity)));
};
const idleTimeouts = () => page.evaluate(() => window.timeouts.length);
const deep = (mode) => [...requests].filter(([k]) => k.startsWith(mode + '/') && +k.split('/')[1] > 12);
const maxElevationError = 0.25; // metres: the bilinear surface is the cone, Terrarium steps 1/256 m
const maxFrameMismatch = 0.01;

for (const zoom of [13.5, 15.5]) {
  await load();
  await make({ mode: 'dense', center: flank, zoom });
  const dense = await pixels();
  for (const mode of ['sparse204', 'sparse404']) {
    const scene = `${mode} z${zoom}`;
    // (A) zoom in from z12.
    await load(); requests.clear(); errorEvents = 0;
    await make({ mode, fix: true, center: flank, zoom: 12 });
    await page.evaluate((z) => window.easeTo(z), zoom);
    let e = await coneError();
    check(e <= maxElevationError, `${scene} zoom in: elevation within ${maxElevationError} m (${e.toFixed(3)})`);
    let m = mismatch(await pixels(), dense);
    check(m <= maxFrameMismatch, `${scene} zoom in: frame as the dense tileset's (${(m * 100).toFixed(2)} % differs)`);
    // (B) a cold jump, then two revisits.
    await load(); requests.clear(); errorEvents = 0;
    await make({ mode, fix: true, center: flank, zoom });
    e = await coneError();
    check(e <= maxElevationError, `${scene} cold jump: elevation within ${maxElevationError} m (${e.toFixed(3)})`);
    m = mismatch(await pixels(), dense);
    check(m <= maxFrameMismatch, `${scene} cold jump: frame as the dense tileset's (${(m * 100).toFixed(2)} % differs)`);
    for (const z of [11, zoom, 11, zoom]) await jump({ zoom: z });
    const most = Math.max(...deep(mode).map(([, n]) => n));
    check(most === 1, `${scene} revisits: each z13+ tile asked for once (most ${most})`);
    check(errorEvents === 0, `${scene}: no error events (${errorEvents})`);
    const timeouts = await idleTimeouts();
    check(timeouts === 0, `${scene}: idle after every move (${timeouts} timeouts)`);
    if (mode === 'sparse204' && zoom === 15.5) {
      // A style set forgets the empty tiles the page knew: they may be another tileset's now. The
      // new style changes only the source's attribution: gl-js loads it anew, and only the style
      // set clears what the routing knew.
      const before = deep(mode).reduce((a, [, n]) => a + n, 0);
      await page.evaluate(() => window.setDemStyle());
      const after = deep(mode).reduce((a, [, n]) => a + n, 0);
      check(after > before, `${scene}: a style set asks for the empty tiles again (${before} -> ${after})`);
    }
  }
  if (zoom === 15.5) {
    // The regression the routing fixes: without it, gl-js draws two empty zooms from z5.
    await load();
    await make({ mode: 'sparse204', fix: false, center: flank, zoom });
    const m = mismatch(await pixels(), dense);
    check(m >= 0.5, `sparse204 z15.5 without the routing: drawn from z5 (${(m * 100).toFixed(1)} % differs; if this fails, gl-js may no longer need the routing)`);
  }
}

// The cut-out at 0 m, top-down over its west coast, at the zooms where it is two and three
// empty zooms deep; the frame is compared away from the coast (1.5 z11 DEM pixels and 2 px).
const coast = tilePoint(apexX + 1, apexY + 2);
const kmLng = kmPerDegree * Math.cos(coast[1] * Math.PI / 180);
for (const zoom of [14.5, 15.5]) {
  await load();
  await make({ mode: 'cutdense', center: coast, zoom, pitch: 0, elevation: 0 });
  const ref = await pixels();
  await load();
  await make({ mode: 'cut204', fix: true, center: coast, zoom, pitch: 0, elevation: 0 });
  const offsets = [-1, -0.5, -0.2, 0.2, 0.5, 1];
  const pts = offsets.map((e) => [coast[0] + e / kmLng, coast[1]]);
  const q = await page.evaluate((p) => window.query(p), pts);
  const worst = Math.max(...q.map((r, i) => Math.abs((r.e ?? NaN) - (offsets[i] < 0 ? coneMeters(pts[i]) : 0))));
  check(worst <= maxElevationError, `cut-out z${zoom}: 0 m in it and the cone beside it (${worst.toFixed(3)} m)`);
  const m = mismatch(await pixels(), ref, 1.5 * 2 ** (zoom - 11) + 2);
  check(m <= 0.002, `cut-out z${zoom}: frame as the dense tileset's away from the coast (${(m * 100).toFixed(3)} % differs)`);
}

await browser.close();
server.close();
console.log(failures ? `${failures} check(s) failed` : 'all checks passed');
process.exit(failures ? 1 : 0);
