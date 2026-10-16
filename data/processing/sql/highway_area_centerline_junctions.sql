-- highway_area_centerline_junctions.sql — punch junction zones out of highway_areas and merge
-- stamped-out parts per clipping polygon into one junction area each.
-- Depends on: highway_areas (highway_area_centerline.sql),
--   highway_junctions_clipping_areas (road_marking_lanes_prepare.sql).

DROP TABLE IF EXISTS _highway_areas_merge;

CREATE TABLE _highway_areas_merge AS
WITH clipping AS (
    SELECT
        row_number() OVER (ORDER BY layer, geom) AS clip_id,
        layer,
        geom
    FROM highway_junctions_clipping_areas
),
-- intersection parts per clipping polygon (for junction merge + attribute voting)
junction_parts_raw AS (
    SELECT
        c.clip_id,
        ha.osm_type,
        ha.osm_id,
        ha.highway,
        ha.surface,
        ha."sett:length",
        ha.tunnel,
        ha.hierarchy,
        ha.layer,
        ST_Intersection(ha.geom, c.geom) AS isect_geom
    FROM highway_areas ha
    INNER JOIN clipping c
        ON ha.geom && c.geom
       AND ST_Intersects(ha.geom, c.geom)
       AND ha.layer IS NOT DISTINCT FROM c.layer
),
junction_parts AS (
    SELECT
        clip_id,
        osm_type,
        osm_id,
        highway,
        surface,
        "sett:length",
        tunnel,
        hierarchy,
        layer,
        (ST_Dump(isect_geom)).geom AS geom
    FROM junction_parts_raw
    WHERE isect_geom IS NOT NULL
      AND NOT ST_IsEmpty(isect_geom)
),
junction_parts_filtered AS (
    SELECT *
    FROM junction_parts
    WHERE ST_Area(geom) >= 1
),
-- road areas outside junction clipping zones
-- Fast path: no bbox hit → keep original geometry.
-- Otherwise ST_Difference against union of only intersecting clips (not global union).
outside_raw AS (
    SELECT
        ha.road_segment_id,
        ha.osm_type,
        ha.osm_id,
        ha.highway,
        ha.surface,
        ha."sett:length",
        ha.tunnel,
        ha.hierarchy,
        ha.layer,
        ha.type,
        CASE
            WHEN local_clips.clip_geom IS NULL THEN ha.geom
            ELSE ST_Difference(ha.geom, local_clips.clip_geom)
        END AS diff_geom
    FROM highway_areas ha
    LEFT JOIN LATERAL (
        SELECT ST_UnaryUnion(ST_Collect(c.geom)) AS clip_geom
        FROM clipping c
        WHERE ha.geom && c.geom
          AND ST_Intersects(ha.geom, c.geom)
          AND ha.layer IS NOT DISTINCT FROM c.layer
    ) local_clips ON true
),
outside_parts AS (
    SELECT
        road_segment_id,
        osm_type,
        osm_id,
        highway,
        surface,
        "sett:length",
        tunnel,
        hierarchy,
        layer,
        type,
        (ST_Dump(diff_geom)).geom AS geom
    FROM outside_raw
    WHERE diff_geom IS NOT NULL
      AND NOT ST_IsEmpty(diff_geom)
),
outside_filtered AS (
    SELECT *
    FROM outside_parts
    WHERE ST_Area(geom) >= 1
),
-- dominant surface (area-weighted, including NULL), then all attributes from the largest
-- fragment within that surface group
surface_weights AS (
    SELECT
        clip_id,
        surface,
        SUM(ST_Area(geom)) AS area
    FROM junction_parts_filtered
    GROUP BY clip_id, surface
),
surface_choice AS (
    SELECT DISTINCT ON (clip_id)
        clip_id,
        surface
    FROM surface_weights
    ORDER BY
        clip_id,
        area DESC,
        surface NULLS LAST
),
dominant_surface_parts AS (
    SELECT jp.*
    FROM junction_parts_filtered jp
    INNER JOIN surface_choice sc
        ON sc.clip_id = jp.clip_id
       AND jp.surface IS NOT DISTINCT FROM sc.surface
),
junction_attrs AS (
    SELECT DISTINCT ON (clip_id)
        clip_id,
        osm_type,
        osm_id,
        highway,
        surface,
        "sett:length",
        tunnel,
        hierarchy,
        layer
    FROM dominant_surface_parts
    ORDER BY
        clip_id,
        ST_Area(geom) DESC
),
junction_merged AS (
    SELECT
        clip_id,
        ST_Buffer(
            ST_Buffer(
                ST_Union(geom),
                metres(5),
                'quad_segs=16'
            ),
            metres(-5),
            'quad_segs=16'
        ) AS geom
    FROM junction_parts_filtered
    GROUP BY clip_id
),
junction_areas AS (
    SELECT
        NULL::bigint AS road_segment_id,
        ja.osm_type,
        ja.osm_id,
        ja.highway,
        ja.surface,
        ja."sett:length",
        ja.tunnel,
        ja.hierarchy,
        ja.layer,
        'junction'::text AS type,
        jm.geom
    FROM junction_merged jm
    INNER JOIN junction_attrs ja ON ja.clip_id = jm.clip_id
    WHERE NOT ST_IsEmpty(jm.geom)
      AND ST_Area(jm.geom) >= 1
)
SELECT
    road_segment_id,
    osm_type,
    osm_id,
    highway,
    surface,
    "sett:length",
    tunnel,
    hierarchy,
    layer,
    type,
    geom
FROM outside_filtered
UNION ALL
SELECT
    road_segment_id,
    osm_type,
    osm_id,
    highway,
    surface,
    "sett:length",
    tunnel,
    hierarchy,
    layer,
    type,
    geom
FROM junction_areas;

DROP TABLE IF EXISTS highway_areas;
ALTER TABLE _highway_areas_merge RENAME TO highway_areas;

DROP INDEX IF EXISTS highway_areas_geom_idx;
CREATE INDEX highway_areas_geom_idx ON highway_areas USING GIST (geom);
