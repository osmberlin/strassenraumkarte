# Tile regression harness

Compare QGIS (reference) and Rust (candidate) XYZ tiles at the pixel level so a renderer migration can be judged tile-by-tile instead of by eye.

## Status

**Full-style suite** (QGIS full project vs Rust `full-approx`): [`manifest-full.json`](manifest-full.json) · [`scripts/render-suite-full.sh`](scripts/render-suite-full.sh) · report [`FULL_STYLE_REPORT.md`](FULL_STYLE_REPORT.md). Latest run: `runs/full-approx-20260801-175611/` (mean pixelmatch ~**11.0%** after building drop-shadow + soft trees + landuse greys; prior ~12.7%).

**WebP output (production-shaped Rust tiles):** default `--format webp --quality 90`. Full-area size vs prior PNG: [`WEBP_MIGRATION.md`](WEBP_MIGRATION.md) (**826.3 → 78.4 MiB**, −90.5%). Harness compares still use PNG.

**Multi-tile smoke suite** remains for the `highway_area` isolate: committed `manifest.json` (12 tiles, z15–z18) → QGIS + Rust → `compare-run` gallery. Interim isolate results: [`REPORT.md`](REPORT.md) (mean **0.079%**). Rules dump: [`HIGHWAY_AREA_RULES.md`](HIGHWAY_AREA_RULES.md).

Still later: stratified `sample-tiles`, DSSIM/SSIMULACRA2 budgets, seam-check, standard suite expansion.

**Intersection check tile:** `17/70422/43011` (Herrfurthplatz-like)
**Isolate anchor:** `17/70422/43008`

## Full-style workflow (QGIS full vs Rust full-approx)

```bash
# from repo root
./audit/tile-regression/scripts/render-suite-full.sh
```

Writes `runs/full-approx-<ts>/{qgis,rust,compare}/` and symlinks `runs/latest-rust` → rust tiles.

Serve in the vector compare UI:

```bash
RUST_TILES_ROOT=audit/tile-regression/runs/latest-rust bun run --cwd vector dev
# or explicit:
# RUST_TILES_ROOT=audit/tile-regression/runs/full-approx-<ts>/rust bun run --cwd vector dev
```

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
chmod +x scripts/render-qgis-tile.sh scripts/render-suite.sh scripts/render-suite-full.sh scripts/bench-bbox.sh
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

**Bbox timing** (full-style only): large bbox z15–z20 → [`LARGE_BBOX_TIMING.md`](LARGE_BBOX_TIMING.md). Speed iterations (`--workers`, profile) → [`SPEED_ITERATIONS.md`](SPEED_ITERATIONS.md). Starter-bbox notes remain in [`TIMING.md`](TIMING.md) (ignore highway_area isolate rows when judging full-approx).

Wall-clock comparison on the starter bbox (278 tiles, z15–18):

```bash
./audit/tile-regression/scripts/bench-bbox.sh
# skip optional full-style QGIS re-run:
./audit/tile-regression/scripts/bench-bbox.sh --skip-full-style
```

Writes `runs/bench-<ts>/` with `tiles.txt`, per-engine PNGs, `timing.json`, and `summary.json`. Report: [`TIMING.md`](TIMING.md).

Rust bbox mode (without the script):

```bash
./rust/srk-render/target/release/srk-render \
  --bbox 13.4132,52.4715,13.4312,52.4821 \
  --zmin 15 --zmax 18 \
  --layers highway_area \
  --out /tmp/srk-bench-rust \
  --format png --quiet
```

## Fixture lock

See [`fixture-lock.json`](fixture-lock.json) for the git SHA, Docker PostGIS image, PBF checksum, and bbox.

- **Large-bbox SQL freeze:** `audit/sql-compare/reference/baseline.json` (+ `.meta.json`) — recorded under `sql_compare_freeze`.
- **Live harness DB pin:** `audit/sql-compare/reference/starter.json` — starter bbox digests; does **not** match baseline (different bbox). Re-snapshot with `audit/sql-compare/snapshot.py` after intentional data changes.

## Calibration

QGIS-vs-QGIS bands for the `highway_area` isolate: [`CALIBRATION.md`](CALIBRATION.md). Soft defaults remain `ok≤1%` / `review≤5%` / `bad≤50%` / hard-fail `>50%`.
