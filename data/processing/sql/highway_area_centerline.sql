-- highway_area_centerline.sql — create highway_areas from road centerlines, lane and road width attributes
-- Depends on: highway_transformed (lanes_spread_dual_carriageway.sql), highway_preparation.sql

-- Move OSM-mapped highway areas in tunnels aside (streets underground are not
-- rendered as road surfaces; building_passage stays visible). Kept in
-- highway_area_tunnel for tunnel portal shared-edge detection.
DROP TABLE IF EXISTS highway_area_tunnel;
CREATE TABLE highway_area_tunnel AS
SELECT *
FROM highway_area
WHERE tunnel IS NOT NULL
  AND tunnel NOT IN ('no', 'none', 'building_passage');

CREATE INDEX highway_area_tunnel_geom_idx
    ON highway_area_tunnel USING GIST (geom);

DELETE FROM highway_area
WHERE tunnel IS NOT NULL
  AND tunnel NOT IN ('no', 'none', 'building_passage');

-- 1) clip road segments where area:highway polygons exists
DROP TABLE IF EXISTS highway_clipped;
CREATE TABLE highway_clipped AS

SELECT
    ht.road_segment_id,
    CASE
        WHEN ht.highway = 'construction'
             AND ht.construction IS NOT NULL
             AND ht.construction <> ''
            THEN ht.construction
        ELSE ht.highway
    END AS highway,
    CASE
        WHEN ht.highway = 'construction'
             AND ht.construction IS NOT NULL
             AND ht.construction <> ''
            THEN 'construction'
        ELSE NULL
    END AS type,
    ht.surface,
    ht.osm_type,
    ht.osm_id,
    ht.tunnel,
    ht.hierarchy,
    ht.layer,
    ht."sett:length",
    ht.width,
    ht.placement_offset,
        (ST_Dump( -- dump single parts of multilinestrings
            CASE
                -- keep original road geometry, when no clipping is necessary
                WHEN intersecting_areas.geom IS NULL
                    THEN ht.geom
                ELSE
                    ST_Difference(
                        ht.geom,
                        intersecting_areas.geom
                    )
            END
        )).geom AS geom
FROM highway_transformed ht
-- filter intersecting highway areas for each segment (might be faster than a UNION for all area polygons, depending on map size, number of highway segments and area polygons)
LEFT JOIN LATERAL (
    SELECT
        ST_Union(highway_area.geom) AS geom
    FROM highway_area
    WHERE
        highway_area.geom && ht.geom -- bounding box filter (GiST index) first...
        AND ST_Intersects(ht.geom, highway_area.geom) -- ...then exact intersection test
        AND ht.layer IS NOT DISTINCT FROM highway_area.layer
) intersecting_areas
ON TRUE
-- only motorways and regular roads (exclude path, service, …); requires highway_preparation.sql
-- tunnels are not rendered as highway areas
WHERE ht.type IN ('road', 'motorway')
  AND ht.road_segment_id IS NOT NULL
  AND (ht.tunnel IS NULL OR ht.tunnel IN ('no', 'none', 'building_passage'));

-- exclude empty geometries
DELETE FROM highway_clipped
WHERE
    geom IS NULL
    OR ST_Length(geom) < metres(0.5) -- delete very short artefacts, e.g. when highway areas aren't exact seemless
    OR ST_IsEmpty(geom);

-- create spatial index
DROP INDEX IF EXISTS highway_clipped_geom_idx;
CREATE INDEX highway_clipped_geom_idx ON highway_clipped USING GIST (geom);

-- dominant source attributes per merge group (longest centerline)
DROP TABLE IF EXISTS highway_clipped_attrs;
CREATE TABLE highway_clipped_attrs AS
SELECT DISTINCT ON (road_segment_id, highway, surface, layer, tunnel, "sett:length", type)
    road_segment_id,
    highway,
    surface,
    layer,
    tunnel,
    "sett:length",
    type,
    osm_type,
    osm_id,
    hierarchy
FROM highway_clipped
ORDER BY
    road_segment_id,
    highway,
    surface,
    layer,
    tunnel,
    "sett:length",
    type,
    ST_Length(geom) DESC;

DROP INDEX IF EXISTS highway_clipped_attrs_group_idx;
CREATE INDEX highway_clipped_attrs_group_idx
    ON highway_clipped_attrs (road_segment_id, highway, surface, layer, tunnel, "sett:length", type);


-- 2) buffer road segments (per road_segment_id, highway, surface, layer, tunnel, sett:length, type)
DROP TABLE IF EXISTS highway_buffers;
CREATE TABLE highway_buffers AS

SELECT
    road_segment_id,
    highway,
    surface,
    layer,
    tunnel,
    "sett:length",
    type,
    (ST_Dump(
        -- fill gaps and smooth outlines by buffering and shrinking
        ST_Buffer(
            ST_Buffer(
                ST_Union(buffer_geom),
                metres(5)
            ),
            metres(-5)
        )
    )).geom AS geom
