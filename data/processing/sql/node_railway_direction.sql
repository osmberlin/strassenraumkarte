-- node_railway_direction.sql — railway line azimuth onto railway nodes
--
-- For railway_node that share a vertex with a railway_way and have no
-- direction yet:
--   * direction = whole degrees, 0 = north, clockwise (ST_Azimuth), in the
--     sense ST_StartPoint -> ST_EndPoint of the chosen way.
--   * Several ways: lowest osm_id. Same 0.3 m window as node_highway_direction.
--
-- railway=buffer_stop, when the node is not itself a switch (3+ incident
-- rails): walk the track forward and backward along vertices, at most
-- railway_buffer_stop_end_walk_m (ground metres, along the rails).
--   * degree 1 at the arrived vertex: track end. Store it for that
--     direction (fore = local azimuth, back = opposite), with path length.
--   * degree 2: one continuation (a way split counts). Keep walking.
--   * degree 3+: switch. Abort that direction and do not store an end.
-- A buffer stop that already sits on a track end (degree 1) stores that
-- end at length 0. Two ends: the shorter path wins. Direction then points
-- away from the chosen end (end ahead -> local azimuth + 180). No end:
-- local azimuth unchanged.
--
-- Existing numeric/cardinal OSM directions are left unchanged. Nodes that
-- only intersect a railway mid-segment (no shared vertex) are ignored.
--
-- Depends on: railway_node, railway_way (osm_import.lua),
--             helper/metres.sql, params/params.sql

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/metres.sql'

BEGIN;

ALTER TABLE railway_node ADD COLUMN IF NOT EXISTS direction integer;

-- 1 mm grid so identical OSM vertices share a key after projection.
CREATE OR REPLACE FUNCTION pg_temp.rwd_vkey(g geometry)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT round(ST_X(g)::numeric, 3)::text || '|' || round(ST_Y(g)::numeric, 3)::text
$$;

DROP TABLE IF EXISTS _rwd_input;
CREATE TEMP TABLE _rwd_input AS
SELECT
    row_number() OVER () AS node_id,
    osm_type,
    osm_id,
    railway,
    geom,
    pg_temp.rwd_vkey(geom) AS vkey
FROM railway_node
WHERE direction IS NULL
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

CREATE INDEX _rwd_input_geom_idx ON _rwd_input USING GIST (geom);
CREATE INDEX _rwd_input_node_id_idx ON _rwd_input (node_id);
ANALYZE _rwd_input;

-- Undirected rail graph: one row per ordered pair of adjacent vertices.
DROP TABLE IF EXISTS _rwd_link;
CREATE TEMP TABLE _rwd_link AS
SELECT
    vkey,
    nkey,
    min(len) AS len,
    (array_agg(ngeom ORDER BY len))[1] AS ngeom
FROM (
    SELECT
        pg_temp.rwd_vkey(ST_PointN(dumped.geom, gs.i)) AS vkey,
        pg_temp.rwd_vkey(ST_PointN(dumped.geom, gs.i + 1)) AS nkey,
        ST_Distance(
            ST_PointN(dumped.geom, gs.i),
            ST_PointN(dumped.geom, gs.i + 1)
        ) AS len,
        ST_PointN(dumped.geom, gs.i + 1) AS ngeom
    FROM railway_way w
    CROSS JOIN LATERAL ST_Dump(w.geom) AS dumped
    CROSS JOIN LATERAL generate_series(1, ST_NPoints(dumped.geom) - 1) AS gs(i)
    WHERE dumped.geom IS NOT NULL
      AND NOT ST_IsEmpty(dumped.geom)
      AND ST_GeometryType(dumped.geom) = 'ST_LineString'
      AND ST_NPoints(dumped.geom) >= 2
    UNION ALL
    SELECT
        pg_temp.rwd_vkey(ST_PointN(dumped.geom, gs.i + 1)) AS vkey,
        pg_temp.rwd_vkey(ST_PointN(dumped.geom, gs.i)) AS nkey,
        ST_Distance(
            ST_PointN(dumped.geom, gs.i),
            ST_PointN(dumped.geom, gs.i + 1)
        ) AS len,
        ST_PointN(dumped.geom, gs.i) AS ngeom
    FROM railway_way w
    CROSS JOIN LATERAL ST_Dump(w.geom) AS dumped
    CROSS JOIN LATERAL generate_series(1, ST_NPoints(dumped.geom) - 1) AS gs(i)
    WHERE dumped.geom IS NOT NULL
      AND NOT ST_IsEmpty(dumped.geom)
      AND ST_GeometryType(dumped.geom) = 'ST_LineString'
      AND ST_NPoints(dumped.geom) >= 2
) e
WHERE vkey <> nkey
  AND len > 0
