// The sparse raster-dem fixture of check.mjs, served locally: a 2000 m cone (the fixture of
// MapLibre Native's test/renderer/terrain_sparse_dem.test.cpp), Terrarium, 512 px, maxzoom 14.
// /t/<mode>/<z>/<x>/<y>.png where mode is sparse204 | sparse404 | dense | cut204 | cutdense:
// sparse has z0-12 everywhere and z13-14 only in one z12 tile, and answers every other tile 204
// (or 404); cut has a cut-out at 0 m whose tiles answer 204, and whose z11 parent straddles it.
import http from 'node:http';
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
// maplibre-gl's dist folder, and the compiled test/sparse_dem/page.dart.
const dist = process.env.SPARSE_DEM_GL_DIST;
const pageScript = process.env.SPARSE_DEM_PAGE_JS;

export const planetMaxZoom = 12, demSize = 512, apexX = 2165, apexY = 1447;
const kmPerDegree = 6371.0088 * Math.PI / 180;
export const tilePoint = (x, y, z = 12) => {
  const n = 2 ** z;
  return [x / n * 360 - 180, Math.atan(Math.sinh(Math.PI * (1 - 2 * y / n))) * 180 / Math.PI];
};
const apex = tilePoint(apexX + 0.5, apexY + 0.5);
export const coneMeters = ([lng, lat]) => {
  const north = (lat - apex[1]) * kmPerDegree;
  const east = (lng - apex[0]) * kmPerDegree * Math.cos(apex[1] * Math.PI / 180);
  return 400 + 2000 * Math.max(0, 1 - Math.hypot(north, east) / 15);
};
const subBox = [apexX + 2, apexY + 2];
const inCutTile = (z, x, y) => z >= 12 && (x >> (z - 12)) === apexX + 1 && [apexY + 1, apexY + 2].includes(y >> (z - 12));
const inCutPoint = ([lng, lat]) => {
  const n = 4096, la = lat * Math.PI / 180;
  const x = Math.floor((lng + 180) / 360 * n), y = Math.floor((1 - Math.log(Math.tan(la) + 1 / Math.cos(la)) / Math.PI) / 2 * n);
  return x === apexX + 1 && (y === apexY + 1 || y === apexY + 2);
};

const crcTable = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc = (buf) => { let c = -1; for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
  return Buffer.concat([len, td, c]);
};
function encodePNG(rgba, w, h) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
const memo = new Map();
function demTile(cut, z, x, y) {
  const key = `${cut}/${z}/${x}/${y}`;
  if (memo.has(key)) return memo.get(key);
  const n = 2 ** z, img = Buffer.alloc(demSize * demSize * 4);
  for (let row = 0; row < demSize; row++) {
    const my = (y + (row + 0.5) / demSize) / n;
    const lat = Math.atan(Math.sinh(Math.PI * (1 - 2 * my))) * 180 / Math.PI;
    for (let col = 0; col < demSize; col++) {
      const lng = (x + (col + 0.5) / demSize) / n * 360 - 180;
      const h = cut && inCutPoint([lng, lat]) ? 0 : coneMeters([lng, lat]);
      const v = h + 32768, whole = Math.floor(v), i = (row * demSize + col) * 4;
      img[i] = whole >> 8; img[i + 1] = whole & 255; img[i + 2] = Math.floor((v - whole) * 256); img[i + 3] = 255;
    }
  }
  const png = encodePNG(img, demSize, demSize);
  memo.set(key, png);
  return png;
}
function has(mode, z, x, y) {
  if (mode === 'dense' || mode === 'cutdense') return true;
  if (mode.startsWith('cut') && inCutTile(z, x, y)) return false;
  if (z <= planetMaxZoom) return true;
  return (x >> (z - 12)) === subBox[0] && (y >> (z - 12)) === subBox[1];
}

export const requests = new Map();
export function start(port = 0) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const m = url.pathname.match(/^\/t\/(\w+)\/(\d+)\/(\d+)\/(\d+)\.png$/);
    if (m) {
      const [, mode, z, x, y] = [m[1], m[1], +m[2], +m[3], +m[4]];
      const key = `${mode}/${z}/${x}/${y}`;
      requests.set(key, (requests.get(key) || 0) + 1);
      if (!has(mode, z, x, y)) {
        res.writeHead(mode.endsWith('404') ? 404 : 204, { 'Access-Control-Allow-Origin': '*' });
        return res.end();
      }
      res.writeHead(200, { 'Content-Type': 'image/png', 'Access-Control-Allow-Origin': '*' });
      return res.end(demTile(mode.startsWith('cut'), z, x, y));
    }
    if (url.pathname.startsWith('/gl/')) {
      const f = path.join(dist, path.basename(url.pathname));
      if (!fs.existsSync(f)) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'Content-Type': f.endsWith('.css') ? 'text/css' : 'text/javascript' });
      return res.end(fs.readFileSync(f));
    }
    if (url.pathname === '/sparse_dem.js') {
      res.writeHead(200, { 'Content-Type': 'text/javascript' });
      return res.end(fs.readFileSync(pageScript));
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      return res.end(fs.readFileSync(path.join(here, 'index.html')));
    }
    res.writeHead(404); res.end();
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)));
}
