# Tile regression harness

Compare QGIS (reference) and Rust (candidate) XYZ tiles at the pixel level so a renderer migration can be judged tile-by-tile instead of by eye.

## Status

Phase 0 skeleton + Phase 1 single-tile render mode. The full harness (`sample-tiles`, `compare-tile`, `compare-run`, budgets, gallery) comes next.

## Render one tile (QGIS reference)

Use the deterministic `--tiles` mode on `render/xyz_tiles.py`. For single-tile compare runs, prefer `--metatile 1 --gutter 1` and PNG:

```bash
export PGPASSFILE=/tmp/srk-pgpass/.pgpass PGPASSWORD=postgres
export PGUSER=postgres DB_HOST=localhost DB_PORT=5433 DB_NAME=strassenraumkarte
source render/qgis_env.sh
python3 render/xyz_tiles.py \
  --project style/strassenraumkarte.qgz \
  --tiles 17/70422/43008 \
  --format png --metatile 1 --gutter 1 --workers 1 \
  --out /tmp/srk-one-tile-ref
```

Output: `/tmp/srk-one-tile-ref/17/70422/43008.png` (pick a tile inside the loaded PostGIS bbox — e.g. docker starter `13.4132,52.4715,13.4312,52.4821` — or the PNG will be blank background only).

`--tiles` can be repeated or comma-separated (`--tiles 17/70439/43023,17/70439/43024`). It forces `--workers 1`. Optional `--layers name1,name2` limits the paint list to those QGIS layer names (for isolates).

You can also pass `--tiles` / `--layers` through `render/render_tiles.sh` (skips `--bbox` / project-extent when `--tiles` is set).

## Fixture lock

See `fixture-lock.json` for the git SHA, DB connection, and starter bbox. A full `audit/sql-compare/` freeze is still pending.
