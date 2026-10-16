-- oneway.sql — one-way carrier lines with junction punch-outs for direction arrows
--
-- One-way highway centreline segments are merged into corridors (same class + name +
-- layer) so consecutive OSM pieces of one street do not get holes. Junction masks are
-- 11 m buffers around corridor endpoints and crossings between different corridor
-- pieces (one-ways only). Traffic roads are cut only at junctions among themselves;
-- other one-ways are cut at every one-way junction. Mapped area:highway junction /
-- crossing polygons of the same layer are subtracted as well.
-- Output geometries point in driving direction (oneway=-1 is reversed). oneway is
-- dropped; oneway:bicycle is remapped relative to that direction.
--
-- Excluded from the carrier lines: dual_carriageway=yes, type=motorway
-- (motorway, motorway_link, trunk, trunk_link, …), real tunnels (tunnel set
-- and not no/none/building_passage), and ways whose turn:lanes value is
-- anything other than no, none or unset. turn:lanes is not stored on highway;
-- lanes.turn holds the per-lane value (no/none kept, any other value drops
-- the segment).
--
-- Depends on: highway (highway_preparation.sql), highway_area (highway_area_merge.sql),
--             lanes (turn, segment_id; after lanes_split.sql)
-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) One-way source segments
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _ow_src AS
SELECT
    row_number() OVER () AS seg_id,
    h.osm_id,
    h.highway,
    h.type,
    h.class,
    h.name,
    CASE
        WHEN h.oneway IN ('yes', '1', 'true') THEN 'yes'
        WHEN h.oneway = '-1' THEN '-1'
    END AS oneway,
    CASE
        WHEN h."oneway:bicycle" IN ('yes', '1', 'true') THEN 'yes'
        WHEN h."oneway:bicycle" = '-1' THEN '-1'
        WHEN h."oneway:bicycle" = 'no' THEN 'no'
        ELSE h."oneway:bicycle"
    END AS oneway_bicycle,
    h.dual_carriageway,
    h.width,
    h.layer,
    h.hierarchy,
    h.highway IN (
        'primary', 'secondary', 'tertiary',
        'residential', 'unclassified', 'living_street', 'pedestrian', 'road'
    ) AS is_traffic,
    dumped.geom,
    ST_SnapToGrid(ST_StartPoint(dumped.geom), metres(0.5)) AS a,
    ST_SnapToGrid(ST_EndPoint(dumped.geom), metres(0.5)) AS b,
    ST_Length(dumped.geom) AS len
FROM highway h
CROSS JOIN LATERAL ST_Dump(h.geom) AS dumped(path, geom)
WHERE h.oneway IN ('yes', '1', 'true', '-1')
  AND h.geom IS NOT NULL
  AND NOT ST_IsEmpty(h.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND h.dual_carriageway IS DISTINCT FROM 'yes'
  AND h.type IS DISTINCT FROM 'motorway'
  AND (
        h.tunnel IS NULL
     OR h.tunnel IN ('no', 'none', 'building_passage')
  )
  AND NOT EXISTS (
      SELECT 1
      FROM lanes l
      WHERE l.segment_id = h.segment_id
        AND l.turn IS NOT NULL
        AND l.turn NOT IN ('no', 'none')
  );

CREATE INDEX _ow_src_seg_id_idx ON _ow_src (seg_id);
CREATE INDEX _ow_src_a_idx ON _ow_src (a);
CREATE INDEX _ow_src_b_idx ON _ow_src (b);
CREATE INDEX _ow_src_geom_idx ON _ow_src USING GIST (geom);

ANALYZE _ow_src;

-- ---------------------------------------------------------------------------
-- 2) Corridors for junction detection (highway + name + layer; unnamed: osm_id)
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _ow_corr_links AS
SELECT
    a.seg_id AS n1,
    b.seg_id AS n2
