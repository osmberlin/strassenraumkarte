# Viewers and compare UIs

Every map viewer and compare page in the repo, what it is for, and which one to use. Scene comparison workflow (rendering, steps, checks, URL parameters): [design-research/README.md](design-research/README.md#szenen-vergleichen--comparing-scenes).

## Inventory

| Viewer / UI | Purpose | Data source | How to start | Overlap |
| --- | --- | --- | --- | --- |
| **Design viewer** [`docs/design-research/tools/viewer.html`](design-research/tools/viewer.html) (Leaflet, Catalyst look) | Compare design variants (LA, LA vivid, ink variants, Rust full-approx) with each other and with QGIS: single layer, swipe, side by side, scene jumps | Per tile folder: `<variant>/{z}/{x}/{y}.webp`, `qgis` = symlink to `render/tiles`, `layers.json`, `area.json` (written by the script) | `docs/design-research/tools/serve_viewer.sh [bbox] [port]` → `:8017` (Berlin default). Other areas: `OUT=<dir> INDEX_ONLY=1` | QGIS reference overlaps the QGIS run preview; Rust full-approx overlaps the vector compare's Rust pane |
| **Design overview** [`docs/design-research/index.html`](design-research/index.html) | Step history of both explorations: sheets, legends, before/after, lightbox | Images and README text in `docs/design-research/*/steps/`, written by `tools/make_index.py` | `python3 docs/design-research/tools/make_index.py`, then open the file | None (static document, no tiles) |
| **QGIS run preview** [`render/tiles/preview.html`](../render/tiles/preview.html) + [`render/preview_server.py`](../render/preview_server.py) (Leaflet, Catalyst look) | Look at the QGIS XYZ tiles; start `run.sh` with a bbox and a PBF or Geofabrik source from the page | `render/tiles/{z}/{x}/{y}.jpg` (gitignored), `data/osm/*.pbf`, `run.sh` | `./render/preview_server.py` → `http://127.0.0.1:8000/preview.html`. Tiles only: `cd render/tiles && python3 -m http.server 8000` | Its tiles are the design viewer's `qgis` layer and the vector compare's QGIS pane |
| **Vector app** [`vector/`](../vector/) main preview (MapLibre, Catalyst look) | Vector channel (PMTiles) with the QGIS port of the style; debug tile style; legend | `vector/public/tiles/strassenraumkarte.pmtiles` (from `bun run pipeline`), sprites | `cd vector && bun install && bun run dev` → `http://127.0.0.1:5177/` | Same app as the compare mode |
| **Vector compare** `?compare=1` in the same app (`src/compare/ComparePage.tsx`, Catalyst look) | QGIS · Rust full-approx · Vector panes: side by side, swipe, blend; location presets; tile IDs | QGIS at `/raster/` from `render/tiles`; Rust at `/raster-rust/` from `audit/tile-regression/runs/latest-rust` (or `RUST_TILES_ROOT=<dir>`); vector PMTiles | Same dev server: `http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side&panes=qgis,rust,vector` | Design viewer (Rust full-approx + QGIS, no vector pane). The design viewer's **Vektor-Vergleich ↗** button opens this page on the same view |
| **Compare gallery** `vector/compare-output/index.html` | QGIS vs vector screenshots per compare location, with pixel diff | `compare-output/` (gitignored) from `bun run screenshots` | Dev server and `preview_server.py` running, then `bun run screenshots` in `vector/` | Static report; `montage.ts` makes the same images as JPEG rows |
| **Tile regression gallery** `audit/tile-regression/runs/<suite>/index.html` | QGIS vs Rust per tile, pixelmatch ratio and bands | `runs/<suite>/{qgis,rust,compare}` (gitignored), from `render-suite*.sh` | `bun run scripts/compare-run.ts --ref-dir … --cand-dir …` in `audit/tile-regression/` | Static report; the same tiles as the vector compare's panes |
| Screenshot scripts (no UI) | Save screenshots for `docs/`: `vector/scripts/capture-viewers.ts` (all four viewers, console check), `vector/scripts/verify-preview.ts` (one vector preview), `vector/scripts/montage.ts` (rows of runs) | Running viewers | `cd vector && STEP=before bun run capture-viewers`, `bun run verify-preview`, `bun run scripts/montage.ts <out> …` | `capture-viewers` replaces the single-page part of `verify-preview` |

Not viewers: `docs/design-research/tools/legend.py` and `map_sheet.py` (images), `audit/tile-compare/compare-tiles.py` and `audit/sql-compare/compare.py` (metrics).

## Decision: separate, one entry point for scenes, same look

**Keep the viewers separate. Do not merge them into one app.** They differ in the thing they draw and in what they need to run:

- The **MapLibre app** renders vector tiles (PMTiles) with the style in `vector/src/style`. Leaflet shows raster XYZ only, so a merged viewer would need a second renderer for the vector channel anyway.
- The **QGIS run preview** talks to a server (`preview_server.py`: PBF list, `run.sh` jobs, status). A static viewer like the design viewer cannot host that API.
- The **design viewer** serves rendered variant folders with a `layers.json` / `area.json` per folder. That lets one page compare any number of variants and areas, which the vector app does not do.

**One obvious entry point for the tile-comparison use case:** the design viewer (`serve_viewer.sh`) is where you start when comparing scenes. Its **Vektor-Vergleich ↗** button opens the vector compare on the same view (`?compare=1&panes=qgis,rust,vector&map=zoom/lat/lng`). The vector compare stays the only place that shows the vector channel next to the others.

Known limits, not fixed here:

- The vector compare's Rust pane shows one run (`runs/latest-rust` or `RUST_TILES_ROOT`). Pointing `RUST_TILES_ROOT` at a design variant folder (`tmp/design-tiles/la`, same `z/x/y` layout) should show that variant there. This is not verified yet.
- The Rust pane is empty at the `intersection` preset with the current `latest-rust` run: its z16 tiles cover x 35206–35208, the preset is outside that range. This is data coverage, not a bug. The 404s in the console are the missing Rust tiles.
- `serve_viewer.sh` links `render/tiles` as the QGIS layer only for the Berlin bbox. Other areas get no QGIS layer unless `QGIS_TILES=<dir>` is set (fixed in this change, see below).

## Decision: removals

**None.** Each viewer above has a documented workflow (design-research README, `vector/README.md`, top-level README), and none is a copy of another. `vector/scripts/verify-preview.ts` overlaps `capture-viewers.ts`, but it is still in `package.json`; it can go once `capture-viewers` has replaced its use.

## Same look (Catalyst)

The design viewer's header and controls are the reference: [`viewer.html`](design-research/tools/viewer.html) `<style type="text/tailwindcss">` (Tailwind v4 browser build, Catalyst tokens: zinc, `bg-white/90` header, outline buttons, segmented control, chevron select, badges, `kbd`).

| Viewer | How the look is applied |
| --- | --- |
| Design viewer | Reference (no change except the vector link button) |
| Vector app (main and compare) | Plain CSS in `vector/src/app.css`, same tokens, no Tailwind dependency. Header `.bar`, `.btn`, `.seg` (Mode control in compare), `.select` (Location), `.compare-label` as badges. Commit `56e8406` |
| QGIS run preview | Plain CSS in `render/tiles/preview.html`, same tokens on the existing `srk-*` classes. Markup and JS untouched. Commit `159c409` |
| Static galleries (`design-research/index.html`, compare and tile-regression reports) | Not changed: documents with their own reading layout, not tools |

Inter is loaded from Google Fonts in all three pages (the design viewer already did).

Screenshots before and after, with the console check per viewer: [viewers/01-catalyst-look](viewers/01-catalyst-look/README.md).

## Verification

Checked in the built-in browser and with `bun run capture-viewers` (Playwright):

- Vector main and compare: no console or page errors on the main map. Mode switches (Side by side, Swipe, Blend) still change the mode and the URL (`mode=swipe`); swipe slider shows.
- QGIS run preview: no console errors; zoom, layer panel and run form render with the new look.
- Design viewer: styled, the link carries the current view (`#map=` → `?map=`). Console has one request to `/tailwindcss` that fails (`ERR_ABORTED`) while the Tailwind browser build resolves `@import "tailwindcss"`; the page still renders with its styles. Not changed in this pass.

## Changes in this pass

- `vector/`: Catalyst header and compare controls; Mode is a segmented control with the same handler; `bun run capture-viewers` script.
- `render/tiles/preview.html`: Catalyst controls (CSS only).
- `docs/design-research/tools/viewer.html`: **Vektor-Vergleich ↗** link, updated with the map view.
- `docs/design-research/tools/serve_viewer.sh`: prints the vector compare URL; QGIS layer only for the Berlin bbox unless `QGIS_TILES` is set; a line about the viewer in its header comment.
- `docs/design-research/README.md`: section "Szenen vergleichen / Comparing scenes".
- Top-level `README.md`: pointer to this file.
