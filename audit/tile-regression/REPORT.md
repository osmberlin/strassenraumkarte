# Rust vs QGIS tile regression — interim report (`highway_area`)

**Date:** 2026-08-01  
**Layer isolate:** `highway_area` (SimpleFill class rules only)  
**Latest gallery:** [`runs/20260801-172219-smoke/index.html`](runs/20260801-172219-smoke/index.html) · [`summary.json`](runs/20260801-172219-smoke/summary.json)  
**Style rules:** [`HIGHWAY_AREA_RULES.md`](HIGHWAY_AREA_RULES.md)  
**Canonical mode:** [`RENDER_MODE.md`](RENDER_MODE.md) — `--metatile 1 --gutter 1 --workers 1 --format png`

This is an interim parity note for the Rust vertical slice. The full go/no-go lives in Phase 4 (`docs/rust-renderer-evaluation.md`); that file is stubbed and points here until more layers land.

## Method

| Side | Engine | Command shape |
| --- | --- | --- |
| ref | QGIS (`render/xyz_tiles.py`) | `--tiles … --layers highway_area --metatile 1 --gutter 1 --workers 1 --format png` |
| cand | `rust/srk-render` | `--tiles … --layers highway_area --format png` |
| compare | `scripts/compare-run.ts` | pixelmatch threshold 0.1; bands ok ≤1%, review ≤5%, bad ≤50% |

Both engines read the same PostGIS `highway_area` table (starter bbox fixture). No labels, no other map layers.

## Tile set

Smoke suite in [`manifest.json`](manifest.json): **12** tiles, z15–18, all inside the starter bbox, stratified by anchor / neighbor / density / intersection. See manifest `notes` for why most `vector/locations.ts` points were skipped (outside bbox).

## Before → after (style-filter iteration)

| Run | Mean pixelmatch | Max | Bands (ok/review/bad/hard-fail) |
| --- | ---: | ---: | --- |
| Before (`20260801-170307-smoke`) | **1.96%** | **8.85%** (`18/140851/86021`) | 5 / 6 / 1 / 0 |
| After (`20260801-172219-smoke`) | **0.079%** | **0.203%** (`15/17606/10752`) | **12 / 0 / 0 / 0** |

Anchor `17/70422/43008`: **0.096% → 0.006%** (still well under 1%).

### What changed in Rust

1. **SQL / paint filter** — only `area:highway` values that appear in QGIS class-fill rules (see rules doc). Dropped catch-all painting of `parking_space`, `traffic_island`, and other unlisted classes. Worst tile had ~2500 m² of those extras; after filter it paints 3 features and matches QGIS at 0.000%.
2. **Stroke** — QGIS SimpleFill uses outline width **0** (same colour as fill). Removed the experimental 0.5 px dark stroke.
3. **Palette** — unchanged hex values; already matched QGIS (`#e1e3bd`, `#d7d8c5`, `#cccccc`, `#bbbbb2`, `#a8a8a7`).

## Per-zoom (after)

| Zoom | n | Mean | Max |
| --- | ---: | ---: | ---: |
| 15 | 2 | 0.187% | 0.203% |
| 16 | 3 | 0.117% | 0.157% |
| 17 | 4 | 0.053% | 0.166% |
| 18 | 3 | 0.006% | 0.017% |

## Remaining gaps (expected)

- **RasterFill surface textures** (concrete / paving_stones / sett / asphalt) — not in Rust slice; QGIS still overlays them on matching `surface` features → residual AA/texture diffs, largest at z15 in this suite.
- **Effects** (innerShadow / dropShadow on textures; separate carriageway blur stack not named `highway_area`) — not ported.
- **Sidewalk / crossover data-defined colours** — present in QGIS symbols but columns `footway` / `path` / `service` are absent on `public.highway_area`, so they do not fire in either engine today.
- **Qt vs tiny-skia AA** — sub-percent rim differences remain on dense tiles.
- **Other layers** — out of scope for this isolate.

## How to re-run

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte
./audit/tile-regression/scripts/render-suite.sh
```
