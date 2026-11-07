#!/usr/bin/env bash
# The headless-browser check of maplibre_web's sparse raster-dem routing (lib/src/sparse_dem.dart)
# against the maplibre-gl version pinned in package.json: terrain over a sparse tileset (204 and
# 404, zoom in and cold jump, one and two empty zooms, a cut-out at 0 m), request counts, idle,
# a style set, and the regression without the routing. Exits non-zero when a check fails.
#
#   SPARSE_DEM_TOOLS=<dir> [PLAYWRIGHT_BROWSERS_PATH=<dir>] tool/sparse_dem_check/run.sh
#
# SPARSE_DEM_TOOLS holds node_modules: the pinned playwright and maplibre-gl are installed there
# when missing or of another version, and Chromium into PLAYWRIGHT_BROWSERS_PATH (default
# $SPARSE_DEM_TOOLS/ms-playwright). Nothing is installed globally. Needs node, npm and dart.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package="$(cd "$here/../.." && pwd)"
: "${SPARSE_DEM_TOOLS:?set SPARSE_DEM_TOOLS to the directory for node_modules}"
export SPARSE_DEM_TOOLS="$(cd "$SPARSE_DEM_TOOLS" && pwd)"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$SPARSE_DEM_TOOLS/ms-playwright}"

installed() { node -p "try { require('$SPARSE_DEM_TOOLS/node_modules/$1/package.json').version } catch { '' }"; }
pin() { node -p "require('$here/package.json').dependencies['$1']"; }
for dep in playwright maplibre-gl; do
  if [[ "$(installed $dep)" != "$(pin $dep)" ]]; then
    npm install --prefix "$SPARSE_DEM_TOOLS" --no-save --no-fund --no-audit "$dep@$(pin $dep)"
  fi
done
(cd "$SPARSE_DEM_TOOLS" && npx --no-install playwright install chromium >/dev/null)

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
(cd "$package" && dart compile js -O2 -o "$out/sparse_dem.js" test/sparse_dem/page.dart >/dev/null)
SPARSE_DEM_GL_DIST="$SPARSE_DEM_TOOLS/node_modules/maplibre-gl/dist" SPARSE_DEM_PAGE_JS="$out/sparse_dem.js" \
  node "$here/check.mjs"