GROUP BY vkey, nkey;

CREATE INDEX _rwd_link_vkey_idx ON _rwd_link (vkey);
ANALYZE _rwd_link;

DROP TABLE IF EXISTS _rwd_deg;
CREATE TEMP TABLE _rwd_deg AS
SELECT vkey, count(*)::integer AS deg
FROM _rwd_link
GROUP BY vkey;

CREATE INDEX _rwd_deg_vkey_idx ON _rwd_deg (vkey);
ANALYZE _rwd_deg;

-- Local azimuth at the node, same window as node_highway_direction.sql.
DROP TABLE IF EXISTS _rwd_azimuth;
CREATE TEMP TABLE _rwd_azimuth AS
WITH
ways_at_node AS (
    SELECT
        inp.node_id,
        inp.osm_type,
        inp.osm_id,
        inp.railway,
        inp.geom AS node_geom,
        inp.vkey,
        w.osm_id AS way_id,
        dumped.geom AS way_geom
    FROM _rwd_input inp
    JOIN railway_way w
      ON w.geom && inp.geom
     AND ST_Intersects(w.geom, inp.geom)
    CROSS JOIN LATERAL ST_Dump(w.geom) AS dumped
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
chosen_way AS (
    SELECT DISTINCT ON (node_id)
        node_id,
        osm_type,
        osm_id,
        railway,
        node_geom,
        vkey,
        way_geom
    FROM ways_at_node
    ORDER BY node_id, way_id ASC
),
chosen_with_azimuth AS (
    SELECT
        ch.node_id,
        ch.osm_type,
        ch.osm_id,
        ch.railway,
        ch.node_geom,
        ch.vkey,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                ch.way_geom,
                GREATEST(0.0, loc.frac - loc.delta_frac)
            ),
            ST_LineInterpolatePoint(
                ch.way_geom,
                LEAST(1.0, loc.frac + loc.delta_frac)
            )
        ) AS azimuth
    FROM chosen_way ch
    CROSS JOIN LATERAL (
        SELECT
            ST_LineLocatePoint(ch.way_geom, ch.node_geom) AS frac,
            LEAST(
                0.5,
                metres(0.3) / GREATEST(ST_Length(ch.way_geom), metres(0.3))
            ) AS delta_frac
    ) loc
)
SELECT *
FROM chosen_with_azimuth
WHERE azimuth IS NOT NULL;

CREATE INDEX _rwd_azimuth_node_id_idx ON _rwd_azimuth (node_id);
ANALYZE _rwd_azimuth;

-- First step of each walk, plus a length-0 end when the buffer stop is the end.
DROP TABLE IF EXISTS _rwd_seed;
CREATE TEMP TABLE _rwd_seed AS
WITH
starts AS (
    SELECT
        az.node_id,
        az.azimuth,
        az.node_geom,
        az.vkey,
        COALESCE(d.deg, 0) AS deg,
        lnk.nkey,
        lnk.len,
        lnk.ngeom,
        ST_Azimuth(az.node_geom, lnk.ngeom) AS step_az
    FROM _rwd_azimuth az
    JOIN _rwd_deg d
      ON d.vkey = az.vkey
    JOIN _rwd_link lnk
      ON lnk.vkey = az.vkey
    WHERE az.railway = 'buffer_stop'
      AND d.deg IN (1, 2)
),
ranked AS (
    SELECT
        s.*,
        abs(
            mod((degrees(s.step_az - s.azimuth) + 540)::numeric, 360) - 180
        ) AS ang,
        row_number() OVER (
            PARTITION BY s.node_id
            ORDER BY
                abs(mod((degrees(s.step_az - s.azimuth) + 540)::numeric, 360) - 180),
                s.nkey
        ) AS rn
    FROM starts s
    WHERE s.step_az IS NOT NULL
)
SELECT
    node_id,
    CASE
        WHEN deg = 1 AND ang <= 90 THEN 'fore'
        WHEN deg = 1 THEN 'back'
        WHEN rn = 1 THEN 'fore'
        ELSE 'back'
    END AS dir,
    vkey AS start_key,
    vkey AS prev_key,
    nkey AS cur_key,
    len AS dist