FROM (
    SELECT
        road_segment_id,
        highway,
        surface,
        layer,
        tunnel,
        "sett:length",
        type,

        -- buffer on the left and right side of the centerline, then merge
        ST_Union(
            ST_Buffer(
                ST_LineExtend(geom, metres(1), metres(1)),
                -- geom,
                metres((width / 2.0) - placement_offset),
                'side=left join=mitre'
            ),
            ST_Buffer(
                ST_LineExtend(geom, metres(1), metres(1)),
                -- geom,
                metres((width / 2.0) + placement_offset),
                'side=right join=mitre'
            )
        ) AS buffer_geom
    FROM highway_clipped
) AS buffered
GROUP BY
    road_segment_id,
    highway,
    surface,
    layer,
    tunnel,
    "sett:length",
    type;

-- create spatial index
DROP INDEX IF EXISTS highway_buffers_geom_idx;
CREATE INDEX highway_buffers_geom_idx ON highway_buffers USING GIST (geom);


-- 3) dissolve road areas with matching road_segment_id, highway, surface, layer, tunnel, sett:length and type
DROP TABLE IF EXISTS highway_areas;

CREATE TABLE highway_areas AS
SELECT
    grouped.road_segment_id,
    attrs.osm_type,
    attrs.osm_id,
    grouped.highway,
    grouped.surface,
    grouped."sett:length",
    grouped.tunnel,
    attrs.hierarchy,
    grouped.layer,
    grouped.type,
    grouped.geom
FROM (
    SELECT
        road_segment_id,
        highway,
        surface,
        layer,
        tunnel,
        "sett:length",
        type,
        (ST_Dump(ST_Union(geom))).geom AS geom
    FROM highway_buffers
    GROUP BY
        road_segment_id,
        highway,
        surface,
        layer,
        tunnel,
        "sett:length",
        type
) AS grouped
INNER JOIN highway_clipped_attrs attrs
    ON attrs.road_segment_id = grouped.road_segment_id
   AND attrs.highway IS NOT DISTINCT FROM grouped.highway
   AND attrs.surface IS NOT DISTINCT FROM grouped.surface
   AND attrs.layer IS NOT DISTINCT FROM grouped.layer
   AND attrs.tunnel IS NOT DISTINCT FROM grouped.tunnel
   AND attrs."sett:length" IS NOT DISTINCT FROM grouped."sett:length"
   AND attrs.type IS NOT DISTINCT FROM grouped.type
WHERE ST_Area(grouped.geom) >= 1;

-- create spatial index
DROP INDEX IF EXISTS highway_areas_geom_idx;
CREATE INDEX highway_areas_geom_idx ON highway_areas USING GIST (geom);


-- 4) get junction areas (only between different road_segment_id on the same layer)
DROP TABLE IF EXISTS highway_junctions;

CREATE TABLE highway_junctions AS
WITH numbered AS (
  SELECT
      road_segment_id,
      layer,
      geom
  FROM highway_buffers
),
junctions AS (
  SELECT
      a.layer,
      ST_Intersection(a.geom, b.geom) AS geom
  FROM numbered a
  JOIN numbered b
    ON a.road_segment_id < b.road_segment_id
   AND a.layer IS NOT DISTINCT FROM b.layer
   AND a.geom && b.geom              -- bounding box filter (GiST index)
   AND ST_Intersects(a.geom, b.geom) -- exact intersection
)
SELECT
    layer,
    -- fill gaps and extend outlines by buffering more than shrinking
    (ST_Dump(
        ST_Buffer(
            ST_Buffer(
                ST_Union(geom),
                metres(10),
                'join=mitre'
            ),
            metres(-5),
            'join=mitre'
        )
    )).geom AS geom
FROM junctions
WHERE ST_Area(geom) > 0
GROUP BY layer;

-- create spatial index
DROP INDEX IF EXISTS highway_junctions_geom_idx;
CREATE INDEX highway_junctions_geom_idx ON highway_junctions USING GIST (geom);


-- -- 5) extract outlines (boundaries) of junction polygons
-- DROP TABLE IF EXISTS highway_junctions_outline;

-- CREATE TABLE highway_junctions_outline AS
-- SELECT
--     (ST_Dump(ST_Boundary(geom))).geom AS geom
-- FROM highway_junctions;

-- -- create spatial index
-- DROP INDEX IF EXISTS highway_junctions_outline_geom_idx;
-- CREATE INDEX highway_junctions_outline_geom_idx ON highway_junctions_outline USING GIST (geom);


-- clean up tables that we don't need anymore
DROP TABLE IF EXISTS highway_clipped;
DROP TABLE IF EXISTS highway_clipped_attrs;
DROP TABLE IF EXISTS highway_buffers;