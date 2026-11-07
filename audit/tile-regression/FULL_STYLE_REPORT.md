# Full-style report — QGIS vs Rust `full-approx`

**Date:** 2026-08-01  
**Run:** `audit/tile-regression/runs/full-approx-20260801-175611/`  
**Bbox:** `13.4132,52.4715,13.4312,52.4821` (starter)  
**Suite:** `manifest-full.json` · 10 tiles · z15–z20

## Verdict (honest)

Rust `full-approx` is **visually recognizable** as the Straßenraumkarte at intersection zoom: green parks, pink buildings with soft SE drop-shadows, soft tree crowns, and road polygons. It is **not** bit-exact QGIS parity. Mean pixelmatch vs full-style QGIS is ~**11.0%** after a shadows/trees/landuse pass (was ~12.7%). Still above the aspirational &lt;10% target — labels, RasterFill textures, and richer effects remain the gap. A roads-only / `highway_area`-isolate candidate against full-style QGIS would sit ~**50%+** mismatched.

## Before → after

| Stage | Rust paint | vs QGIS full-style (same 10 tiles) |
| --- | --- | --- |
| Before this pass | `highway_area` isolate only | Roads on blank `#ededed`; parks/buildings/trees missing → expected ~50%+ pixelmatch |
| After `full-approx` v1 | landuse…trees flat fills | mean **14.12%**, max **16.69%** |
| After draw-order / tree α | path/service under `highway_area`; softer tree alpha | mean **12.71%**, max **14.21%** |
| After shadows + landuse + soft trees | building drop-shadow; crown α≈0.62 + under-disk; landuse greys expanded | mean **11.04%**, max **13.27%** |

## Engines

| Side | Command |
| --- | --- |
| Ref | QGIS `xyz_tiles.py` — **no `--layers`** · `--format png --metatile 1 --gutter 1 --workers 1` |
| Cand | `srk-render --layers full-approx` |

Timing (this host): QGIS ~46 s / 10 tiles; Rust ~287 ms / 10 tiles (~28.7 ms/tile with shadow blur).

## Intersection tile `17/70422/43011`

| | Path |
| --- | --- |
| QGIS ref | `runs/full-approx-20260801-175611/qgis/17/70422/43011.png` |
| Rust cand | `runs/full-approx-20260801-175611/rust/17/70422/43011.png` |
| Diff | `runs/full-approx-20260801-175611/compare/tiles/17/70422/43011/diff.png` |
| Gallery | `runs/full-approx-20260801-175611/compare/index.html` |

**Rust shows:** park greens (Herrfurthplatz circle), pink building footprints with soft SE drop-shadow (`#232323`, ~2.5 m / blur ~2.2 m / α≈0.28), soft tree crowns (α≈0.62 + darker under-disk), grey `highway_area` roads.  
**Pixelmatch:** **10.59%** (was **12.65%**). Band `bad` — expected during migration.

### Landuse pink note

On this tile, `landuse.class` values are greens (`park`, `grass`, `scrub`, …) plus `ground` / `kindergarten` / `sand` — **no** `residential`/`commercial`/`retail`. Large pink regions are **building** footprints (`#ffe9e9`, ~38% of tile area), not landuse. Palette now explicitly maps urban fabric classes to `#d8dacf` / `#dbdde1` and never uses building pink for landuse.

## Per-tile metrics (after shadows pass)

| Tile | Label | pixelmatch |
| --- | ---: | ---: |
| 15/17605/10752 | intersection parent z15 | 10.86% |
| 15/17606/10752 | density z15 | 6.15% |
| 16/35211/21505 | intersection z16 | 9.18% |
| 16/35212/21505 | density z16 | 10.77% |
| 17/70422/43011 | intersection z17 | 10.59% |
| 17/70425/43010 | density peak z17 | 11.78% |
| 18/140845/86023 | intersection z18 | 13.27% |
| 18/140851/86021 | density z18 | 12.16% |
| 19/281691/172046 | intersection z19 | 13.08% |
| 20/563382/344092 | intersection z20 | 12.57% |

Summary: `runs/full-approx-20260801-175611/compare/summary.json`  
Bands: 0 ok / 0 review / **10 bad** / 0 hard-fail (exit 0 under migration hard-fail >50%).

## What `full-approx` paints (bottom → top)

1. Background `#ededed`
2. `landuse` class fills (QGIS categorized greys/greens; urban → `#d8dacf`/`#dbdde1`; never `#ffe9e9`)
3. `pitch` `#d1d7c6` (if table exists)
4. `water_body_dissolved` `#cac7ed`
5. `waterway_clipped` line `#b2abe0` (width attr or 2 m)
6. path-like `highway` + `highway_service` lines
7. `highway_area` class fills (IN-list; no `parking_space`)
8. `building_shade` (faint), `building_parts_dissolved_height` (height order), `building` `#ffe9e9` + SE drop-shadow
9. `tree` crown `#6b8f4e` (α≈0.62 + soft under-disk), trunk `#8d8a63` if circumference present

## Remaining visual gaps (ranked)

1. **Labels (PAL)** — QGIS has street/place labels; Rust none (deferred by design).
2. **Richer effects** — innerShadow / outerGlow on forest, water shoreline; building shadow is a cheap approx only.
3. **RasterFill / surface textures** — asphalt, sett, grass patterns; viewport-anchored → also a seam risk.
4. **SvgMarker / furniture / markings** — road markings, bollards, pitch markings, etc.
5. **Landuse class fidelity** — family buckets approx; QGIS categorized map is richer + textures.
6. **Symbol levels / blend / opacity stacks** — 64×layer buckets, Multiply/Screen, non-default opacities.
7. **Water shoreline shapeburst** — flat purple fill only.

## Reproduce

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte

./audit/tile-regression/scripts/render-suite-full.sh

# Vite picks newest full-approx-*/rust by mtime (or set explicitly):
bun run --cwd vector dev
# RUST_TILES_ROOT=audit/tile-regression/runs/full-approx-20260801-175611/rust bun run --cwd vector dev
```

`highway_area` isolate mode remains: `srk-render --layers highway_area` + `scripts/render-suite.sh`.
