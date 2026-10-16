# Design research: two style explorations

> **Map data:** all renderings, scenes, showcases and map sheets in this folder are made from OpenStreetMap data, © OpenStreetMap contributors, available under the [Open Database License (ODbL)](https://www.openstreetmap.org/copyright). Reference images collected during the research (`*/references/web/`, `*/references/user/`) are third-party work and are kept local only; they are not part of this repository.


Two alternative looks for the Straßenraumkarte, each with a mission statement, style attributes, research notes, reference images and — since the night of 2026-10-15 — a **working renderer** in `rust/srk-render` that draws the style directly from PostGIS.

| | Exploration | Mission in one line |
|---|---|---|
| ![](01-landscape-architecture/current.jpg) | [01 — Landscape-architecture plan](01-landscape-architecture/README.md) · `srk-render --layers la` | A site plan a landscape architect drew for the street: cool sage/khaki ground, illustrated tree symbols, calm white buildings with a crisp outline and the odd red roof. |
| ![](02-fantasy-ink-map/current.jpg) | [02 — Fantasy-book ink map](02-fantasy-ink-map/README.md) · `srk-render --layers ink` | A hand-drawn ink map from a fantasy novel: plan-view city with hatched roofs, upright trees and landmarks, monochrome with one category lifted out in an accent ink. |

## Decisions so far

| Question | Decision | Why |
| --- | --- | --- |
| Which renderer? | **Rust (`srk-render`)**, new presets `la` and `ink` next to `full-approx` | Both styles are pixel craft (hatching, jitter, blur, painter's order, textures). In Rust every stroke is code we can iterate on and judge from rendered images; QGIS would need expression/geometry-generator gymnastics, MapLibre cannot do the raster effects. 64 tiles render in ~2.5 s. |
| Seamless tiles? | All randomness is seeded from **world coordinates** (EPSG:3857 metres) or OSM ids; densities use a zoom-scaled world cell (`zcell`) | Neighbouring tiles and metatiles produce identical pixels at their shared edge. |
| Ink: houses in 3D? | **No.** Plan view + roof hatch along the slope + ridge + cross-hatched shaded roof half + narrow south facade band (z18+). Only landmarks and trees stand up. | Tobias: dense rows of houses would collide in an oblique view. The roof treatment gives volume without occlusion. |
| Ink: accent colour | One category per render: `SRK_ACCENT` = `playground` (default), `bench`, `tree` or `none` | Requirement: highlight one category, rest stays black-and-white ink. |
| LA: palette | Swatches from Tobias's Pinterest board (`#EAE9E3 #CBD4BC #A6A48C #85835F …`) | The first mockup was too yellow/earthy; the board is cooler and greyer. |

## Layout

```
docs/design-research/
├── README.md                     this overview
├── index.html                    static overview page (current images, sheets, step history) — open locally
├── NIGHT-2026-10-15.md           report of the overnight iteration run
├── scenes/                       the four test scenes: QGIS today, Rust full-approx baseline
├── tools/                        viewer, scene rendering, steps, legends, sheets, overview page (see Tooling)
├── 01-landscape-architecture/
│   ├── README.md                 mission statement, attributes, pipeline mapping
│   ├── current.jpg               latest rendering of the four scenes
│   ├── legend.jpg                legend sheet (tools/legend.py)
│   ├── steps/NN-…/               one folder per iteration: sheet.jpg, detail*.jpg, before-after.jpg, README.md
│   ├── research-notes.md         full research: palette, line weights, tree vocabulary, references
│   ├── mockups/                  first target pictures (image post-processing, superseded)
│   └── references/               README committed; web/ and user/ images stay local (.gitignore)
└── 02-fantasy-ink-map/           same structure
```

## Rendering the styles

Needs the PostGIS database with processed Straßenraumkarte tables (for the scenes: the Schillerkiez bbox is enough, see below) and a release build of `srk-render`.

```bash
# one-time: DB for the scene area (Docker stack from docker/README.md; ~1.5 min, < 100 MB)
BBOX=13.4102,52.4680,13.4520,52.4832 ./docker/run-berlin.sh
(cd rust/srk-render && cargo build --release)

# the six scenes at z19 (or 16–18 as third argument) → PNG tiles + stitched scenes
docs/design-research/tools/render_scenes.sh la  /tmp/la
docs/design-research/tools/render_scenes.sh ink /tmp/ink
SRK_ACCENT=bench docs/design-research/tools/render_scenes.sh ink /tmp/ink-bench

# any area / zoom range, like the production farm
DB_PORT=5433 PGPASSWORD=postgres rust/srk-render/target/release/srk-render \
  --layers ink --bbox 13.4132,52.4715,13.4312,52.4821 --zmin 16 --zmax 19 --format webp --out /tmp/ink-tiles
```

Code: [`style_la.rs`](../../rust/srk-render/src/style_la.rs), [`style_ink.rs`](../../rust/srk-render/src/style_ink.rs), shared helpers (queries, world noise, masks, hatching, wobble, blur, labels) in [`style_kit.rs`](../../rust/srk-render/src/style_kit.rs).

## Szenen vergleichen / Comparing scenes

Four questions, four tools. Which viewer is for what, and the Catalyst look they share: [docs/VIEWERS.md](../VIEWERS.md).

| Question | Tool |
| --- | --- |
| How does one scene look in each variant? | `render_scenes.sh` → one PNG per scene |
| What changed since the last step? | `save_step.sh … auto` → `before-after.jpg` |
| Did an unrelated change move pixels? | `regress.sh`, `seam_check.sh` |
| Compare variants, QGIS and the vector channel interactively | `serve_viewer.sh` → viewer, with a link to the vector compare |

The scenes are `a` Herrfurthplatz, `b` Schillerpromenade, `c` Hasenheide-Rand, `d` Hofblöcke, `e` Richardplatz, `f` Körnerpark (Berlin Neukölln, default bbox).

### 1. Render scenes

Needs PostGIS on `localhost:5433` (see [docker/README.md](../../docker/README.md)) and a release build of `srk-render`. Options go before the layers:

```bash
docs/design-research/tools/render_scenes.sh la /tmp/la
docs/design-research/tools/render_scenes.sh --env SRK_LA_PALETTE=vivid la /tmp/la-vivid
docs/design-research/tools/render_scenes.sh --env SRK_INK_OBLIQUE=freestanding ink /tmp/ink-oblique
docs/design-research/tools/render_scenes.sh --env SRK_INK_PAPER=white ink /tmp/ink-white 18
docs/design-research/tools/render_scenes.sh --scenes a,e --png-only ink /tmp/ink-quick 17
```

- `--env KEY=VALUE` (repeatable) sets a variant switch: `SRK_LA_PALETTE=vivid`, `SRK_INK_OBLIQUE=freestanding`, `SRK_INK_PAPER=white`, `SRK_ACCENT=playground|bench|tree|none`.
- `--scenes a,e` renders some scenes; `--png-only` deletes the tile folder after stitching. The zoom argument (19 default, 16–18) keeps the same area with fewer tiles.
- Keep render folders in `/tmp`; they are large.

### 2. Save a step with before and after

```bash
docs/design-research/tools/save_step.sh docs/design-research/02-fantasy-ink-map NN-slug /tmp/ink-oblique README-step.md auto
python3 docs/design-research/tools/make_index.py
```

`save_step.sh` writes `steps/NN-slug/{sheet.jpg, sheet-ef.jpg, detail.jpg, README.md}`. With `auto` it also writes `before-after.jpg` against the latest earlier step that has a `detail.jpg`; pass a step slug or folder instead for another baseline. Then commit code, step folder and `index.html` together.

### 3. Regressions and seams

```bash
docs/design-research/tools/regress.sh             # golden tiles for la and ink variants, then the seam check
docs/design-research/tools/regress.sh --only la   # one preset
docs/design-research/tools/regress.sh --update    # after an intended style change: new baseline
docs/design-research/tools/seam_check.sh la       # metatile 1 vs 4, healthy is < 0.1 % mean
```

`regress.sh` compares every tile with `tmp/regress-baseline/<case>/`; exit 0 is ok, 1 is a regression, seam or determinism failure, 2 means no baseline yet (run `--update`). Diff images of failing tiles are in `tmp/regress-diff/`.

### 4. Interactive viewer

```bash
docs/design-research/tools/serve_viewer.sh                   # render all variants for Berlin Neukölln, serve on :8017
SKIP_RENDER=1 docs/design-research/tools/serve_viewer.sh     # serve the tiles that already exist in tmp/design-tiles
VARIANTS="la ink" docs/design-research/tools/serve_viewer.sh "" 8019   # some variants only, another port
```

Open <http://127.0.0.1:8017/>. Layers: `la`, `la-vivid`, `ink`, `ink-bench`, `ink-tree`, `ink-oblique`, `ink-white`, `full-approx` (Rust baseline) and `qgis` (today's QGIS tiles, the reference).

- **Modes:** *Eine Ebene* (`single`), *Wischen* (`swipe`, draggable divider), *Nebeneinander* (`side`, two synced maps). Keys `1` `2` `3`; `x` swaps A and B; `←` `→` jump through the scenes.
- **URL state:** `#map=zoom/lat/lng&a=<layer A>&b=<layer B>&mode=single|swipe|side&split=0.5&frames=1`. `split` is the swipe position (swipe only), `frames=1` shows the scene frames. Example: `#map=18/52.4758/13.42985&a=la&b=qgis&mode=swipe&split=0.5`.
- **QGIS reference:** linked automatically for the Berlin bbox (from `render/tiles` of this checkout or the main checkout). For another area set `QGIS_TILES=<dir>`.
- **Vector channel:** **Vektor-Vergleich ↗** in the header opens the vector compare on the same view (needs `bun run dev` in `vector/`).

Another area, here Langerwehe (bbox and tiles in [langerwehe/README.md](langerwehe/README.md)). The tile folder needs one link per variant folder; `INDEX_ONLY=1` writes only `index.html`, `layers.json` and `area.json` (no render, no server):

```bash
mkdir -p tmp/langerwehe/www && ln -sfn ../la tmp/langerwehe/www/la
OUT=tmp/langerwehe/www AREA_NAME="Langerwehe" VIEW_CENTER=50.8176,6.3581 VIEW_ZOOM=17 \
  INDEX_ONLY=1 docs/design-research/tools/serve_viewer.sh 6.335,50.805,6.381,50.827
(cd tmp/langerwehe/www && python3 -m http.server 8018 --bind 127.0.0.1)
```

The Langerwehe view has no scene list: scenes belong to the Berlin bbox.

### 5. Vector compare (MapLibre)

```bash
cd vector && bun run dev
# http://127.0.0.1:5177/?compare=1&location=intersection&mode=side-by-side&panes=qgis,rust,vector
```

Panes: QGIS (`render/tiles`), Rust (`audit/tile-regression/runs/latest-rust`, or `RUST_TILES_ROOT=<dir>`), vector (PMTiles). Swipe and blend overlay a raster on the vector. Pointing `RUST_TILES_ROOT` at a variant folder such as `tmp/design-tiles/la` should show that variant in the Rust pane; not tried yet. The Rust pane is empty at a preset outside `latest-rust`'s tiles.

## Tooling

All tools live in `tools/`, run from the repository root, and use `rust/srk-render/target/release/srk-render` — set `SRK_BIN=<path>` to use another build (e.g. one from a sibling worktree). DB defaults: `localhost:5433`, `postgres`/`postgres`.

**Overview page** — `python3 docs/design-research/tools/make_index.py` writes [`index.html`](index.html): both explorations side by side, current images, legends, map sheets and the whole step history (README text and every image, newest first). Relative links only: open it from disk or any static server. Click an image for the lightbox (←/→ walks the step, click = 1:1, Esc closes). Re-run after saving a step.

**Interactive viewer** — `docs/design-research/tools/serve_viewer.sh [bbox] [port]` renders LA, LA vivid, ink (accent playgrounds / benches / trees, oblique, white paper) and the Rust baseline at z16–19 for all six scenes into `tmp/design-tiles/` and serves <http://127.0.0.1:8017/>.

- Modes: *Eine Ebene*, *Wischen* (swipe: two layers, draggable divider) and *Nebeneinander* (two synced maps). Keys `1`/`2`/`3`, `x` swaps A and B, `←`/`→` jump through the scenes.
- Scene jump list (A–F) and optional scene frames; the whole state is in the URL, so a link shows exactly the same comparison, e.g. `#map=19/52.47735/13.42185&a=la&b=qgis&mode=swipe&split=0.5`.
- Reference layer `qgis`: today's QGIS tiles (jpg, z15–20), symlinked from `render/tiles` of this checkout or the main checkout (`QGIS_TILES=<dir>` to point elsewhere).
- `SKIP_RENDER=1` serves existing tiles, `VARIANTS="la ink"` renders only some variants, `ZMAX=20` renders z20 too.
- The script writes `layers.json` (which variant folders exist, format, zoom range) and `area.json` (title, bounds, start view, scene list) next to the tiles. `AREA_NAME`, `SCENES=berlin|none`, `VIEW_CENTER=lat,lng` and `VIEW_ZOOM` set the area; the Berlin scenes apply only to the default bbox.
- `INDEX_ONLY=1 OUT=<dir>` writes just `index.html`, `layers.json` and `area.json` into another tile folder (no render, no server), e.g. for the Langerwehe viewer.

**Scenes** — `render_scenes.sh [options] <layers> <out-dir> [zoom]` renders the six scenes (z19, or the same area at 16–18) and stitches them to `<out-dir>/<scene>.png`.

- `--env KEY=VALUE` (repeatable) passes a variant switch: `SRK_LA_PALETTE=vivid`, `SRK_INK_OBLIQUE=freestanding`, `SRK_INK_PAPER=white`, `SRK_ACCENT=playground|bench|tree|none`.
- `--scenes a,e` renders only some scenes; `--png-only` deletes the tile folder afterwards (saves disk — keep render dirs in `/tmp` and delete them).

**Steps** — `save_step.sh <exploration-dir> <NN-slug> <render-dir> <readme.md> [previous-step|auto]` writes `sheet.jpg`, `sheet-ef.jpg`, `detail.jpg` and the README into `steps/NN-slug/`. With a previous step (slug, folder, or `auto` = the latest earlier step with a `detail.jpg`) it also writes `before-after.jpg`: detail and sheet of both steps side by side.

**Legends** — `python3 docs/design-research/tools/legend.py la|ink [--env KEY=VALUE] [--columns 6] [--out file]` looks up one representative feature per class in PostGIS (deep inside an area, the middle of a line, a solitary tree …), renders the tiles around it with srk-render and lays out a legend sheet with real map samples: lawn, scrub, flower bed, woodland, water, sand, playground, pitch, cemetery, allotments, parking, block, small houses, church, broadleaved / conifer / street trees, bench, hedge, fence, wall, embankment, railway. Default output `<exploration>/legend.jpg`; `--only lawn,water` for a subset. Takes ~1–3 min (≈ 60 tiles).

**Map sheets** — `python3 docs/design-research/tools/map_sheet.py ink|la <stitched map.png> <out.jpg> --zoom 17` adds frame, title (cartouche / title block), compass rose / north arrow and scale bar → `*/map-sheet-schillerkiez.jpg`. `--legend <legend.jpg>` adds a legend band below the map (render the legend with `--columns 8` for a wide strip); `--white` for white-paper ink maps, `--paces` for a fantasy scale bar.

**Seams** — `seam_check.sh <layers> [bbox] [zoom]` compares metatile 1 vs 4 (see Gotchas).

## Gotchas (learned the hard way)

- **Seamless tiles need world-anchored *everything*.** Noise, scatter and hatch phase from world coordinates is not enough: any size derived from the *render extent* drifts between metatile layouts. `ctx.m()` first used `mercator_scale(extent)` (centre latitude of the buffer); a 4×4 metatile has a slightly different centre than a single tile, so hatch spacing differed by a fraction of a pixel and 22 % of the ink pixels changed. Fix: `Ctx::ref_scale()` takes 1/cos φ at the centre of the **z10 tile** containing the extent. Also compute hatch phase in `f64` — world positions in pixels are ~10⁸ and `f32` loses whole pixels.
- Check it with `tools/seam_check.sh <layers>` (metatile 1 vs 4); healthy is < 0.1 % mean.
- `srk-render` links two `tiny-skia` versions (ours and resvg's). Render SVG (labels) into a `resvg::tiny_skia::Pixmap` and copy the bytes over (`Pixmap::from_vec`).
- `building:part` polygons lie on top of their building; draw them as lines only or they double every roof (and the church).

## How to work on an exploration

1. Read the exploration's README (mission statement first) and its research notes.
2. Add own screenshots to `references/user/` and note them in `references/README.md`.
3. Change `style_la.rs` / `style_ink.rs`, render the scenes, look at them.
4. Save the iteration with `tools/save_step.sh <exploration> NN-slug <render-dir> <readme.md> auto` (writes a before/after against the previous step), run `tools/make_index.py`, and commit code + step folder + `index.html` together.
5. Record findings and gotchas in the exploration's README.

## Status

- 2026-10-15 (day): research folders, mission statements, image-processing mockups for four scenes.
- 2026-10-15/16 (night): both styles implemented in Rust and iterated in steps (see `steps/` and [NIGHT-2026-10-15.md](NIGHT-2026-10-15.md)).
