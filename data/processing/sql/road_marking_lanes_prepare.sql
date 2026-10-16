-- road_marking_lanes_prepare.sql — clip lane centerlines at junctions
-- Run once before road_marking_barred_area.sql, road_marking_separation.sql,
-- road_marking_lane_divider.sql,
-- road_marking_crossing_edge.sql and road_marking_arrows.sql
-- (see data/data_preparation.sh). Depends on: lanes, highway_junctions, highway_area,
-- highway_areas (highway_area_centerline.sql), crossing (import),
-- road_marking_way (stop_line rows from road_marking_stop_lines.sql).
--
-- highway_junctions (from highway_area_centerline.sql) uses buffer overlaps only between
-- different road_segment_id values on the same layer; highway and surface are not
-- considered there, so surface/highway transitions within one segment do not produce
-- false junction clips. layer is carried through clipping polygons end-to-end.
--
-- lanes_clipped: highway_area junction/crossing is omitted from clipping when markings=yes
--   (markings may continue through the junction polygon), and for area:highway
--   motorway/motorway_link with junction=y_junction (class = y_junction).
-- lanes_clipped_for_arrows: same hulls + junction footprints, but junction/crossing areas
--   clip turn arrows even if markings=yes. motorway/motorway_link y-junctions are omitted
--   here as well, so their markings continue through the polygon.

-- 1a) Shared basis: junction footprints + hulls between each stop_line and its nearest junction.
--     This is the expensive part; compute once and reuse.
DROP TABLE IF EXISTS highway_junctions_clipping_base;

CREATE TABLE highway_junctions_clipping_base AS
WITH nearest AS (
    SELECT
        l.geom AS line_geom,
        j.geom AS poly_geom,
        j.layer,
        ST_Distance(l.geom, j.geom) AS dist
    FROM road_marking_way l
    JOIN LATERAL (
        SELECT geom, layer
        FROM highway_junctions
        ORDER BY l.geom <-> geom
        LIMIT 1
    ) j ON true
    WHERE l.road_marking = 'stop_line'
      AND l.source IN (
          'stop_node_generic',
          'stop_node_generic_angled',
          'stop_node_highway_area'
      )
),
hulls AS (
    SELECT
        layer,
        ST_ConvexHull(
            ST_Collect(line_geom, poly_geom)
        ) AS geom
    FROM nearest
    WHERE dist <= 18
),
merged AS (
    SELECT layer, geom FROM highway_junctions
    UNION ALL
    SELECT layer, geom FROM hulls
)
SELECT
    layer,
    (ST_Dump(ST_UnaryUnion(ST_Collect(geom)))).geom AS geom
FROM merged
GROUP BY layer;

DROP INDEX IF EXISTS highway_junctions_clipping_base_geom_idx;
CREATE INDEX highway_junctions_clipping_base_geom_idx
    ON highway_junctions_clipping_base USING GIST (geom);


-- 1b) Clipping polygons for lane markings: base + junction/crossing highway_area polygons,
--     but skip areas with markings=yes (markings may continue through the polygon).
DROP TABLE IF EXISTS highway_junctions_clipping_areas;

CREATE TABLE highway_junctions_clipping_areas AS
WITH merged AS (
    SELECT layer, geom FROM highway_junctions_clipping_base
    UNION ALL
    -- add area:highway junction/crossing polygons (but: if junction/crossing area is tagged
    -- markings=yes, they should not clip lane markings; motorway/motorway_link
    -- y-junctions keep their markings too)
    SELECT ha.layer, ha.geom
    FROM highway_area ha
    WHERE ha.type IN ('junction', 'crossing')
      AND (ha.markings IS NULL OR ha.markings <> 'yes')
      AND NOT (
          ha."area:highway" IN ('motorway', 'motorway_link')
          AND ha.type = 'junction'
          AND ha.class = 'y_junction'
      )
)
SELECT
    layer,
    (ST_Dump(ST_UnaryUnion(ST_Collect(geom)))).geom AS geom
FROM merged
GROUP BY layer;

-- create spatial index
DROP INDEX IF EXISTS highway_junctions_clipping_areas_geom_idx;
CREATE INDEX highway_junctions_clipping_areas_geom_idx ON highway_junctions_clipping_areas USING GIST (geom);


-- 1c) Additional clipping polygons for arrows: only junction/crossing highway_area polygons
--     with markings=yes. Arrows should still be clipped by those (2nd pass), except
--     motorway/motorway_link y-junctions (markings stay).
DROP TABLE IF EXISTS highway_junctions_clipping_areas_markings_yes;

