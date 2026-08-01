# SQL before/after compare

Fingerprint PostGIS outputs after data prep, freeze a reference under gitignored
`reference/`, then compare candidates after SQL changes.

**BBox:** default `13.3958,52.4243,13.4874,52.4849` (~1–2 min SQL). Render was
the slow part in audits, not prep — `run-berlin.sh` already skips render.

```bash
# Freeze once
./audit/sql-compare/run-reference.sh

# After editing data/processing/sql/…
LABEL=after ./audit/sql-compare/rerun-compare.sh
# or one group:
LABEL=b1 ./audit/sql-compare/rerun-compare.sh --group building
```

Exit `0` = match, `1` = drift. Digests: row count + md5 of id/attrs/geom
(`tables.json`; `grid_m` snaps geoms). Re-freeze after fixing non-deterministic
SQL (e.g. tied outline picks).