FROM _ow_src a
JOIN _ow_src b
  ON a.seg_id < b.seg_id
 AND a.highway = b.highway
 AND a.name IS NOT DISTINCT FROM b.name
 AND COALESCE(a.layer, 0) = COALESCE(b.layer, 0)
 AND (a.name IS NOT NULL OR a.osm_id = b.osm_id)
 AND (a.a = b.a OR a.a = b.b OR a.b = b.a OR a.b = b.b);

CREATE TEMP TABLE _ow_corr_ids AS
WITH RECURSIVE
adj AS (
    SELECT n1, n2 FROM _ow_corr_links
    UNION ALL
    SELECT n2, n1 FROM _ow_corr_links
),
reach AS (
    SELECT seg_id AS node, seg_id AS root
    FROM _ow_src
    UNION
    SELECT a.n2, r.root
    FROM reach r
    JOIN adj a ON a.n1 = r.node
)
SELECT
    node AS seg_id,
    MIN(root) AS corridor_id
FROM reach
GROUP BY node;

CREATE INDEX _ow_corr_ids_seg_id_idx ON _ow_corr_ids (seg_id);
CREATE INDEX _ow_corr_ids_corridor_id_idx ON _ow_corr_ids (corridor_id);

ANALYZE _ow_corr_ids;

-- Dissolved corridor pieces (LineMerge + dump). Direction is irrelevant here.
CREATE TEMP TABLE _ow_corr_lines AS
SELECT
    row_number() OVER () AS line_id,
    c.corridor_id,
    c.highway,
    c.layer,
    c.is_traffic,
    dumped.geom,
    ST_StartPoint(dumped.geom) AS a,
    ST_EndPoint(dumped.geom) AS b
FROM (
    SELECT
        i.corridor_id,
        MIN(s.highway) AS highway,
        MIN(s.layer) AS layer,
        bool_and(s.is_traffic) AS is_traffic,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(s.geom))) AS geom
    FROM _ow_src s
    JOIN _ow_corr_ids i ON i.seg_id = s.seg_id
    GROUP BY i.corridor_id
) c
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(c.geom, 2)) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString';

CREATE INDEX _ow_corr_lines_geom_idx ON _ow_corr_lines USING GIST (geom);
CREATE INDEX _ow_corr_lines_line_id_idx ON _ow_corr_lines (line_id);

ANALYZE _ow_corr_lines;

-- ---------------------------------------------------------------------------
-- 3) Junction points: crossings between pieces + start/end vertices
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _ow_junc_pts_all AS
WITH crossings AS (
    SELECT
        COALESCE(a.layer, 0) AS layer,
        (ST_Dump(ST_CollectionExtract(ST_Intersection(a.geom, b.geom), 1))).geom AS geom
    FROM _ow_corr_lines a
    JOIN _ow_corr_lines b
      ON a.line_id < b.line_id
     AND COALESCE(a.layer, 0) = COALESCE(b.layer, 0)
     AND a.geom && b.geom
     AND ST_Intersects(a.geom, b.geom)
),
ends AS (
    SELECT COALESCE(layer, 0) AS layer, a AS geom FROM _ow_corr_lines
    UNION ALL
    SELECT COALESCE(layer, 0), b FROM _ow_corr_lines
)
SELECT DISTINCT ON (layer, ST_SnapToGrid(geom, metres(0.5)))
    layer,
    ST_SnapToGrid(geom, metres(0.5)) AS geom
FROM (
    SELECT layer, geom FROM crossings WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
    UNION ALL
    SELECT layer, geom FROM ends WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
) u
WHERE ST_GeometryType(geom) = 'ST_Point'
ORDER BY layer, ST_SnapToGrid(geom, metres(0.5));

