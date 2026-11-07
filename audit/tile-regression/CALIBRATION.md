# Harness calibration (highway_area isolate)

Measured **2026-08-01** on the starter bbox DB (`fixture-lock.json`), QGIS 4.0.2,
canonical flags `--metatile 1 --gutter 1 --workers 1 --format png`, pixelmatch
threshold `0.1` (same as `compare-one-tile` / smoke suite).

Goal: separate bit-identical QGIS reruns, tiny intentional knobs, and deliberate
content/background breaks so bands for **highway_area isolate** come from data.

## Setup

```bash
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte
source render/qgis_env.sh

TILES=17/70422/43008,17/70425/43010,16/35211/21505
./audit/tile-regression/scripts/render-qgis-tile.sh \
  --tiles "$TILES" --layers highway_area --dpi 96 --out /tmp/srk-cal-a
```

Compare with Bun + `pixelmatch` (ratio = mismatched / 65536).

## Measurements

### 1. QGIS vs QGIS identical rerun (sanity)

Same flags, same three tiles, two independent renders (`/tmp/srk-cal-a` vs `b`).

| Tile | Mismatched px | Pixelmatch |
| --- | ---: | ---: |
| `17/70422/43008` | 0 | **0%** |
| `17/70425/43010` | 0 | **0%** |
| `16/35211/21505` | 0 | **0%** |

**Band:** identical isolates are bit-exact under these flags. Any non-zero on a
true A/A rerun is a harness or I/O bug, not AA noise.

### 2. DPI 96 vs 97 (one tile)

`17/70422/43008`, `highway_area` isolate, only `--dpi` changed.

| Compare | Mismatched px | Pixelmatch |
| --- | ---: | ---: |
| dpi 96 vs 97 | 0 | **0%** |

**Note:** class fills on this layer are MapUnit / colour-driven SimpleFills with
outline width 0; a 1 DPI nudge does not move pixels here. DPI remains a useful
full-style / paper-unit probe later, but it is **not** a separator for this isolate.

### 3. Metatile 1 vs 8 (full style, prior measurement)

Documented in [`RENDER_MODE.md`](RENDER_MODE.md) (starter bbox, z15–17, 82 tiles,
`compare-tiles.py` SSIM — not pixelmatch):

| Metric | Value |
| --- | ---: |
| Mean SSIM | 0.9900 |
| Min SSIM | 0.8934 |
| Mean \|Δ\|>16 frac | 0.0029% |
| Dominant cause | Viewport-anchored RasterFill phase + sparse label/edge AA |

**Harness implication:** metatile packing is **not** pixel-equivalent for full
style. Isolates still use `--metatile 1`. Do not treat metatile-1-vs-8 drift as a
Rust failure.

### 4. Known-different content (highway_area vs landuse)

Same tile `17/70422/43008`, both isolates, dpi 96, default background `#ededed`.

| Compare | Mismatched px | Pixelmatch |
| --- | ---: | ---: |
| `highway_area` vs `landuse` | 17240 | **26.31%** |

### 5. Known-broken background

Same isolate + tile; only `--background` `#ededed` → `#ff0000`.

| Compare | Mismatched px | Pixelmatch |
| --- | ---: | ---: |
| bg default vs red | 60606 | **92.48%** |

### 6. `--no-fonts` (skipped this pass)

`highway_area` isolate has no labeling. Full-style `--no-fonts` vs fonts was
skipped to keep wall clock low (full style is minutes per tile set). Revisit when
calibrating label-on suites.

### 7. Context: QGIS vs Rust smoke (style-filter aligned)

From `runs/20260801-172219-smoke/` (`REPORT.md`): mean **0.079%**, max **0.203%**,
12/12 in soft `ok`. That is the current AA / missing RasterFill+effects residual
band for a “good enough” Rust slice — not a QGIS-vs-QGIS number, but it sits
comfortably under the `ok` ceiling below.

## Recommended bands — `highway_area` isolate

Soft bands in summary/gallery (migration mode). Hard fail still gates exit code.

| Band | Pixelmatch ratio | Confirmed by |
| --- | ---: | --- |
| **ok** | ≤ **1%** (≤0.01) | Identical = 0%; post-filter Rust smoke mean 0.079% / max 0.203% |
| **review** | ≤ **5%** (≤0.05) | Room for moderate symbology gaps without treating as wrong layer |
| **bad** | ≤ **50%** (≤0.50) | Layer swap landuse≈26% lands here |
| **hard-fail** (exit 1) | > **50%** | Background wipe ≈92%; geometry totally wrong |

**Verdict:** keep the existing smoke defaults (`ok≤1%`, `review≤5%`, `bad≤50%`,
hard-fail `>0.5`). They separate A/A and near-parity Rust from intentional
content/background breaks on this isolate. Do **not** tighten `ok` below ~0.5%
until RasterFill/effects are in scope — residual AA alone already approaches
0.2% on denser smoke tiles.

## What this does *not* calibrate

- Workers 1 vs 2 (single-tile mode forces workers=1)
- Full-style `--no-fonts` / label placement
- DPI sensitivity of paper-unit symbol layers
- Metatile packing for isolates (use RENDER_MODE.md for full style)

## Re-run checklist

1. Identical A/A on 2–3 smoke tiles → expect **0%**
2. Optional: dpi 96 vs 97 on `highway_area` → expect **~0%** today
3. Optional: isolate vs other layer or bg change → expect **bad** / **hard-fail**
4. Update this file if bands change
