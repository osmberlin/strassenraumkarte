# Rust tile renderer — evaluation report

**Date:** 2026-08-02  
**Scope:** Replace the QGIS raster XYZ step (PostGIS → tiles) with `rust/srk-render`, while MapLibre vector remains a parallel product channel.  
**Plan:** [`.cursor/plans/rust_tile_renderer_evaluation.plan.md`](../.cursor/plans/rust_tile_renderer_evaluation.plan.md)

## Recommendation

**Continue hybrid migration — do not stop, do not claim full QGIS replacement yet.**

| Criterion | Verdict |
| --- | --- |
| **Farm throughput (live WebP)** | **Go** — ~**20×** faster than production-shaped QGIS on the large Berlin bbox |
| **Codec / CDN size** | **Go** — WebP q90 ~12× smaller than PNG; default pipeline codec |
| **Visual parity (full style)** | **Not yet** — full-approx ~10% pixelmatch residual; labels, many SVG/effects, symbol levels still open |
| **Visual parity (`highway_area` isolate)** | **Strong** — smoke suite mean **0.08%** after rule alignment |

**Practical path:** use Rust for high-zoom raster farm capacity with WebP; keep QGIS (or accept known gaps) until label + remaining symbol work closes the visual budget. MapLibre vector stays independent.

---

## Speed (live farm)

Host: Darwin arm64, 10 CPUs · PostGIS `localhost:5433` · bbox `13.3958,52.4243,13.4874,52.4849` · z18–z20 · **102 225** tiles · 8 workers.

QGIS reference (full style, metatile 8, gutter 1, 2 workers, JPG): **1568 s**.

| Rust config | Format | Wall | vs QGIS |
| --- | --- | ---: | ---: |
| **mt1, gutter 0 (farm default)** | **webp q90** | **78.8 s** | **~20×** |
| mt4, gutter 1 | webp q90 | 93.0 s | ~17× |
| mt8, gutter 1 | webp q90 | 96.2 s | ~16× |
| Prior (workers + prep + early-out) | webp q90 | 82.5 s | ~19× |

Detail, profiles, and dead-ends: [`audit/tile-regression/SPEED_ITERATIONS.md`](../audit/tile-regression/SPEED_ITERATIONS.md).

**Metatile:** helps dense z18 (mt8+gutter1 ≈ 6 s vs ~25 s for mt1+gutter1). On sparse z20, per-tile empty early-out + mt1 wins. Default farm: `--metatile 1 --gutter 0`.

**Codecs** ([`WEBP_MIGRATION.md`](../audit/tile-regression/WEBP_MIGRATION.md), `bench-codecs`):

| Codec | Role | z18–z20 disk (approx) | Notes |
| --- | --- | ---: | --- |
| **webp q90** | **live default** | ~36 MiB | Cite for capacity |
| jpg q90 | QGIS-like | ~275 MiB | Encode via `image` crate too slow for farms |
| png | harness only | ~453 MiB | pixelmatch bit-stable |

---

## Visual parity

### `highway_area` isolate

Canonical mode: metatile 1, gutter 1, PNG ([`RENDER_MODE.md`](../audit/tile-regression/RENDER_MODE.md)).

| Suite | Mean pixelmatch | Max | Bands |
| --- | ---: | ---: | --- |
| Smoke 12 tiles z15–18 ([`REPORT.md`](../audit/tile-regression/REPORT.md)) | **0.079%** | 0.203% | 12 ok |

### Full-approx stack

Paint order (simplified): landuse → pitch (+ markings) → water → roads → buildings (drop-shadow) → trees → additional furniture/markings as implemented.

| Evidence | Result |
| --- | --- |
| Style-iterate Herrfurthplatz `17/70422/43011` | ~11.5% → **~9.8%** after textures/trees/buildings |
| Full-approx suite (10 tiles) | mean ~**11%** ([`FULL_STYLE_REPORT.md`](../audit/tile-regression/FULL_STYLE_REPORT.md)) |
| Gaps | Labels (PAL), many SvgMarkers, innerShadow/glow, symbol levels, blend modes, Qt vs Skia AA ([`STYLE_ITERATE_GAPS.md`](../audit/tile-regression/STYLE_ITERATE_GAPS.md)) |

Recent full-approx expansions (in tree): pitch SVG markings, sandpit, landscape ways, playground, road-marking nodes/ways, viewpoint stamps via `resvg`.

---

## What was built

| Area | Deliverable |
| --- | --- |
| Harness | `audit/tile-regression/` — sample, compare, galleries, budgets, calibration |
| QGIS tooling | `--tiles`, `--layers`, metatile/gutter single-tile mode |
| Style IR | `style/scripts/dump-style.py` → inventory / IR (generated, gitignored) |
| Rust crate | `rust/srk-render` — full-approx + highway_area isolate, WebP/JPG/PNG, workers, prepared SQL, empty early-out, metatile N, gutter |
| Perf docs | `SPEED_ITERATIONS.md`, `WEBP_MIGRATION.md`, `LARGE_BBOX_TIMING.md` |

**Tried and dropped:** multi-layer `UNION ALL` fetch (~2× SQL cost on local PostGIS).

---

## Honest gaps (block full go)

1. **Labels** — placement (PAL) not ported; compare label-free or keep QGIS labels.
2. **Symbol coverage** — MarkerLine/HashLine, full SvgMarker param substitution, many furniture icons incomplete.
3. **Effects** — innerShadow / glow / full shapeburst fidelity incomplete vs QGIS stacks.
4. **Draw order** — symbol levels + blend modes not fully matched.
5. **Seams** — farm default gutter 0; use `--gutter 1` (and optionally metatile) for bleed parity.

---

## How to reproduce

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export PGPASSWORD=postgres PGPASSFILE=/tmp/srk-pgpass/.pgpass

cd rust/srk-render && cargo build --release

# Live farm timing
./target/release/srk-render \
  --bbox 13.3958,52.4243,13.4874,52.4849 \
  --zmin 18 --zmax 20 --layers full-approx \
  --out /tmp/srk-farm --format webp --quality 90 \
  --metatile 1 --gutter 0 --workers 8 --quiet --timing-json --profile

# Parity-shaped (edge bleed)
./target/release/srk-render ... --metatile 8 --gutter 1 --format png

# Codec compare
./audit/tile-regression/scripts/bench-codecs.sh
```

---

## Verdict (one line)

**Rust is ready to own live WebP farm throughput (~20× QGIS); it is not yet a drop-in full-style visual replacement — continue hybrid until labels and remaining symbols close the ~10% full-approx gap.**