CREATE TABLE highway_junctions_clipping_areas_markings_yes AS
WITH merged AS (
    SELECT ha.layer, ha.geom
    FROM highway_area ha
    WHERE ha.type IN ('junction', 'crossing')
      AND ha.markings = 'yes'
      AND NOT (
          ha."area:highway" IN ('motorway', 'motorway_link')
          AND ha.type = 'junction'
          AND ha.class = 'y_junction'
      )
)
SELECT
    layer,
    (ST_Dump(ST_UnaryUnion(ST_Collect(geom)))).geom AS geom
FROM merged
GROUP BY layer;

DROP INDEX IF EXISTS highway_junctions_clipping_areas_markings_yes_geom_idx;
CREATE INDEX highway_junctions_clipping_areas_markings_yes_geom_idx
    ON highway_junctions_clipping_areas_markings_yes USING GIST (geom);


-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

\i 'processing/sql/helper/highway_road_area.sql'


-- 1d) Crossing lanes only: trim at road / non-road highway_area boundaries; keep fragment
--     containing the reference point. Other lanes pass through unchanged.
--     Tunnel segments are omitted (except building_passage) so no lane markings
--     are generated underground.
DROP TABLE IF EXISTS lanes_road_trimmed;

CREATE TABLE lanes_road_trimmed AS
WITH
surface_lanes AS (
    SELECT l.*
    FROM lanes l
    LEFT JOIN highway h ON h.segment_id = l.segment_id
    WHERE h.tunnel IS NULL
       OR h.tunnel IN ('no', 'none', 'building_passage')
),
non_crossing AS (
    SELECT
        l.osm_id,
        l.highway,
        l.name,
        l.lane_index,
        l.type,
        l.class,
        l.direction,
        l.width,
        l.surface,
        l.turn,
        l.colour,
        l.marking_left,
        l.marking_right,
        l.separation_left,
        l.separation_right,
        l.buffer_left,
        l.buffer_right,
        l.traffic_mode_left,
        l.traffic_mode_right,
        l.layer,
        l."offset",
        l.transition,
        l.geom
    FROM surface_lanes l
    WHERE l.class IS DISTINCT FROM 'crossing'
       OR NOT (
           (l.marking_left IS NOT NULL AND l.marking_left NOT IN ('no', 'none')
            AND (l.marking_left LIKE '%line%' OR l.marking_left = 'barred_area'))
           OR (l.marking_right IS NOT NULL AND l.marking_right NOT IN ('no', 'none')
               AND (l.marking_right LIKE '%line%' OR l.marking_right = 'barred_area'))
       )
),
crossing_candidates AS (
    SELECT
        l.osm_id,
        l.highway,
        l.name,
        l.lane_index,
        l.type,
        l.class,
        l.direction,
        l.width,
        l.surface,
        l.turn,
        l.colour,
        l.marking_left,
        l.marking_right,
        l.separation_left,
        l.separation_right,
        l.buffer_left,
        l.buffer_right,
        l.traffic_mode_left,
        l.traffic_mode_right,
        l.layer,
        l."offset",
        l.transition,
        l.geom AS lane_geom
    FROM surface_lanes l
    WHERE l.class = 'crossing'
      AND (
          (l.marking_left IS NOT NULL AND l.marking_left NOT IN ('no', 'none')
           AND (l.marking_left LIKE '%line%' OR l.marking_left = 'barred_area'))
          OR (l.marking_right IS NOT NULL AND l.marking_right NOT IN ('no', 'none')
              AND (l.marking_right LIKE '%line%' OR l.marking_right = 'barred_area'))
      )
      AND l.geom IS NOT NULL
      AND NOT ST_IsEmpty(l.geom)
      AND ST_GeometryType(l.geom) = 'ST_LineString'
),
with_ref AS (
    SELECT
        cc.*,
        COALESCE(
            (
                SELECT ST_ClosestPoint(cc.lane_geom, c.geom)
                FROM crossing c
                WHERE cc.lane_geom && c.geom
                  AND ST_DWithin(
                      cc.lane_geom,
                      c.geom,
                      metres(:'crossing_road_trim_ref_tolerance'::double precision)
                  )
                ORDER BY cc.lane_geom <-> c.geom
                LIMIT 1
            ),
            ST_LineInterpolatePoint(cc.lane_geom, 0.5)
        ) AS ref_pt
    FROM crossing_candidates cc
),
with_road AS (
    SELECT
        wr.*,
        ru.union_geom
    FROM with_ref wr
    LEFT JOIN LATERAL (
        SELECT ST_Union(parts.geom) AS union_geom
        FROM (
            SELECT ha.geom
            FROM highway_area ha
            INNER JOIN _highway_road_area rh
                ON rh.area_highway = ha."area:highway"
            WHERE ha.geom && wr.lane_geom
              AND ST_Intersects(ha.geom, wr.lane_geom)
              AND (wr.layer IS NULL OR ha.layer IS NOT DISTINCT FROM wr.layer)
            UNION ALL
            SELECT hac.geom
            FROM highway_areas hac
            INNER JOIN _highway_road_area rh
                ON rh.area_highway = hac.highway
            WHERE hac.geom && wr.lane_geom
              AND ST_Intersects(hac.geom, wr.lane_geom)
              AND (wr.layer IS NULL OR hac.layer IS NOT DISTINCT FROM wr.layer)
        ) parts
    ) ru ON true
),
trimmed AS (
    SELECT
        wr.osm_id,
        wr.highway,
        wr.name,
        wr.lane_index,
        wr.type,
        wr.class,
        wr.direction,
        wr.width,
        wr.surface,
        wr.turn,
        wr.colour,
        wr.marking_left,
        wr.marking_right,
        wr.separation_left,
        wr.separation_right,
        wr.buffer_left,
        wr.buffer_right,
        wr.traffic_mode_left,
        wr.traffic_mode_right,
        wr.layer,
        wr."offset",
        wr.transition,
        CASE
            WHEN wr.union_geom IS NULL OR ST_IsEmpty(wr.union_geom)
            THEN wr.lane_geom
            WHEN ST_Intersects(wr.union_geom, wr.ref_pt)
            THEN ST_Intersection(wr.lane_geom, wr.union_geom)
            ELSE ST_Difference(wr.lane_geom, wr.union_geom)
        END AS trimmed_geom,
        wr.ref_pt
    FROM with_road wr
),
crossing_trimmed_dumped AS (
    SELECT
        t.osm_id,
        t.highway,
        t.name,
        t.lane_index,
        t.type,
        t.class,
        t.direction,
        t.width,
        t.surface,
        t.turn,
        t.colour,
        t.marking_left,
        t.marking_right,
        t.separation_left,
        t.separation_right,
        t.buffer_left,
        t.buffer_right,
        t.traffic_mode_left,
        t.traffic_mode_right,
        t.layer,
        t."offset",
        t.transition,
        (dp.geom)::geometry(LineString) AS geom
    FROM trimmed t
    CROSS JOIN LATERAL ST_Dump(t.trimmed_geom) AS dp
    WHERE t.trimmed_geom IS NOT NULL
      AND NOT ST_IsEmpty(t.trimmed_geom)
      AND ST_GeometryType((dp.geom)) = 'ST_LineString'
      AND ST_DWithin(
          (dp.geom)::geometry,
          t.ref_pt,
          metres(:'crossing_road_trim_ref_tolerance'::double precision)
      )
      AND ST_Length((dp.geom)) >= metres(:'crossing_road_trim_min_length'::double precision)
)
SELECT * FROM non_crossing
UNION ALL
SELECT * FROM crossing_trimmed_dumped;

