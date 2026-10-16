# Canonical comparison render mode

Decision for the tile-regression harness: which QGIS metatile settings produce a
stable reference for single-tile pixel compares (vs production `--metatile 8`).

## Measurement (2026-08-01)

QGIS-vs-QGIS drift on the starter bbox, same host / DB / project / fonts:

| | Mode A (harness candidate) | Mode B (production-like) |
| --- | --- | --- |
| Flags | `--metatile 1 --gutter 1 --workers 1 --format png` | `--metatile 8 --gutter 1 --workers 1 --format png` |
| Bbox | `13.4132,52.4715,13.4312,52.4821` | same |
| Zooms | z15–z17 (82 tiles; z18 skipped as optional) | same |
| Metatile jobs | 82 | 4 |
| Wall clock | **10m 02s** | **1m 17s** |

Compared with `audit/tile-compare/compare-tiles.py` (default thresholds:
mean SSIM ≥ 0.98, min SSIM ≥ 0.95, mean \|Δ\|>16 frac ≤ 2%).

### Aggregate metrics

| Metric | Value |
| --- | ---: |
| Tiles compared | 82 / 82 |
| Mean SSIM | **0.9900** |
| Min SSIM | **0.8934** |
| Median SSIM | 0.9999 |
| P05 SSIM | 0.9257 |
| Mean \|Δ\|>16 frac | **0.0029%** |
| Mean \|Δ\|>1 frac | 16.3% |
| Identical tiles | 4 / 82 |
| Tiles with SSIM &lt; 0.95 | 7 |
| Tiles with SSIM &lt; 0.98 | 12 |
| `compare-tiles.py` verdict | **FAIL** (min SSIM) |

### Per zoom

| Zoom | n | Mean SSIM | Min SSIM | Mean \|Δ\|>1 | Mean \|Δ\|>16 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 15 | 6 | 0.9943 | 0.9722 | 9.1% | 0% |
| 16 | 20 | 0.9869 | 0.8934 | 15.8% | ~0% |
| 17 | 56 | 0.9906 | 0.8980 | 17.2% | 0.004% |

### Worst tiles (by SSIM)

| Tile | SSIM | \|Δ\|>1 | max \|Δ\| |
| --- | ---: | ---: | ---: |
| `16/35209/21507` | 0.8934 | 76.3% | 14 |
| `16/35209/21506` | 0.8978 | 73.0% | 14 |
| `17/70419/43013` | 0.8980 | 75.5% | 14 |
| `17/70419/43012` | 0.9240 | 59.9% | 16 |
| `17/70419/43014` | 0.9251 | 67.1% | 13 |

### Qualitative (labels / edges / fills)

Side-by-side + 8× amplified diffs on the worst tiles:

- **Dominant drift is viewport-anchored fill texture**, not missing geometry.
  Park / landuse RasterFill (and similar mottled greens) shifts phase when the
  render extent changes with metatile packing. That yields dense low-amplitude
  noise (often max \|Δ\| ≤ 14) over large areas — enough to tank SSIM while
  staying under the \|Δ\|>16 threshold.
- **Roads, building footprints, and solid fills** largely match (black in the
  amplified diff).
- **Labels / edges:** sparse high-diff pixels exist (tens per tile, sometimes on
  the outer 8 px band), consistent with PAL placement / AA depending on a larger
  metatile+gutter context. They are secondary to the texture phase issue on this
  bbox; they still matter for future label-on compares.
- Eye-check: left/right tiles look “the same map”; the diff panel is what makes
  the metatile contamination obvious.

Artefacts (local, not committed): `/tmp/srk-metatile-compare/{metatile1,metatile8,report,worst-diffs}/`.

## Recommendation

**Canonical harness mode: `--metatile 1 --gutter 1 --workers 1 --format png`.**

Reasons:

1. Metatile 1 vs 8 is **not pixel-equivalent** for QGIS-vs-QGIS: mean SSIM still
   passes 0.98, but min SSIM drops to **0.89** and ~15% of tiles fall below 0.98.
   Using production metatile packing as the reference would contaminate every
   later Rust (or isolate) diff with metatile geometry / pattern phase / label
   context.
2. Single-tile and `--tiles` workflows already force workers=1 and prefer
   metatile=1; keeping the harness on the same flags avoids two “truths”.
3. Production can (and should) keep `--metatile 8 --gutter 1` for throughput
   (~8× faster on this bbox). Do **not** change production defaults for this
   decision — only the compare harness.

### Re-run

```bash
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte
BBOX=13.4132,52.4715,13.4312,52.4821

./render/render_tiles.sh --bbox "$BBOX" --zmin 15 --zmax 17 \
  --metatile 1 --gutter 1 --workers 1 --format png \
  --out /tmp/srk-metatile-compare/metatile1

./render/render_tiles.sh --bbox "$BBOX" --zmin 15 --zmax 17 \
  --metatile 8 --gutter 1 --workers 1 --format png \
  --out /tmp/srk-metatile-compare/metatile8

./audit/tile-compare/setup.sh   # once
./audit/tile-compare/.venv/bin/python ./audit/tile-compare/compare-tiles.py \
  /tmp/srk-metatile-compare/metatile1 \
  /tmp/srk-metatile-compare/metatile8 \
  --out /tmp/srk-metatile-compare/report
```