CREATE TEMP TABLE _ow_junc_pts_road AS
WITH road_lines AS (
    SELECT * FROM _ow_corr_lines WHERE is_traffic
),
crossings AS (
    SELECT
        COALESCE(a.layer, 0) AS layer,
        (ST_Dump(ST_CollectionExtract(ST_Intersection(a.geom, b.geom), 1))).geom AS geom
    FROM road_lines a
    JOIN road_lines b
      ON a.line_id < b.line_id
     AND COALESCE(a.layer, 0) = COALESCE(b.layer, 0)
     AND a.geom && b.geom
     AND ST_Intersects(a.geom, b.geom)
),
ends AS (
    SELECT COALESCE(layer, 0) AS layer, a AS geom FROM road_lines
    UNION ALL
    SELECT COALESCE(layer, 0), b FROM road_lines
)
SELECT DISTINCT ON (layer, ST_SnapToGrid(geom, metres(0.5)))
    layer,
    ST_SnapToGrid(geom, metres(0.5)) AS geom
FROM (
    SELECT layer, geom FROM crossings WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
    UNION ALL
    SELECT layer, geom FROM ends WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
) u
WHERE ST_GeometryType(geom) = 'ST_Point'
ORDER BY layer, ST_SnapToGrid(geom, metres(0.5));

CREATE TEMP TABLE _ow_buf_all AS
SELECT
    layer,
    ST_Buffer(geom, metres(:'oneway_junction_buffer_m'::numeric), 'quad_segs=8') AS geom
FROM _ow_junc_pts_all;

CREATE TEMP TABLE _ow_buf_road AS
SELECT
    layer,
    ST_Buffer(geom, metres(:'oneway_junction_buffer_m'::numeric), 'quad_segs=8') AS geom
FROM _ow_junc_pts_road;

CREATE INDEX _ow_buf_all_geom_idx ON _ow_buf_all USING GIST (geom);
CREATE INDEX _ow_buf_road_geom_idx ON _ow_buf_road USING GIST (geom);

ANALYZE _ow_buf_all;
ANALYZE _ow_buf_road;

-- Mapped OSM junction / crossing polygons (same layer semantics as buffers)
CREATE TEMP TABLE _ow_area_junc AS
SELECT
    COALESCE(layer, 0) AS layer,
    geom
FROM highway_area
WHERE source = 'osm_feature'
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND (
        (type = 'junction' AND class IS NULL)
     OR (type = 'crossing' AND class IN ('traffic_signals', 'marked', 'zebra'))
  );

CREATE INDEX _ow_area_junc_geom_idx ON _ow_area_junc USING GIST (geom);

ANALYZE _ow_area_junc;

-- ---------------------------------------------------------------------------
-- 4) Output chains (finer key: oneway, oneway:bicycle, dual_carriageway)
--    Merge in OSM digitising direction (end of A to start of B).
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _ow_out_links AS
SELECT
    a.seg_id AS src,
    b.seg_id AS dst
FROM _ow_src a
JOIN _ow_src b
  ON a.seg_id <> b.seg_id
 AND a.highway = b.highway
 AND a.name IS NOT DISTINCT FROM b.name
 AND COALESCE(a.layer, 0) = COALESCE(b.layer, 0)
 AND a.oneway IS NOT DISTINCT FROM b.oneway
 AND a.oneway_bicycle IS NOT DISTINCT FROM b.oneway_bicycle
 AND a.dual_carriageway IS NOT DISTINCT FROM b.dual_carriageway
 AND (a.name IS NOT NULL OR a.osm_id = b.osm_id)
 AND a.b = b.a;

CREATE TEMP TABLE _ow_out_next AS
WITH n_succ AS (
    SELECT src, count(*) AS n FROM _ow_out_links GROUP BY src
),
n_pred AS (
    SELECT dst, count(*) AS n FROM _ow_out_links GROUP BY dst
)
SELECT
    l.src,
    l.dst
FROM _ow_out_links l
JOIN n_succ s ON s.src = l.src AND s.n = 1
JOIN n_pred p ON p.dst = l.dst AND p.n = 1;

CREATE INDEX _ow_out_next_src_idx ON _ow_out_next (src);
CREATE INDEX _ow_out_next_dst_idx ON _ow_out_next (dst);

