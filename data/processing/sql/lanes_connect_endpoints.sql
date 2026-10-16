----------------------------------------------------------------------
-- lanes_connect_endpoints.sql
-- Snaps lane endpoints to their connected prev/next lane endpoints,
-- so that connected lanes share the same vertex at the junction.
-- Run after lanes_connectivity.sql.
--
-- Joins use segment_id (unique per highway fragment from
-- highway_preparation.sql). prev_osm_id / next_osm_id are kept for
-- downstream road-marking scripts.
--
-- Entry/Exit convention by direction:
--   forward / other:  entry = StartPoint (idx 0),   exit = EndPoint (last idx)
--   backward:         entry = EndPoint   (last idx), exit = StartPoint (idx 0)
----------------------------------------------------------------------

----------------------------------------------------------------------
-- 0) Lane flow counts + spread flags (dual_carriageway and Y-junctions)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _lane_flow_counts;
CREATE TEMP TABLE _lane_flow_counts AS
SELECT
    segment_id,
    (COUNT(*) FILTER (WHERE direction IN ('forward', 'both_ways')))::integer
        AS cnt_along_way,
    (COUNT(*) FILTER (WHERE direction IN ('backward', 'both_ways')))::integer
        AS cnt_against_way
FROM lanes
GROUP BY segment_id;

CREATE INDEX _lane_flow_counts_idx ON _lane_flow_counts (segment_id);

DROP TABLE IF EXISTS _snap_spread_ends;
CREATE TEMP TABLE _snap_spread_ends AS
SELECT
    h.segment_id,
    NOT ST_Equals(
        ST_StartPoint(h.geom),
        ST_StartPoint(ht.geom)
    ) AS start_spread,
    NOT ST_Equals(
        ST_EndPoint(h.geom),
        ST_EndPoint(ht.geom)
    ) AS end_spread
FROM highway h
JOIN highway_transformed ht ON h.segment_id = ht.segment_id
WHERE NOT ST_Equals(ST_StartPoint(h.geom), ST_StartPoint(ht.geom))
   OR NOT ST_Equals(ST_EndPoint(h.geom), ST_EndPoint(ht.geom));

CREATE INDEX _snap_spread_ends_idx ON _snap_spread_ends (segment_id);


----------------------------------------------------------------------
-- 1) Lane counts per physical travel direction on this highway segment
----------------------------------------------------------------------

ALTER TABLE lanes ADD COLUMN IF NOT EXISTS direction_lane_count integer;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS prev_lane_count integer;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS next_lane_count integer;

UPDATE lanes l
SET direction_lane_count = CASE
        WHEN l.direction = 'backward' THEN f.cnt_against_way
        ELSE f.cnt_along_way
    END
FROM _lane_flow_counts f
WHERE f.segment_id = l.segment_id;

UPDATE lanes SET prev_lane_count = NULL, next_lane_count = NULL;

UPDATE lanes l
SET prev_lane_count = CASE
    WHEN p.direction = 'backward' THEN pc.cnt_against_way
    ELSE pc.cnt_along_way
END
FROM lanes p
JOIN _lane_flow_counts pc ON pc.segment_id = p.segment_id
WHERE l.prev_segment_id IS NOT NULL
  AND p.segment_id = l.prev_segment_id
  AND p.lane_index = l.prev_lane_index;

UPDATE lanes l
SET next_lane_count = CASE
    WHEN n.direction = 'backward' THEN nc.cnt_against_way
    ELSE nc.cnt_along_way
END
FROM lanes n
JOIN _lane_flow_counts nc ON nc.segment_id = n.segment_id
WHERE l.next_segment_id IS NOT NULL
  AND n.segment_id = l.next_segment_id
  AND n.lane_index = l.next_lane_index;


----------------------------------------------------------------------
-- 2) Phase 1: Snap dual carriageway EXIT endpoints at spread ends
----------------------------------------------------------------------

DROP TABLE IF EXISTS _snap_dc_exit;
CREATE TEMP TABLE _snap_dc_exit AS
SELECT
    l.segment_id,
    l.lane_index,
    l.direction,
    CASE
        WHEN n.direction = 'backward' THEN ST_EndPoint(n.geom)
        ELSE ST_StartPoint(n.geom)
    END AS target_pt
