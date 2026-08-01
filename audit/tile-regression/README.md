# Tile regression harness

Compare QGIS (reference) and Rust (candidate) XYZ tiles at the pixel level so a renderer migration can be judged tile-by-tile instead of by eye.

## Status

**Multi-tile smoke suite** is available for the `highway_area` isolate: committed `manifest.json` (12 tiles, z15–z18 inside the starter bbox) → QGIS + Rust batch render → `compare-run` dark HTML gallery. One-tile MVP (`compare-one-tile`) still works for ad-hoc checks.

Latest interim results: [`REPORT.md`](REPORT.md) (mean **0.079%** after style-filter alignment). Rules dump: [`HIGHWAY_AREA_RULES.md`](HIGHWAY_AREA_RULES.md). Gallery: `runs/20260801-172219-smoke/index.html`.

Still later: stratified `sample-tiles`, DSSIM/SSIMULACRA2 budgets, seam-check, full/standard suites.

**Anchor tile:** `17/70422/43008`

## Canonical render mode

Harness / single-tile compares use:

```text
--metatile 1 --gutter 1 --workers 1 --format png
```

Production keeps `--metatile 8 --gutter 1`. QGIS-vs-QGIS measurement on the starter bbox (z15–17) showed mean SSIM **0.990** but min SSIM **0.893** (FAIL vs `compare-tiles.py` thresholds) — mainly viewport-anchored fill texture phase, plus sparse label/edge AA. Details: [`RENDER_MODE.md`](RENDER_MODE.md).

`scripts/render-qgis-tile.sh` already defaults to the harness flags above.

## Setup

```bash
cd audit/tile-regression
bun install
chmod +x scripts/render-qgis-tile.sh scripts/render-suite.sh
```

Env (typical local Docker DB on 5433):

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte
# if missing:
# mkdir -p /tmp/srk-pgpass && printf 'localhost:5433:*:postgres:postgres\n' > /tmp/srk-pgpass/.pgpass && chmod 600 /tmp/srk-pgpass/.pgpass
```

## Smoke suite workflow (`highway_area` isolate)

End-to-end (preferred):

```bash
# from repo root
./audit/tile-regression/scripts/render-suite.sh
```

This:

1. Reads `manifest.json` tiles with `"suite": "smoke"`
2. Renders all tiles once with QGIS (`--layers highway_area`) → `/tmp/srk-smoke-ref`
3. Renders the same list with `srk-render` → `/tmp/srk-smoke-cand`
4. Runs `compare-run.ts` → `runs/<timestamp>-smoke/`

Outputs under `runs/<ts>-smoke/`:

| Artefact | Purpose |
| --- | --- |
| `index.html` | Dark gallery sorted by pixelmatch desc |
| `summary.json` | Counts, mean/max, per-zoom aggregates, worst tiles |
| `tiles.jsonl` | One metrics record per tile |
| `tiles/{z}/{x}/{y}/{ref,cand,diff}.png` | Per-tile images |

### Exit policy (migration mode)

- Soft bands in summary/gallery only: `ok` ≤1%, `review` ≤5%, `bad` ≤50%
- **Exit 1** only if any tile has pixelmatch ratio **> 0.5** (`--hard-fail`, default 0.5) or compare I/O fails (missing PNG, size mismatch)
- Otherwise exit **0** so the suite stays usable while Rust is incomplete

### Lon/lat → tile

```bash
cd audit/tile-regression
bun run scripts/lonlat-to-tile.ts --lon 13.4222 --lat 52.4768 --zooms 15,16,17,18
bun run scripts/lonlat-to-tile.ts --from-locations --zooms 15,16,17,18
```

Most `vector/locations.ts` compare points lie **outside** the starter bbox; only `intersection` is inside. Smoke tiles were filtered with PostGIS (`highway_area.geom` ∩ `ST_TileEnvelope`) inside `fixture-lock.json` bbox.

### Compare only (renders already done)

```bash
cd audit/tile-regression
bun run scripts/compare-run.ts \
  --manifest manifest.json \
  --suite smoke \
  --ref-dir /tmp/srk-smoke-ref \
  --cand-dir /tmp/srk-smoke-cand
```

Optional `--render` on `compare-run` invokes QGIS + Rust first; prefer `render-suite.sh` for clearer logs.

## One-tile workflow

```bash
./audit/tile-regression/scripts/render-qgis-tile.sh \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-ref

(cd rust/srk-render && cargo build --release)
./rust/srk-render/target/release/srk-render \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-cand \
  --format png

cd audit/tile-regression
bun run scripts/compare-one-tile.ts \
  --tiles 17/70422/43008 \
  --ref-dir /tmp/srk-one-tile-ref \
  --cand-dir /tmp/srk-one-tile-cand
```

Gallery + metrics land in `runs/<timestamp>/`. DSSIM is included when `dssim` is on `PATH`.

## Render helpers

```bash
./audit/tile-regression/scripts/render-qgis-tile.sh \
  --tiles 17/70422/43008,17/70422/43011 \
  --layers highway_area \
  --out /tmp/srk-smoke-ref
```

Defaults: `--format png --metatile 1 --gutter 1 --workers 1`. Extra args are forwarded to `render/xyz_tiles.py`.

## Fixture lock

See `fixture-lock.json` for the git SHA, DB connection, and starter bbox. A full `audit/sql-compare/` freeze is still pending.