DROP INDEX IF EXISTS lanes_road_trimmed_geom_idx;
CREATE INDEX lanes_road_trimmed_geom_idx ON lanes_road_trimmed USING GIST (geom);


-- 2) lanes_clipped: ST_Difference against intersecting clipping union per lane (skip when
--     lane_markings:junction=yes). Dump to simple LineStrings. TODO: simplify this step.
DROP TABLE IF EXISTS lanes_clipped;

CREATE TABLE lanes_clipped AS
WITH
-- for each lane, find intersecting clipping areas and union only those
lanes_with_clipping AS (
    SELECT
        lrt.osm_id,
        lrt.highway,
        lrt.name,
        lrt.lane_index,
        lrt.type,
        lrt.class,
        lrt.direction,
        lrt.width,
        lrt.surface,
        lrt.turn,
        lrt.colour,
        lrt.marking_left,
        lrt.marking_right,
        lrt.separation_left,
        lrt.separation_right,
        lrt.buffer_left,
        lrt.buffer_right,
        lrt.traffic_mode_left,
        lrt.traffic_mode_right,
        lrt.layer,
        lrt."offset",
        lrt.transition,
        lrt.geom AS lane_geom,
        -- Union only clipping polygons that intersect this lane
        ST_Union(clipping.geom) AS clipping_geom
    FROM lanes_road_trimmed lrt
    INNER JOIN lanes
      ON lanes.osm_id = lrt.osm_id
     AND lanes.lane_index = lrt.lane_index
    LEFT JOIN highway_junctions_clipping_areas clipping
      ON lrt.geom && clipping.geom  -- bbox filter (spatial index)
     AND ST_Intersects(lrt.geom, clipping.geom)
     AND lrt.layer IS NOT DISTINCT FROM clipping.layer
     AND lanes."lane_markings:junction" IS DISTINCT FROM 'yes'
    GROUP BY
        lrt.osm_id, lrt.highway, lrt.name, lrt.lane_index,
        lrt.type, lrt.class, lrt.direction, lrt.width,
        lrt.surface, lrt.turn, lrt.colour,
        lrt.marking_left, lrt.marking_right,
        lrt.separation_left, lrt.separation_right,
        lrt.buffer_left, lrt.buffer_right,
        lrt.traffic_mode_left, lrt.traffic_mode_right,
        lrt.layer, lrt."offset", lrt.transition,
        lrt.geom
),
-- apply difference only where clipping areas exist
clipped AS (
    SELECT
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        layer,
        "offset",
        transition,
        CASE
            -- if clipping areas exist, apply difference
            WHEN clipping_geom IS NOT NULL THEN
                ST_Difference(lane_geom, clipping_geom)
            -- otherwise keep original geometry
            ELSE lane_geom
        END AS geom
    FROM lanes_with_clipping
),
-- dump multi-geometries and filter
dumped AS (
    SELECT
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        layer,
        "offset",
        transition,
        (ST_Dump(geom)).geom AS geom
    FROM clipped
)
SELECT
    osm_id,
    highway,
    name,
    lane_index,
    type,
    class,
    direction,
    width,
    surface,
    turn,
    colour,
    marking_left,
    marking_right,
    separation_left,
    separation_right,
    buffer_left,
    buffer_right,
    traffic_mode_left,
    traffic_mode_right,
    layer,
    "offset",
    transition,
    geom