FROM lanes l
JOIN _snap_spread_ends se ON se.segment_id = l.segment_id
JOIN lanes n
  ON  n.segment_id  = l.next_segment_id
 AND n.lane_index  = l.next_lane_index
WHERE l.next_segment_id IS NOT NULL
  AND (
      (l.direction <> 'backward' AND se.end_spread)
      OR
      (l.direction = 'backward' AND se.start_spread)
  );

UPDATE lanes l
SET geom = CASE
    WHEN l.direction = 'backward'
    THEN ST_SetPoint(l.geom, 0, d.target_pt)
    ELSE ST_SetPoint(l.geom, ST_NPoints(l.geom) - 1, d.target_pt)
END
FROM _snap_dc_exit d
WHERE l.segment_id = d.segment_id
  AND l.lane_index = d.lane_index;


----------------------------------------------------------------------
-- 3a) Phase 2a: Snap lane ENTRY to predecessor's EXIT when
--     flow lane count here <= predecessor.
----------------------------------------------------------------------

DROP TABLE IF EXISTS _snap_entry;
CREATE TEMP TABLE _snap_entry AS
SELECT
    l.segment_id,
    l.lane_index,
    l.direction,
    CASE
        WHEN p.direction = 'backward' THEN ST_StartPoint(p.geom)
        ELSE ST_EndPoint(p.geom)
    END AS target_pt
FROM lanes l
JOIN lanes p
  ON  p.segment_id  = l.prev_segment_id
 AND p.lane_index  = l.prev_lane_index
JOIN _lane_flow_counts fl ON fl.segment_id = l.segment_id
JOIN _lane_flow_counts fp ON fp.segment_id = p.segment_id
WHERE l.prev_segment_id IS NOT NULL
  AND (
      CASE WHEN l.direction = 'backward' THEN fl.cnt_against_way ELSE fl.cnt_along_way END
  ) <= (
      CASE WHEN p.direction = 'backward' THEN fp.cnt_against_way ELSE fp.cnt_along_way END
  );

UPDATE lanes l
SET geom = CASE
    WHEN l.direction = 'backward'
    THEN ST_SetPoint(l.geom, ST_NPoints(l.geom) - 1, e.target_pt)
    ELSE ST_SetPoint(l.geom, 0, e.target_pt)
END
FROM _snap_entry e
WHERE l.segment_id = e.segment_id
  AND l.lane_index = e.lane_index;


----------------------------------------------------------------------
-- 3b) Phase 2b: Fallback – predecessor's EXIT → successor's ENTRY
----------------------------------------------------------------------

DROP TABLE IF EXISTS _snap_exit_fallback;
CREATE TEMP TABLE _snap_exit_fallback AS
SELECT
    l.segment_id,
    l.lane_index,
    l.direction,
    CASE
        WHEN n.direction = 'backward' THEN ST_EndPoint(n.geom)
        ELSE ST_StartPoint(n.geom)
    END AS target_pt
FROM lanes l
JOIN lanes n
  ON  n.segment_id  = l.next_segment_id
 AND n.lane_index  = l.next_lane_index
WHERE l.next_segment_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM _snap_entry se
      WHERE se.segment_id = n.segment_id AND se.lane_index = n.lane_index
  );

UPDATE lanes l
SET geom = CASE
    WHEN l.direction = 'backward'
    THEN ST_SetPoint(l.geom, 0, f.target_pt)
    ELSE ST_SetPoint(l.geom, ST_NPoints(l.geom) - 1, f.target_pt)
END
FROM _snap_exit_fallback f
WHERE l.segment_id = f.segment_id
  AND l.lane_index = f.lane_index;


----------------------------------------------------------------------
-- 5) Cleanup
----------------------------------------------------------------------

DROP TABLE IF EXISTS _snap_spread_ends;
DROP TABLE IF EXISTS _snap_dc_exit;
DROP TABLE IF EXISTS _snap_entry;
DROP TABLE IF EXISTS _snap_exit_fallback;
DROP TABLE IF EXISTS _lane_flow_counts;
