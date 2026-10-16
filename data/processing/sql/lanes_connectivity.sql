-- Determines prev/next lane connectivity for each lane segment.
-- Run after lanes_offset.sql.
--
-- Uses highway (original, untransformed) for road network topology
-- (shared start/end nodes per segment_id) and the offset lanes table
-- for geometry-based distance checks.
--
-- dual_carriageway ↔ shared carriageway of the same street: width and
-- distance filters are relaxed (lane widths often jump at the split).
--
-- For each lane, determines:
--   prev_segment_id / prev_lane_index  – the preceding lane segment
--   next_segment_id / next_lane_index  – the following lane segment
--   prev_osm_id / next_osm_id          – OSM way id of the neighbour (for rendering)

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


----------------------------------------------------------------------
-- 0) Add connectivity columns to the lanes table
----------------------------------------------------------------------

ALTER TABLE lanes ADD COLUMN IF NOT EXISTS prev_osm_id bigint;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS prev_lane_index integer;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS next_osm_id bigint;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS next_lane_index integer;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS prev_segment_id bigint;
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS next_segment_id bigint;
-- Filled in lanes_connect_endpoints.sql: lane count in this lane's
-- physical travel direction along the OSM way (see that script).
ALTER TABLE lanes ADD COLUMN IF NOT EXISTS direction_lane_count integer;

UPDATE lanes SET
    prev_osm_id = NULL,
    prev_lane_index = NULL,
    next_osm_id = NULL,
    next_lane_index = NULL,
    prev_segment_id = NULL,
    next_segment_id = NULL;


----------------------------------------------------------------------
-- 1) Extract road endpoints and compute azimuths at each end
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_road_ep;
CREATE TEMP TABLE _conn_road_ep AS
SELECT
    segment_id,
    osm_id,
    name,
    highway,
    dual_carriageway,
    geom,
    ST_StartPoint(geom)  AS spt,
    ST_EndPoint(geom)    AS ept,
    ST_NPoints(geom)     AS npts,
    -- Azimuth at start: direction from first to second vertex
    ST_Azimuth(
        ST_StartPoint(geom),
        ST_PointN(geom, 2)
    ) AS az_start,
    -- Azimuth at end: direction from penultimate to last vertex
    ST_Azimuth(
        ST_PointN(geom, GREATEST(ST_NPoints(geom) - 1, 1)),
        ST_EndPoint(geom)
    ) AS az_end
FROM highway
WHERE ST_NPoints(geom) >= 2;

CREATE INDEX _conn_road_ep_spt_idx ON _conn_road_ep USING GIST (spt);
CREATE INDEX _conn_road_ep_ept_idx ON _conn_road_ep USING GIST (ept);
CREATE INDEX _conn_road_ep_segment_id_idx ON _conn_road_ep (segment_id);


----------------------------------------------------------------------
-- 2) Find connected road pairs (shared endpoints + azimuth filter)
--
-- Junction matching uses segment_id (not osm_id), so intra-OSM splits
-- at internal nodes are chained as well as cross-way connections.
--
-- Filter: cos(flow_a − flow_b) > cos(45°)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_junctions;
CREATE TEMP TABLE _conn_junctions AS

-- dual_carriageway ↔ shared (non-dual) carriageway of the same street:
-- at a split/merge the continuation is unique even when lane widths differ.
WITH pairs AS (
-- A.end = B.start  (geometries roughly co-directed)
SELECT
    a.segment_id AS segment_a,
    b.segment_id AS segment_b,
    a.osm_id     AS road_a,
    b.osm_id     AS road_b,
    'end'::text   AS a_end,
    'start'::text AS b_end,
    a.name AS name_a,
    b.name AS name_b,
    a.highway AS highway_a,
    b.highway AS highway_b,
    a.dual_carriageway AS dual_a,
    b.dual_carriageway AS dual_b
FROM _conn_road_ep a
JOIN _conn_road_ep b
  ON a.segment_id <> b.segment_id
 AND ST_Equals(a.ept, b.spt)
WHERE cos(a.az_end - b.az_start) > cos(radians(45))

UNION ALL

-- A.end = B.end  (geometries roughly anti-parallel)
SELECT a.segment_id, b.segment_id, a.osm_id, b.osm_id, 'end', 'end',
       a.name, b.name, a.highway, b.highway, a.dual_carriageway, b.dual_carriageway
FROM _conn_road_ep a
JOIN _conn_road_ep b
  ON a.segment_id <> b.segment_id
 AND ST_Equals(a.ept, b.ept)
WHERE cos(a.az_end - b.az_end - pi()) > cos(radians(45))

UNION ALL

-- A.start = B.start  (geometries roughly anti-parallel)
SELECT a.segment_id, b.segment_id, a.osm_id, b.osm_id, 'start', 'start',
       a.name, b.name, a.highway, b.highway, a.dual_carriageway, b.dual_carriageway
FROM _conn_road_ep a
JOIN _conn_road_ep b
  ON a.segment_id <> b.segment_id
 AND ST_Equals(a.spt, b.spt)
WHERE cos(a.az_start + pi() - b.az_start) > cos(radians(45))

UNION ALL

-- A.start = B.end  (geometries roughly co-directed)
SELECT a.segment_id, b.segment_id, a.osm_id, b.osm_id, 'start', 'end',
       a.name, b.name, a.highway, b.highway, a.dual_carriageway, b.dual_carriageway
FROM _conn_road_ep a
JOIN _conn_road_ep b
  ON a.segment_id <> b.segment_id
 AND ST_Equals(a.spt, b.ept)
WHERE cos(a.az_start - b.az_end) > cos(radians(45))
)
SELECT
    segment_a,
    segment_b,
    road_a,
    road_b,
    a_end,
    b_end,
    (
        name_a IS NOT DISTINCT FROM name_b
        AND highway_a IS NOT DISTINCT FROM highway_b
        AND (
            (dual_a = 'yes' AND dual_b IS DISTINCT FROM 'yes')
            OR
            (dual_b = 'yes' AND dual_a IS DISTINCT FROM 'yes')
        )
    ) AS dual_single
