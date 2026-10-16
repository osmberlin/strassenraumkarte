-- node_highway_direction.sql — highway line attributes onto point features
--
-- For nodes that share a support point (vertex) with a highway line:
--   * feature_node (class = 'traffic_calming'): set direction when NULL
--   * barrier_node: set direction when NULL; set width from that highway when NULL
--
-- direction = whole degrees, drawn sense ST_StartPoint -> ST_EndPoint.
-- width = highway.width (includes lane defaults from import). If no highway
-- shares a vertex with the node, width stays NULL.
--
-- All highway.type values are used (paths included: cycle barriers typically
-- sit on cycleway/path). Existing numeric/cardinal OSM directions are left
-- unchanged. Nodes that only intersect a highway mid-segment (no shared
-- vertex) are ignored.
--
-- Several ways at one node: pick the highest-ranking highway (lowest
-- highway.hierarchy; e.g. residential before footway), then lowest osm_id
-- on a tie. Both direction and width come from that same way.
--
-- Depends on: highway (highway_preparation.sql), feature_node, barrier_node
--             helper/metres.sql

\i 'processing/sql/helper/metres.sql'

BEGIN;

DROP TABLE IF EXISTS _nhd_input;
CREATE TEMP TABLE _nhd_input AS
SELECT
    row_number() OVER () AS node_id,
    src,
    osm_id,
    geom,
    need_direction,
    need_width
FROM (
    SELECT
        'feature'::text AS src,
        osm_id,
        geom,
        TRUE AS need_direction,
        FALSE AS need_width
    FROM feature_node
    WHERE class = 'traffic_calming'
      AND direction IS NULL
      AND geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
    UNION ALL
    SELECT
        'barrier'::text,
        osm_id,
        geom,
        direction IS NULL AS need_direction,
        width IS NULL AS need_width
    FROM barrier_node
    WHERE (direction IS NULL OR width IS NULL)
      AND geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
) s;

CREATE INDEX _nhd_input_geom_idx ON _nhd_input USING GIST (geom);
CREATE INDEX _nhd_input_node_id_idx ON _nhd_input (node_id);
ANALYZE _nhd_input;

DROP TABLE IF EXISTS _nhd_result;
CREATE TEMP TABLE _nhd_result AS
WITH
highways_at_node AS (
    -- Highway must share a vertex with the node (Stützpunkt), not merely
    -- intersect mid-segment.
    SELECT
        inp.node_id,
        inp.geom AS node_geom,
        h.osm_id AS road_id,
        COALESCE(h.hierarchy, 999) AS hierarchy,
        h.width AS road_width,
        dumped.geom AS road_geom
    FROM _nhd_input inp
    JOIN highway h
      ON h.geom && inp.geom
     AND ST_Intersects(h.geom, inp.geom)
    CROSS JOIN LATERAL ST_Dump(h.geom) AS dumped
    WHERE dumped.geom IS NOT NULL
      AND NOT ST_IsEmpty(dumped.geom)
      AND ST_GeometryType(dumped.geom) = 'ST_LineString'
      AND ST_NPoints(dumped.geom) >= 2
      AND EXISTS (
          SELECT 1
          FROM generate_series(1, ST_NPoints(dumped.geom)) AS gs(i)
          WHERE ST_Equals(ST_PointN(dumped.geom, gs.i), inp.geom)
      )
),
-- One highway per node: highest rank (lowest hierarchy), then lowest osm_id.
chosen_highway AS (
    SELECT DISTINCT ON (node_id)
        node_id,
        node_geom,
        road_id,
        road_width,
        road_geom
    FROM highways_at_node
    ORDER BY node_id, hierarchy ASC, road_id ASC
),
chosen_with_azimuth AS (
    SELECT
        ch.node_id,
        ch.road_width AS width,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                ch.road_geom,
                GREATEST(0.0, loc.frac - loc.delta_frac)
            ),
            ST_LineInterpolatePoint(
                ch.road_geom,
                LEAST(1.0, loc.frac + loc.delta_frac)
            )
        ) AS azimuth
    FROM chosen_highway ch
    CROSS JOIN LATERAL (
        SELECT
            ST_LineLocatePoint(ch.road_geom, ch.node_geom) AS frac,
            LEAST(
                0.5,
                metres(0.3) / GREATEST(ST_Length(ch.road_geom), metres(0.3))
            ) AS delta_frac
    ) loc
)
SELECT
    inp.node_id,
    inp.src,
    inp.osm_id,
    inp.need_direction,
    inp.need_width,
    c.azimuth,
    c.width
FROM _nhd_input inp
JOIN chosen_with_azimuth c
  ON c.node_id = inp.node_id
WHERE c.azimuth IS NOT NULL
   OR c.width IS NOT NULL;

CREATE INDEX _nhd_result_src_osm_id_idx ON _nhd_result (src, osm_id);

UPDATE feature_node f
SET direction = ROUND(DEGREES(r.azimuth))
FROM _nhd_result r
WHERE r.src = 'feature'
  AND f.osm_id = r.osm_id
  AND f.class = 'traffic_calming'
  AND r.need_direction
  AND r.azimuth IS NOT NULL
  AND f.direction IS NULL;

UPDATE barrier_node b
SET
    direction = CASE
        WHEN r.need_direction AND r.azimuth IS NOT NULL
        THEN ROUND(DEGREES(r.azimuth))::integer
        ELSE b.direction
    END,
    width = CASE
        WHEN r.need_width AND r.width IS NOT NULL
        THEN r.width
        ELSE b.width
    END
FROM _nhd_result r
WHERE r.src = 'barrier'
  AND b.osm_id = r.osm_id
  AND (
      (r.need_direction AND r.azimuth IS NOT NULL AND b.direction IS NULL)
      OR (r.need_width AND r.width IS NOT NULL AND b.width IS NULL)
  );

DROP TABLE IF EXISTS _nhd_result;
DROP TABLE IF EXISTS _nhd_input;

COMMIT;