CREATE TEMP TABLE _ow_out_comp AS
WITH RECURSIVE
adj AS (
    SELECT src AS n1, dst AS n2 FROM _ow_out_next
    UNION ALL
    SELECT dst, src FROM _ow_out_next
),
reach AS (
    SELECT seg_id AS node, seg_id AS root
    FROM _ow_src
    UNION
    SELECT a.n2, r.root
    FROM reach r
    JOIN adj a ON a.n1 = r.node
)
SELECT
    node AS seg_id,
    MIN(root) AS chain_id
FROM reach
GROUP BY node;

CREATE INDEX _ow_out_comp_seg_id_idx ON _ow_out_comp (seg_id);

CREATE TEMP TABLE _ow_out_start AS
SELECT
    c.chain_id,
    COALESCE(
        MIN(s.seg_id) FILTER (
            WHERE NOT EXISTS (
                SELECT 1 FROM _ow_out_next n WHERE n.dst = s.seg_id
            )
        ),
        MIN(s.seg_id)
    ) AS start_id
FROM _ow_src s
JOIN _ow_out_comp c ON c.seg_id = s.seg_id
GROUP BY c.chain_id;

CREATE TEMP TABLE _ow_out_walk AS
WITH RECURSIVE walk AS (
    SELECT
        st.chain_id,
        st.start_id,
        st.start_id AS seg_id,
        1 AS ord
    FROM _ow_out_start st
    UNION ALL
    SELECT
        w.chain_id,
        w.start_id,
        n.dst,
        w.ord + 1
    FROM walk w
    JOIN _ow_out_next n ON n.src = w.seg_id
    WHERE n.dst IS DISTINCT FROM w.start_id
)
SELECT * FROM walk;

CREATE INDEX _ow_out_walk_chain_idx ON _ow_out_walk (chain_id, ord);

CREATE TEMP TABLE _ow_out_merged AS
SELECT
    row_number() OVER () AS line_id,
    m.highway,
    m.type,
    m.class,
    m.name,
    m.oneway,
    m.oneway_bicycle,
    m.dual_carriageway,
    m.width,
    m.layer,
    m.hierarchy,
    m.is_traffic,
    dumped.geom
