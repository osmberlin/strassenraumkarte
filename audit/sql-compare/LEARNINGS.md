# SQL optimization learnings (2026-08)

Bbox for SQL work: `13.3958,52.4243,13.4874,52.4849` (~80 s prep). Multi-hour
audits were **QGIS render**, not SQL — use `run-berlin.sh` / `--skip-render`.

Compare with [`audit/sql-compare/`](../sql-compare/README.md) (table digests).
Re-freeze `reference/` after intentional semantic/determinism fixes.

## Hot scripts (same bbox)

| Script | ~time | Notes |
| --- | ---: | --- |
| `building.sql` | ~34 s | Dominates prep |
| `road_marking_stop_lines.sql` | ~7 s | Next target |
| `road_marking_crossing.sql` | ~4 s | |
| `label_highway.sql` | ~4 s | |
| `road_marking_lane_divider.sql` | ~4 s | |
| `lanes_offset` / `lanes_connectivity` | ~2 s each | |

## `building.sql` — tried / landed

**Landed**

- **Deterministic height picks:** multi-outline `UPDATE … FROM` was arbitrary;
  fingerprints differed run-to-run with identical SQL. Fixed with `DISTINCT ON`
  (largest outline area, then `osm_id`) and `ROW_NUMBER … ORDER BY area, outline_id`.
- **Attribute join:** `ST_Overlaps OR ST_Within` → `&&` + `ST_Intersects` +
  `NOT ST_Touches` (same interior-intersection semantics; better GiST use).
  ~38 s → ~34 s on this bbox; digests match after determinism fix.

**Tried, rejected**

- `ST_UnaryUnion(ST_Collect(ST_Boundary(…)))` instead of `ST_Union(ST_Boundary(…))`:
  same polygonize *count* in a micro-test, but full pipeline drifted
  (`building_parts_dissolved_height` ±1). Do not use without a green compare.
- `ST_Contains(building, ST_PointOnSurface(part))` for the attribute join:
  ~8× faster on the join alone but **different** match set — fails equivalence.

## Process notes

- Always compare against a frozen reference; first prove **repro A == repro B**
  on unchanged SQL (we initially chased a false “opt broke digests”).
- Coarse `grid_m` in fingerprints absorbs float jitter; count drift is real.