FROM pairs;

CREATE INDEX _conn_junctions_segment_a_idx ON _conn_junctions (segment_a);
CREATE INDEX _conn_junctions_segment_b_idx ON _conn_junctions (segment_b);


----------------------------------------------------------------------
-- 3) Prepare lane metadata
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_lane_info;
CREATE TEMP TABLE _conn_lane_info AS
SELECT
    segment_id,
    osm_id,
    lane_index,
    type,
    direction,
    width,
    turn,
    geom,
    -- Normalized type group: vehicle and bus are treated as one group
    CASE WHEN type IN ('vehicle', 'bus') THEN 'motor' ELSE type END AS type_group,
    COUNT(*) OVER (
        PARTITION BY segment_id,
                     CASE WHEN type IN ('vehicle', 'bus') THEN 'motor' ELSE type END,
                     direction
    ) AS lane_count,
    ST_StartPoint(geom) AS spt,
    ST_EndPoint(geom)   AS ept
FROM lanes;

CREATE INDEX _conn_lane_info_segment_idx ON _conn_lane_info (segment_id);

-- Turn values that restrict a lane's next-matching:
CREATE TEMP TABLE _conn_excluded_turns (turn_val text);
INSERT INTO _conn_excluded_turns VALUES
    ('left'), ('sharp_left'), ('merge_to_left'),
    ('right'), ('sharp_right'), ('merge_to_right'),
    ('left;right'), ('reverse');


----------------------------------------------------------------------
-- 4) Generate lane-level candidate pairs
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_candidates;
CREATE TEMP TABLE _conn_candidates AS
SELECT
    la.segment_id AS segment_id_a,
    la.osm_id     AS osm_id_a,
    la.lane_index AS lane_index_a,
    la.direction AS dir_a,
    la.type_group AS tg_a,
    la.width     AS width_a,
    la.turn      AS turn_a,
    lb.segment_id AS segment_id_b,
    lb.osm_id     AS osm_id_b,
    lb.lane_index AS lane_index_b,
    lb.direction AS dir_b,
    lb.type_group AS tg_b,
    lb.width     AS width_b,
    lb.turn      AS turn_b,
    j.segment_a,
    j.segment_b,
    j.a_end,
    j.b_end,
    j.dual_single,
    ST_Distance(
        CASE WHEN j.a_end = 'end' THEN la.ept ELSE la.spt END,
        CASE WHEN j.b_end = 'start' THEN lb.spt ELSE lb.ept END
    ) AS dist,
    CASE
        WHEN EXISTS (SELECT 1 FROM _conn_excluded_turns WHERE turn_val = la.turn)
        THEN 0
        ELSE 1
    END AS turn_priority,
    la.lane_count AS lane_count_a,
    lb.lane_count AS lane_count_b