FROM (
    SELECT
        w.chain_id,
        (ARRAY_AGG(s.highway ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS highway,
        (ARRAY_AGG(s.type ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS type,
        (ARRAY_AGG(s.class ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS class,
        (ARRAY_AGG(s.name ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS name,
        (ARRAY_AGG(s.oneway ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS oneway,
        (ARRAY_AGG(s.oneway_bicycle ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS oneway_bicycle,
        (ARRAY_AGG(s.dual_carriageway ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS dual_carriageway,
        (ARRAY_AGG(s.width ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS width,
        (ARRAY_AGG(s.layer ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS layer,
        (ARRAY_AGG(s.hierarchy ORDER BY s.len DESC NULLS LAST, s.seg_id))[1] AS hierarchy,
        bool_or(s.is_traffic) AS is_traffic,
        CASE
            WHEN count(*) = 1 THEN (ARRAY_AGG(s.geom ORDER BY w.ord))[1]
            ELSE ST_MakeLine(ARRAY_AGG(s.geom ORDER BY w.ord))
        END AS geom
    FROM _ow_out_walk w
    JOIN _ow_src s ON s.seg_id = w.seg_id
    GROUP BY w.chain_id
) m
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(m.geom, 2)) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString';

CREATE INDEX _ow_out_merged_geom_idx ON _ow_out_merged USING GIST (geom);

ANALYZE _ow_out_merged;

-- ---------------------------------------------------------------------------
-- 5) Punch out junction buffers, then OSM junction / crossing polygons
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _ow_clipped AS
WITH buf_diff AS (
    SELECT
        m.line_id,
        m.highway,
        m.type,
        m.class,
        m.name,
        m.oneway,
        m.oneway_bicycle,
        m.dual_carriageway,
        m.width,
        m.layer,
        m.hierarchy,
        m.geom AS orig_geom,
        CASE
            WHEN clips.clip_geom IS NULL THEN m.geom
            ELSE ST_Difference(m.geom, clips.clip_geom)
        END AS diff_geom
    FROM _ow_out_merged m
    LEFT JOIN LATERAL (
        SELECT ST_UnaryUnion(ST_Collect(b.geom)) AS clip_geom
        FROM (
            SELECT b.geom
            FROM _ow_buf_road b
            WHERE m.is_traffic
              AND m.geom && b.geom
              AND ST_Intersects(m.geom, b.geom)
              AND COALESCE(m.layer, 0) = b.layer
            UNION ALL
            SELECT b.geom
            FROM _ow_buf_all b
            WHERE NOT m.is_traffic
              AND m.geom && b.geom
              AND ST_Intersects(m.geom, b.geom)
              AND COALESCE(m.layer, 0) = b.layer
        ) b
    ) clips ON true
),
area_diff AS (
    SELECT
        d.highway,
        d.type,
        d.class,
        d.name,
        d.oneway,
        d.oneway_bicycle,
        d.dual_carriageway,
        d.width,
        d.layer,
        d.hierarchy,
        d.orig_geom,
        CASE
            WHEN areas.clip_geom IS NULL THEN d.diff_geom
            ELSE ST_Difference(d.diff_geom, areas.clip_geom)
        END AS diff_geom
    FROM buf_diff d
    LEFT JOIN LATERAL (
        SELECT ST_UnaryUnion(ST_Collect(a.geom)) AS clip_geom
        FROM _ow_area_junc a
        WHERE d.diff_geom IS NOT NULL
          AND NOT ST_IsEmpty(d.diff_geom)
          AND d.diff_geom && a.geom
          AND ST_Intersects(d.diff_geom, a.geom)
          AND COALESCE(d.layer, 0) = a.layer
    ) areas ON true
)
SELECT
    d.highway,
    d.type,
    d.class,
    d.name,
    d.oneway,
    d.oneway_bicycle,
    d.dual_carriageway,
    d.width,
    d.layer,
    d.hierarchy,
    d.orig_geom,
    dumped.geom AS geom
FROM area_diff d
CROSS JOIN LATERAL ST_Dump(
    ST_CollectionExtract(d.diff_geom, 2)
) AS dumped(path, geom)
WHERE d.diff_geom IS NOT NULL
  AND NOT ST_IsEmpty(d.diff_geom)
  AND dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND ST_Length(dumped.geom) >= metres(:'oneway_min_fragment_m'::numeric);

-- Restore OSM digitising direction (ST_Difference may reverse fragments)
UPDATE _ow_clipped
SET geom = ST_Reverse(geom)
WHERE ST_LineLocatePoint(orig_geom, ST_StartPoint(geom))
    > ST_LineLocatePoint(orig_geom, ST_EndPoint(geom));

-- ---------------------------------------------------------------------------
-- 6) Reverse oneway=-1 so geometry points in driving direction; remap bicycle
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS highway_oneway;

CREATE TABLE highway_oneway AS
SELECT
    highway,
    type,
    class,
    name,
    CASE
        WHEN oneway_bicycle IS NULL THEN NULL
        WHEN oneway_bicycle = 'no' THEN 'no'
        WHEN oneway IN ('yes', '-1')
         AND oneway_bicycle IN ('yes', '-1')
         AND oneway IS DISTINCT FROM oneway_bicycle THEN '-1'
        WHEN oneway_bicycle IN ('yes', '-1') THEN 'yes'
        ELSE oneway_bicycle
    END AS "oneway:bicycle",
    dual_carriageway,
    width,
    layer,
    hierarchy,
    CASE
        WHEN oneway = '-1' THEN ST_Reverse(geom)
        ELSE geom
    END AS geom
FROM _ow_clipped;

CREATE INDEX highway_oneway_geom_idx ON highway_oneway USING GIST (geom);

COMMIT;