FROM ranked
WHERE len <= metres(:'railway_buffer_stop_end_walk_m'::double precision);

DROP TABLE IF EXISTS _rwd_end_here;
CREATE TEMP TABLE _rwd_end_here AS
SELECT
    node_id,
    CASE WHEN ang <= 90 THEN 'back' ELSE 'fore' END AS dir,
    0::double precision AS dist
FROM (
    SELECT
        node_id,
        ang,
        row_number() OVER (PARTITION BY node_id ORDER BY ang, nkey) AS rn
    FROM (
        SELECT
            az.node_id,
            lnk.nkey,
            abs(
                mod((degrees(ST_Azimuth(az.node_geom, lnk.ngeom) - az.azimuth) + 540)::numeric, 360) - 180
            ) AS ang
        FROM _rwd_azimuth az
        JOIN _rwd_deg d
          ON d.vkey = az.vkey
         AND d.deg = 1
        JOIN _rwd_link lnk
          ON lnk.vkey = az.vkey
        WHERE az.railway = 'buffer_stop'
          AND ST_Azimuth(az.node_geom, lnk.ngeom) IS NOT NULL
    ) s
) ranked
WHERE rn = 1;

DROP TABLE IF EXISTS _rwd_walk;
CREATE TEMP TABLE _rwd_walk AS
WITH RECURSIVE walk AS (
    SELECT
        node_id,
        dir,
        start_key,
        prev_key,
        cur_key,
        dist,
        1 AS steps
    FROM _rwd_seed
    UNION ALL
    SELECT
        w.node_id,
        w.dir,
        w.start_key,
        w.cur_key AS prev_key,
        lnk.nkey AS cur_key,
        w.dist + lnk.len AS dist,
        w.steps + 1 AS steps
    FROM walk w
    JOIN _rwd_deg d
      ON d.vkey = w.cur_key
     AND d.deg = 2
    JOIN _rwd_link lnk
      ON lnk.vkey = w.cur_key
     AND lnk.nkey <> w.prev_key
     AND lnk.nkey <> w.start_key
    WHERE w.steps < 2000
      AND w.dist + lnk.len <= metres(:'railway_buffer_stop_end_walk_m'::double precision)
)
SELECT
    w.node_id,
    w.dir,
    w.dist
FROM walk w
JOIN _rwd_deg d
  ON d.vkey = w.cur_key
 AND d.deg = 1;

DROP TABLE IF EXISTS _rwd_chosen_end;
CREATE TEMP TABLE _rwd_chosen_end AS
SELECT DISTINCT ON (node_id)
    node_id,
    dir,
    dist
FROM (
    SELECT node_id, dir, dist FROM _rwd_walk
    UNION ALL
    SELECT node_id, dir, dist FROM _rwd_end_here
) ends
ORDER BY node_id, dist ASC, dir ASC;

UPDATE railway_node n
SET direction = (
    (
        ROUND(DEGREES(az.azimuth))::integer
        + CASE WHEN e.dir = 'fore' THEN 180 ELSE 0 END
    ) % 360
)
FROM _rwd_azimuth az
LEFT JOIN _rwd_chosen_end e
  ON e.node_id = az.node_id
WHERE n.osm_type = az.osm_type
  AND n.osm_id = az.osm_id
  AND n.direction IS NULL
  AND az.azimuth IS NOT NULL;

DROP TABLE IF EXISTS _rwd_chosen_end;
DROP TABLE IF EXISTS _rwd_walk;
DROP TABLE IF EXISTS _rwd_end_here;
DROP TABLE IF EXISTS _rwd_seed;
DROP TABLE IF EXISTS _rwd_azimuth;
DROP TABLE IF EXISTS _rwd_deg;
DROP TABLE IF EXISTS _rwd_link;
DROP TABLE IF EXISTS _rwd_input;
DROP FUNCTION IF EXISTS pg_temp.rwd_vkey(geometry);

COMMIT;
