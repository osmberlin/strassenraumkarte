# Tile regression harness

Compare QGIS (reference) and Rust (candidate) XYZ tiles at the pixel level so a renderer migration can be judged tile-by-tile instead of by eye.

## Status

One-tile MVP is available: render QGIS isolate → render Rust isolate → `compare-one-tile` gallery. Full suite sampling (`sample-tiles`, batch `compare-run`, budgets) comes later.

**Anchor tile (starter DB bbox):** `17/70422/43008`

## Setup

```bash
cd audit/tile-regression
bun install
chmod +x scripts/render-qgis-tile.sh
```

## One-tile workflow (`highway_area` isolate)

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte

# 1) QGIS reference (isolate)
./audit/tile-regression/scripts/render-qgis-tile.sh \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-ref

# 2) Rust candidate
(cd rust/srk-render && cargo build --release)
./rust/srk-render/target/release/srk-render \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-cand \
  --format png

# 3) Pixel diff gallery
cd audit/tile-regression
bun run scripts/compare-one-tile.ts \
  --tiles 17/70422/43008 \
  --ref-dir /tmp/srk-one-tile-ref \
  --cand-dir /tmp/srk-one-tile-cand
```

Gallery + metrics land in `runs/<timestamp>/` (`ref.png`, `cand.png`, `diff.png`, `metrics.json`, `index.html`). Open `index.html` in a browser. DSSIM is included when `dssim` is on `PATH`.

### Direct PNG paths

```bash
bun run scripts/compare-one-tile.ts \
  --ref /tmp/srk-one-tile-ref/17/70422/43008.png \
  --cand /tmp/srk-one-tile-cand/17/70422/43008.png
```

## Render one tile (QGIS only)

```bash
./audit/tile-regression/scripts/render-qgis-tile.sh \
  --tiles 17/70422/43008 \
  --layers highway_area \
  --out /tmp/srk-one-tile-ref
```

Defaults: `--format png --metatile 1 --gutter 1 --workers 1`. Extra args are forwarded to `render/xyz_tiles.py`.

`--tiles` can be repeated or comma-separated. Optional `--layers name1,name2` limits the paint list (isolates).

## Fixture lock

See `fixture-lock.json` for the git SHA, DB connection, and starter bbox. A full `audit/sql-compare/` freeze is still pending.
