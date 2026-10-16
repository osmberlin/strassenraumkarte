-- dissolves service ways for better rendering
-- groups by class (OSM service=* tag, filled in osm_import.lua) plus width and layer
-- real tunnels stay out (tunnel set and not no/none/NULL/building_passage)
--
-- Line parts that lie inside mapped highway_area polygons with
-- area:highway=service (same layer) are clipped away so the centerline is
-- not drawn on top of those areas.
-- Depends on: highway (highway_preparation.sql); highway_area (highway_area_merge.sql)

\i 'processing/sql/helper/metres.sql'

DROP TABLE IF EXISTS highway_service;

CREATE TABLE highway_service AS
WITH service_ways AS (
    SELECT
        class,
        width,
        layer,
        geom
    FROM highway
    WHERE highway = 'service'
      AND (
            tunnel IS NULL
         OR tunnel IN ('no', 'none', 'building_passage')
      )
),
clipped AS (
    SELECT
        sw.class,
        sw.width,
        sw.layer,
        (ST_Dump(
            CASE
                WHEN intersecting_areas.geom IS NULL THEN sw.geom
                ELSE ST_Difference(sw.geom, intersecting_areas.geom)
            END
        )).geom AS geom
    FROM service_ways sw
    LEFT JOIN LATERAL (
        SELECT ST_Union(ha.geom) AS geom
        FROM highway_area ha
        WHERE ha."area:highway" = 'service'
          AND ha.geom && sw.geom
          AND ST_Intersects(sw.geom, ha.geom)
          AND sw.layer IS NOT DISTINCT FROM ha.layer
    ) intersecting_areas ON TRUE
)
SELECT
    class,
    width,
    layer,
    (ST_Dump(ST_LineMerge(ST_Union(geom)))).geom AS geom
FROM clipped
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) >= metres(0.1)
GROUP BY class, width, layer;

CREATE INDEX highway_service_geom_idx ON highway_service USING GIST (geom);