FROM dumped
WHERE NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString';

-- create spatial index
DROP INDEX IF EXISTS lanes_clipped_geom_idx;
CREATE INDEX lanes_clipped_geom_idx ON lanes_clipped USING GIST (geom);


-- 3) lanes_clipped_for_arrows: apply an additional difference step against ONLY those
--    junction/crossing highway_area polygons that are tagged markings=yes.
DROP TABLE IF EXISTS lanes_clipped_for_arrows;

CREATE TABLE lanes_clipped_for_arrows AS
WITH
lanes_with_clipping AS (
    SELECT
        lc.osm_id,
        lc.highway,
        lc.name,
        lc.lane_index,
        lc.type,
        lc.class,
        lc.direction,
        lc.width,
        lc.surface,
        lc.turn,
        lc.colour,
        lc.marking_left,
        lc.marking_right,
        lc.separation_left,
        lc.separation_right,
        lc.buffer_left,
        lc.buffer_right,
        lc.traffic_mode_left,
        lc.traffic_mode_right,
        lc.layer,
        lc."offset",
        lc.transition,
        lc.geom AS lane_geom,
        ST_Union(extra.geom) AS clipping_geom
    FROM lanes_clipped lc
    INNER JOIN lanes l
        ON l.osm_id = lc.osm_id
       AND l.lane_index = lc.lane_index
    LEFT JOIN highway_junctions_clipping_areas_markings_yes extra
      ON lc.geom && extra.geom
     AND ST_Intersects(lc.geom, extra.geom)
     AND lc.layer IS NOT DISTINCT FROM extra.layer
     AND l."lane_markings:junction" IS DISTINCT FROM 'yes'
    GROUP BY
        lc.osm_id, lc.highway, lc.name, lc.lane_index,
        lc.type, lc.class, lc.direction, lc.width,
        lc.surface, lc.turn, lc.colour,
        lc.marking_left, lc.marking_right,
        lc.separation_left, lc.separation_right,
        lc.buffer_left, lc.buffer_right,
        lc.traffic_mode_left, lc.traffic_mode_right,
        lc.layer, lc."offset", lc.transition,
        lc.geom
),
clipped AS (
    SELECT
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        layer,
        "offset",
        transition,
        CASE
            WHEN clipping_geom IS NOT NULL THEN
                ST_Difference(lane_geom, clipping_geom)
            ELSE lane_geom
        END AS geom
    FROM lanes_with_clipping
),
dumped AS (
    SELECT
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        layer,
        "offset",
        transition,
        (ST_Dump(geom)).geom AS geom
    FROM clipped
)
SELECT
    osm_id,
    highway,
    name,
    lane_index,
    type,
    class,
    direction,
    width,
    surface,
    turn,
    colour,
    marking_left,
    marking_right,
    separation_left,
    separation_right,
    buffer_left,
    buffer_right,
    traffic_mode_left,
    traffic_mode_right,
    layer,
    "offset",
    transition,
    geom
FROM dumped
WHERE NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString';

DROP INDEX IF EXISTS lanes_clipped_for_arrows_geom_idx;
CREATE INDEX lanes_clipped_for_arrows_geom_idx ON lanes_clipped_for_arrows USING GIST (geom);

-- drop clipping polygons, we don't need them anymore
-- DROP TABLE IF EXISTS highway_junctions_clipping_areas;
-- DROP TABLE IF EXISTS highway_junctions_clipping_base;
-- DROP TABLE IF EXISTS highway_junctions_clipping_areas_markings_yes;