FROM _conn_junctions j
JOIN _conn_lane_info la ON la.segment_id = j.segment_a
JOIN _conn_lane_info lb ON lb.segment_id = j.segment_b
WHERE
    (
        (EXISTS (SELECT 1 FROM _conn_excluded_turns WHERE turn_val = la.turn)
         AND la.turn = lb.turn)
        OR
        NOT EXISTS (SELECT 1 FROM _conn_excluded_turns WHERE turn_val = la.turn)
    )
    AND la.type_group = lb.type_group
    AND (
        (j.a_end = 'end' AND j.b_end = 'start'
            AND la.direction = 'forward' AND lb.direction = 'forward')
        OR (j.a_end = 'end' AND j.b_end = 'start'
            AND la.direction NOT IN ('forward', 'backward')
            AND la.direction = lb.direction)
        OR (j.a_end = 'end'   AND j.b_end = 'end'
            AND la.direction = 'forward' AND lb.direction = 'backward')
        OR (j.a_end = 'start' AND j.b_end = 'start'
            AND la.direction = 'backward' AND lb.direction = 'forward')
        OR (j.a_end = 'start' AND j.b_end = 'end'
            AND la.direction = 'backward' AND lb.direction = 'backward')
    )
    AND (
        j.dual_single
        OR abs(la.width - lb.width) <= :lanes_connectivity_max_width_diff
    )
    AND ST_Distance(
        CASE WHEN j.a_end = 'end' THEN la.ept ELSE la.spt END,
        CASE WHEN j.b_end = 'start' THEN lb.spt ELSE lb.ept END
    ) <= metres(
        CASE
            WHEN j.dual_single THEN :lanes_connectivity_max_dist_dual_single
            ELSE :lanes_connectivity_max_dist
        END
    );


----------------------------------------------------------------------
-- 5) Apply distance thresholds
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_valid;
CREATE TEMP TABLE _conn_valid AS
SELECT
    segment_id_a, lane_index_a,
    segment_id_b, lane_index_b,
    osm_id_a, osm_id_b,
    dist, turn_priority, dual_single
FROM _conn_candidates
WHERE
    dual_single
    OR dist <= metres(:lanes_connectivity_close_threshold)
    OR (dist > metres(:lanes_connectivity_close_threshold) AND lane_count_a = lane_count_b);


----------------------------------------------------------------------
-- 6) Greedy 1:1 matching (by distance, with turn priority)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_best_next;
CREATE TEMP TABLE _conn_best_next AS
SELECT DISTINCT ON (segment_id_a, lane_index_a)
    segment_id_a, lane_index_a,
    segment_id_b, lane_index_b,
    osm_id_a, osm_id_b,
    dist,
    turn_priority
FROM _conn_valid
ORDER BY segment_id_a, lane_index_a, dual_single DESC, dist;

DROP TABLE IF EXISTS _conn_final;
CREATE TEMP TABLE _conn_final AS
SELECT DISTINCT ON (segment_id_b, lane_index_b)
    segment_id_a, lane_index_a,
    segment_id_b, lane_index_b,
    osm_id_a, osm_id_b,
    dist,
    turn_priority
FROM _conn_best_next
ORDER BY segment_id_b, lane_index_b, turn_priority, dist;

INSERT INTO _conn_final (
    segment_id_a, lane_index_a,
    segment_id_b, lane_index_b,
    osm_id_a, osm_id_b,
    dist, turn_priority
)
SELECT DISTINCT ON (r.segment_id_a, r.lane_index_a)
    r.segment_id_a, r.lane_index_a,
    r.segment_id_b, r.lane_index_b,
    r.osm_id_a, r.osm_id_b,
    r.dist,
    r.turn_priority
FROM _conn_valid r
WHERE NOT EXISTS (
    SELECT 1 FROM _conn_final f
    WHERE f.segment_id_a = r.segment_id_a
      AND f.lane_index_a = r.lane_index_a
)
AND NOT EXISTS (
    SELECT 1 FROM _conn_final f
    WHERE f.segment_id_b = r.segment_id_b
      AND f.lane_index_b = r.lane_index_b
)
ORDER BY r.segment_id_a, r.lane_index_a, r.dist;


----------------------------------------------------------------------
-- 7) Write results back into the lanes table
----------------------------------------------------------------------

UPDATE lanes l
SET next_segment_id = f.segment_id_b,
    next_lane_index = f.lane_index_b,
    next_osm_id     = f.osm_id_b
FROM _conn_final f
WHERE l.segment_id = f.segment_id_a
  AND l.lane_index = f.lane_index_a;

UPDATE lanes l
SET prev_segment_id = f.segment_id_a,
    prev_lane_index = f.lane_index_a,
    prev_osm_id     = f.osm_id_a
FROM _conn_final f
WHERE l.segment_id = f.segment_id_b
  AND l.lane_index = f.lane_index_b;


----------------------------------------------------------------------
-- 8) Cleanup temporary tables
----------------------------------------------------------------------

DROP TABLE IF EXISTS _conn_road_ep;
DROP TABLE IF EXISTS _conn_junctions;
DROP TABLE IF EXISTS _conn_lane_info;
DROP TABLE IF EXISTS _conn_excluded_turns;
DROP TABLE IF EXISTS _conn_candidates;
DROP TABLE IF EXISTS _conn_valid;
DROP TABLE IF EXISTS _conn_best_next;
DROP TABLE IF EXISTS _conn_final;
