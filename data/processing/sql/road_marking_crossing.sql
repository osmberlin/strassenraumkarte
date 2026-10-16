-- road_marking_crossing.sql — Crossing markings from crossing nodes and tagged path ways.
--
-- Depends on: highway_area (after highway_area_merge.sql), crossing.road_azimuth (§0), highway,
--             barrier_node (osm_import.lua), road_marking_way and road_marking_polygon
--             surface_colour (road_marking_colour.sql), _mapping_issues (osm_import.lua)
-- Output: road_marking_way (crossing | crossing_edge); road_marking_polygon (zebra_stripe);
--         _mapping_issues (§1b, §1c); clips barred_area and surface_colour at crossings

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/line_offset.sql'


----------------------------------------------------------------------
-- §0) road_azimuth on crossing nodes (same helper as stop lines §3b), integer degrees [0, 360)
--     Represents the orientation of the road centerline itself (not the crossing axis).
--     Contexts that need a line across the road (crossing axis) add ±90° (see §3, crossing_generic).
----------------------------------------------------------------------

ALTER TABLE crossing ADD COLUMN IF NOT EXISTS road_azimuth integer;
ALTER TABLE crossing ADD COLUMN IF NOT EXISTS temporary text;
ALTER TABLE highway ADD COLUMN IF NOT EXISTS temporary text;

DROP TABLE IF EXISTS _node_road_azimuth_input;
CREATE TEMP TABLE _node_road_azimuth_input AS
SELECT osm_id AS node_id, geom
FROM crossing;

CREATE INDEX _node_road_azimuth_input_geom_idx
    ON _node_road_azimuth_input USING GIST (geom);
CREATE INDEX _node_road_azimuth_input_node_id_idx
    ON _node_road_azimuth_input (node_id);

\i 'processing/sql/helper/node_road_azimuth.sql'

UPDATE crossing c
SET road_azimuth = MOD(ROUND(DEGREES(na.road_azimuth))::integer + 360, 360)
FROM _node_road_azimuth na
WHERE c.osm_id = na.node_id
  AND na.road_azimuth IS NOT NULL;

DROP TABLE IF EXISTS _node_road_azimuth_input;
DROP TABLE IF EXISTS _node_road_azimuth;


----------------------------------------------------------------------
-- §1) Filter crossing nodes
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_filtered;
CREATE TABLE crossing_filtered AS
SELECT c.*
FROM crossing c
WHERE c."crossing" IN ('traffic_signals', 'marked', 'zebra')
   OR (
       c."crossing:markings" IS NOT NULL
       AND c."crossing:markings" NOT IN ('no', 'surface')
   )
   OR c."crossing:buffer_marking" IS NOT NULL
   OR (
       c."crossing_ref" IS NOT NULL
       AND c."crossing_ref" NOT IN ('no', 'none')
   );

CREATE INDEX crossing_filtered_geom_idx
    ON crossing_filtered USING GIST (geom);
CREATE INDEX crossing_filtered_osm_id_idx
    ON crossing_filtered (osm_id);


----------------------------------------------------------------------
-- §1b) QC: conflicting crossing tags between node and path way
----------------------------------------------------------------------

INSERT INTO _mapping_issues (type, description, osm_type, osm_id, geom)
WITH path_pairs AS (
    SELECT
        c.osm_type,
        c.osm_id,
        c.geom,
        c."crossing" AS node_crossing,
        h."crossing" AS way_crossing,
        c."crossing:markings" AS node_markings,
        h."crossing:markings" AS way_markings,
        c."crossing_ref" AS node_ref,
        h."crossing_ref" AS way_ref
    FROM crossing c
    JOIN highway h
      ON h.type = 'path'
     AND h.geom && c.geom
     AND ST_Intersects(h.geom, c.geom)
),
tag_conflicts AS (
    SELECT
        osm_type,
        osm_id,
        geom,
        unnest(
            ARRAY_REMOVE(
                ARRAY[
                    CASE
                        WHEN nullif(trim(node_crossing), '') IS NOT NULL
                         AND nullif(trim(way_crossing), '') IS NOT NULL
                         AND node_crossing IS DISTINCT FROM way_crossing
                        THEN 'crossing'
                    END,
                    CASE
                        WHEN nullif(trim(node_markings), '') IS NOT NULL
                         AND nullif(trim(way_markings), '') IS NOT NULL
                         AND node_markings IS DISTINCT FROM way_markings
                        THEN 'crossing:markings'
                    END,
                    CASE
                        WHEN nullif(trim(node_ref), '') IS NOT NULL
                         AND nullif(trim(way_ref), '') IS NOT NULL
                         AND node_ref IS DISTINCT FROM way_ref
                        THEN 'crossing_ref'
                    END
                ],
                NULL
            )
        ) AS tag_name
    FROM path_pairs
)
SELECT
    'critical'::text,
    'Conflicting tags between crossing node and crossing way (' ||
    string_agg(DISTINCT tag_name, ', ' ORDER BY tag_name) ||
    ')'::text,
    osm_type,
    osm_id,
    geom
FROM tag_conflicts
WHERE tag_name IS NOT NULL
GROUP BY osm_type, osm_id, geom;


----------------------------------------------------------------------
-- §1c) QC: path ways with crossing tags but not footway/cycleway/path=crossing
----------------------------------------------------------------------

INSERT INTO _mapping_issues (type, description, osm_type, osm_id, geom)
SELECT
    'warning'::text,
    'Path with crossing tags, but not tagged as crossing.'::text,
    h.osm_type,
    h.osm_id,
    ST_LineInterpolatePoint(h.geom, 0.5)
FROM highway h
WHERE h.type = 'path'
  AND h.class IS DISTINCT FROM 'crossing'
  AND (
      h."crossing" IN ('traffic_signals', 'marked', 'zebra')
      OR (
          h."crossing:markings" IS NOT NULL
          AND h."crossing:markings" NOT IN ('no', 'surface')
      )
      OR (
          h."crossing_ref" IS NOT NULL
          AND h."crossing_ref" NOT IN ('no', 'none')
      )
  );


----------------------------------------------------------------------
-- §2) Path segments at crossing nodes (split + endpoint segments only)
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_path_segments;
CREATE TABLE crossing_path_segments AS
WITH paths_at_crossing AS (
    SELECT
        c.osm_id AS crossing_id,
        c.geom AS crossing_geom,
        c.road_azimuth,
        c.osm_type AS crossing_osm_type,
        c.osm_id AS crossing_osm_id,
        c."crossing" AS node_crossing,
        c."crossing:markings" AS node_crossing_markings,
        c."crossing_ref" AS node_crossing_ref,
        c."crossing:buffer_marking" AS node_buffer_marking,
        c.temporary AS node_temporary,
        h.osm_id AS path_id,
        h.osm_type AS path_osm_type,
        h.geom AS path_geom,
        h.width AS path_width,
        h.layer AS path_layer,
        h.surface AS path_surface,
        h."crossing" AS path_crossing,
        h."crossing:markings" AS path_crossing_markings,
        h."crossing_ref" AS path_crossing_ref,
        h.class AS path_class,
        h.highway AS path_highway,
        h.temporary AS path_temporary
    FROM crossing_filtered c
    JOIN highway h
      ON h.geom && c.geom
     AND ST_Intersects(h.geom, c.geom)
     AND h.type = 'path'
     AND h.class = 'crossing'
),
split_parts AS (
    SELECT
        pac.*,
        (d.geom)::geometry(LineString) AS seg_geom
    FROM paths_at_crossing pac
    CROSS JOIN LATERAL (
        SELECT geom
        FROM (
            SELECT (ST_Dump(
                CASE
                    WHEN ST_Intersects(ST_StartPoint(pac.path_geom), pac.crossing_geom)
                      OR ST_Intersects(ST_EndPoint(pac.path_geom), pac.crossing_geom)
                    THEN pac.path_geom
                    ELSE ST_Split(pac.path_geom, pac.crossing_geom)
                END
            )).geom
        ) parts
        WHERE ST_GeometryType(parts.geom) = 'ST_LineString'
          AND ST_Length(parts.geom) > metres(0.01)
          AND ST_Intersects(parts.geom, pac.crossing_geom)
    ) d
)
SELECT
    seg.*
FROM (
    SELECT
        sp.crossing_id,
        sp.crossing_geom,
        sp.road_azimuth,
        sp.crossing_osm_type,
        sp.crossing_osm_id,
        sp.node_crossing,
        sp.node_crossing_markings,
        sp.node_crossing_ref,
        sp.node_buffer_marking,
        sp.path_id,
        sp.path_osm_type,
        sp.path_geom,
        sp.path_width,
        sp.path_layer,
        sp.path_surface,
        sp.path_crossing,
        sp.path_crossing_markings,
        sp.path_crossing_ref,
        sp.path_class,
        sp.path_highway,
        sp.node_temporary,
        sp.path_temporary,
        sp.seg_geom,
        CASE
            WHEN ST_Equals(ST_StartPoint(sp.seg_geom), sp.crossing_geom)
            THEN ST_Azimuth(
                ST_PointN(sp.seg_geom, 1),
                ST_PointN(sp.seg_geom, LEAST(2, ST_NPoints(sp.seg_geom)))
            )
            WHEN ST_Equals(ST_EndPoint(sp.seg_geom), sp.crossing_geom)
            THEN ST_Azimuth(
                ST_PointN(sp.seg_geom, ST_NPoints(sp.seg_geom)),
                ST_PointN(sp.seg_geom, GREATEST(1, ST_NPoints(sp.seg_geom) - 1))
            )
            ELSE NULL::double precision
        END AS segment_azimuth
    FROM split_parts sp
    WHERE ST_NPoints(sp.seg_geom) >= 2
      AND (
          ST_Equals(ST_StartPoint(sp.seg_geom), sp.crossing_geom)
          OR ST_Equals(ST_EndPoint(sp.seg_geom), sp.crossing_geom)
      )
) seg
WHERE seg.segment_azimuth IS NOT NULL;

CREATE INDEX crossing_path_segments_crossing_id_idx
    ON crossing_path_segments (crossing_id);
CREATE INDEX crossing_path_segments_geom_idx
    ON crossing_path_segments USING GIST (seg_geom);


----------------------------------------------------------------------
-- §3) Side analysis and centerline generation (node-driven)
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_path_segments_scored;
CREATE TABLE crossing_path_segments_scored AS
SELECT
    cps.*,
        -- crossing axis (perpendicular to the road) = road_azimuth + 90°
        ABS(ATAN2(
            SIN(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2)),
            COS(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2))
        )) AS angle_to_crossing_axis,
        CASE
            WHEN ABS(ATAN2(
                SIN(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2)),
                COS(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2))
            )) <= ABS(ATAN2(
                SIN(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2 + pi())),
                COS(cps.segment_azimuth - (RADIANS(cps.road_azimuth) + pi() / 2 + pi()))
            ))
        THEN 'a'::text
        ELSE 'b'::text
    END AS side
FROM crossing_path_segments cps
WHERE cps.road_azimuth IS NOT NULL;

CREATE INDEX crossing_path_segments_scored_crossing_side_idx
    ON crossing_path_segments_scored (crossing_id, side);

DROP TABLE IF EXISTS crossing_best_segment_per_side;
CREATE TABLE crossing_best_segment_per_side AS
SELECT *
FROM (
    SELECT
        cps.*,
        ROW_NUMBER() OVER (
            PARTITION BY cps.crossing_id, cps.side
            ORDER BY cps.angle_to_crossing_axis, cps.path_id
        ) AS rn
    FROM crossing_path_segments_scored cps
) ranked
WHERE rn = 1;

DROP TABLE IF EXISTS crossing_sides_present;
CREATE TABLE crossing_sides_present AS
SELECT
    crossing_id,
    COUNT(*) FILTER (WHERE side = 'a') > 0 AS has_side_a,
    COUNT(*) FILTER (WHERE side = 'b') > 0 AS has_side_b
FROM crossing_best_segment_per_side
GROUP BY crossing_id;

DROP TABLE IF EXISTS crossing_node_centerlines;
CREATE TABLE crossing_node_centerlines AS
WITH both_sides AS (
    SELECT crossing_id
    FROM crossing_sides_present
    WHERE has_side_a AND has_side_b
),
side_a AS (
    SELECT * FROM crossing_best_segment_per_side WHERE side = 'a'
),
side_b AS (
    SELECT * FROM crossing_best_segment_per_side WHERE side = 'b'
),
way_lines AS (
    SELECT
        sa.crossing_id,
        sa.crossing_geom,
        sa.crossing_osm_type,
        sa.crossing_osm_id,
        sa.node_crossing,
        sa.node_crossing_markings,
        sa.node_crossing_ref,
        sa.node_buffer_marking,
        CASE
            WHEN sa.path_id = sb.path_id THEN sa.path_geom
            ELSE ST_LineMerge(ST_Collect(sa.path_geom, sb.path_geom))
        END AS geom,
        sa.path_osm_type AS osm_type,
        sa.path_id AS osm_id,
        COALESCE(sa.path_width, sb.path_width) AS width,
        COALESCE(sa.path_layer, sb.path_layer) AS layer,
        COALESCE(sa.path_surface, sb.path_surface) AS surface,
        COALESCE(sa.path_crossing, sb.path_crossing) AS eff_crossing,
        COALESCE(sa.path_crossing_markings, sb.path_crossing_markings) AS eff_crossing_markings,
        COALESCE(sa.path_crossing_ref, sb.path_crossing_ref) AS eff_crossing_ref,
        COALESCE(sa.path_class, sb.path_class) AS eff_class,
        COALESCE(sa.path_highway, sb.path_highway) AS source_highway,
        (
            COALESCE(sa.node_temporary, '') = 'yes'
            OR COALESCE(sb.node_temporary, '') = 'yes'
            OR COALESCE(sa.path_temporary, '') = 'yes'
            OR COALESCE(sb.path_temporary, '') = 'yes'
        ) AS is_temporary
    FROM both_sides bs
    JOIN side_a sa ON sa.crossing_id = bs.crossing_id
    JOIN side_b sb ON sb.crossing_id = bs.crossing_id
),
way_lines_dumped AS (
    SELECT
        wl.*,
        (d.geom)::geometry(LineString) AS line_geom
    FROM way_lines wl
    CROSS JOIN LATERAL ST_Dump(wl.geom) AS d
    WHERE wl.geom IS NOT NULL
      AND NOT ST_IsEmpty(wl.geom)
      AND ST_GeometryType((d.geom)) = 'ST_LineString'
      AND ST_Length((d.geom)) > metres(0.01)
)
SELECT
    wld.crossing_id,
    wld.crossing_geom AS anchor_geom,
    'crossing_way'::text AS source,
    wld.osm_type,
    wld.osm_id,
    wld.line_geom AS geom,
    CASE
        WHEN COALESCE(wld.eff_crossing, wld.node_crossing, '') = 'zebra'
          OR COALESCE(wld.eff_crossing_ref, wld.node_crossing_ref, '') = 'zebra'
          OR COALESCE(wld.eff_crossing_ref, wld.node_crossing_ref, '') LIKE 'zebra%'
          OR COALESCE(wld.eff_crossing_markings, wld.node_crossing_markings, '') = 'zebra'
          OR COALESCE(wld.eff_crossing_markings, wld.node_crossing_markings, '') LIKE 'zebra%'
          OR COALESCE(wld.eff_crossing_markings, wld.node_crossing_markings, '') = 'ladder'
          OR COALESCE(wld.eff_crossing_markings, wld.node_crossing_markings, '') LIKE 'ladder%'
        THEN COALESCE(
            NULLIF(wld.width, :'crossing_default_width'::double precision),
            :'crossing_default_width_zebra'::double precision
        )
        ELSE COALESCE(wld.width, :'crossing_default_width'::double precision)
    END AS width,
    wld.layer,
    wld.surface,
    COALESCE(wld.eff_crossing, wld.node_crossing) AS eff_crossing,
    COALESCE(wld.eff_crossing_markings, wld.node_crossing_markings) AS eff_crossing_markings,
    COALESCE(wld.eff_crossing_ref, wld.node_crossing_ref) AS eff_crossing_ref,
    wld.eff_class,
    wld.node_buffer_marking AS eff_buffer_marking,
    wld.source_highway,
    wld.is_temporary
FROM way_lines_dumped wld

UNION ALL

SELECT
    cf.osm_id AS crossing_id,
    cf.geom AS anchor_geom,
    'crossing_generic'::text AS source,
    cf.osm_type,
    cf.osm_id,
    -- crossing axis (perpendicular to the road) = road_azimuth + 90°
    ST_MakeLine(
        ST_Project(
            cf.geom,
            metres((rw.crossing_width / 2.0) + 1.0),
            RADIANS(cf.road_azimuth) + pi() / 2
        ),
        ST_Project(
            cf.geom,
            metres((rw.crossing_width / 2.0) + 1.0),
            RADIANS(cf.road_azimuth) + pi() / 2 + pi()
        )
    ) AS geom,
    rw.crossing_width AS width,
    NULL::integer AS layer,
    NULL::text AS surface,
    cf."crossing" AS eff_crossing,
    cf."crossing:markings" AS eff_crossing_markings,
    cf."crossing_ref" AS eff_crossing_ref,
    NULL::text AS eff_class,
    cf."crossing:buffer_marking" AS eff_buffer_marking,
    NULL::text AS source_highway,
    (COALESCE(cf.temporary, '') = 'yes') AS is_temporary
FROM crossing_filtered cf
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN COALESCE(cf."crossing", '') = 'zebra'
              OR COALESCE(cf."crossing_ref", '') = 'zebra'
              OR COALESCE(cf."crossing_ref", '') LIKE 'zebra%'
              OR COALESCE(cf."crossing:markings", '') = 'zebra'
              OR COALESCE(cf."crossing:markings", '') LIKE 'zebra%'
              OR COALESCE(cf."crossing:markings", '') = 'ladder'
              OR COALESCE(cf."crossing:markings", '') LIKE 'ladder%'
            THEN COALESCE(
                NULLIF(
                    (
                        SELECT MAX(hp.width)
                        FROM highway hp
                        WHERE hp.type = 'path'
                          AND hp.geom && cf.geom
                          AND ST_Intersects(hp.geom, cf.geom)
                          AND hp.width IS NOT NULL
                    ),
                    :'crossing_default_width'::double precision
                ),
                :'crossing_default_width_zebra'::double precision
            )
            ELSE COALESCE(
                (
                    SELECT MAX(hp.width)
                    FROM highway hp
                    WHERE hp.type = 'path'
                      AND hp.geom && cf.geom
                      AND ST_Intersects(hp.geom, cf.geom)
                      AND hp.width IS NOT NULL
                ),
                :'crossing_default_width'::double precision
            )
        END AS crossing_width
) rw
WHERE cf.road_azimuth IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM both_sides bs WHERE bs.crossing_id = cf.osm_id
  );

CREATE INDEX crossing_node_centerlines_geom_idx
    ON crossing_node_centerlines USING GIST (geom);
CREATE INDEX crossing_node_centerlines_crossing_id_idx
    ON crossing_node_centerlines (crossing_id);


----------------------------------------------------------------------
-- §4) Tagged path ways without a crossing node
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_way_only_centerlines;
CREATE TABLE crossing_way_only_centerlines AS
SELECT
    h.osm_id AS crossing_id,
    ST_LineInterpolatePoint(h.geom, 0.5) AS anchor_geom,
    'crossing_way'::text AS source,
    h.osm_type,
    h.osm_id,
    h.geom,
    COALESCE(
        h.width,
        CASE
            WHEN COALESCE(h."crossing", '') = 'zebra'
              OR COALESCE(h."crossing_ref", '') = 'zebra'
              OR COALESCE(h."crossing:markings", '') = 'zebra'
              OR COALESCE(h."crossing:markings", '') LIKE 'zebra%'
              OR COALESCE(h."crossing:markings", '') = 'ladder'
              OR COALESCE(h."crossing:markings", '') LIKE 'ladder%'
            THEN :'crossing_default_width_zebra'::double precision
            ELSE :'crossing_default_width'::double precision
        END
    ) AS width,
    h.layer,
    h.surface,
    h."crossing" AS eff_crossing,
    h."crossing:markings" AS eff_crossing_markings,
    h."crossing_ref" AS eff_crossing_ref,
    h.class AS eff_class,
    NULL::text AS eff_buffer_marking,
    h.highway AS source_highway,
    (COALESCE(h.temporary, '') = 'yes') AS is_temporary
FROM highway h
WHERE h.type = 'path'
  AND NOT EXISTS (
      SELECT 1
      FROM crossing_filtered c
      WHERE c.geom && h.geom
        AND ST_Intersects(c.geom, h.geom)
  )
  AND (
      h."crossing" IN ('traffic_signals', 'marked', 'zebra')
      OR (
          h."crossing:markings" IS NOT NULL
          AND h."crossing:markings" NOT IN ('no', 'surface')
      )
      OR (
          h."crossing_ref" IS NOT NULL
          AND h."crossing_ref" NOT IN ('no', 'none')
      )
  );

CREATE INDEX crossing_way_only_centerlines_geom_idx
    ON crossing_way_only_centerlines USING GIST (geom);


----------------------------------------------------------------------
-- §4b) Merge connected crossing path centerlines (before extend)
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_merge_segments;
CREATE TABLE crossing_merge_segments AS
WITH segments_base AS (
    SELECT *
    FROM crossing_node_centerlines
    WHERE source = 'crossing_way'
    UNION ALL
    SELECT *
    FROM crossing_way_only_centerlines
),
segments_marked AS (
    SELECT
        s.*,
        (
            COALESCE(s.eff_crossing, '') = 'zebra'
            OR COALESCE(s.eff_crossing_ref, '') = 'zebra'
            OR COALESCE(s.eff_crossing_markings, '') = 'zebra'
            OR COALESCE(s.eff_crossing_markings, '') LIKE 'zebra%'
        ) AS merge_is_zebra,
        (
            COALESCE(s.eff_crossing_markings, '') IN ('ladder', 'pictograms')
            OR COALESCE(s.eff_crossing_markings, '') LIKE 'ladder%'
            OR COALESCE(s.eff_crossing_markings, '') LIKE 'pictograms%'
        ) AS merge_is_ladder_pictograms
    FROM segments_base s
    WHERE s.geom IS NOT NULL
      AND NOT ST_IsEmpty(s.geom)
      AND ST_GeometryType(s.geom) = 'ST_LineString'
      AND ST_NPoints(s.geom) >= 2
)
SELECT
    row_number() OVER ()::bigint AS seg_id,
    sm.crossing_id,
    sm.anchor_geom,
    sm.source,
    sm.osm_type,
    sm.osm_id,
    sm.geom,
    sm.width,
    sm.layer,
    sm.surface,
    sm.eff_crossing,
    sm.eff_crossing_markings,
    sm.eff_crossing_ref,
    sm.eff_class,
    sm.eff_buffer_marking,
    sm.source_highway,
    sm.is_temporary,
    sm.merge_is_zebra,
    sm.merge_is_ladder_pictograms,
    CASE
        WHEN sm.merge_is_zebra OR sm.merge_is_ladder_pictograms THEN 'centerline'::text
        WHEN sm.eff_buffer_marking IS NOT NULL
             AND NOT (
                 sm.merge_is_zebra
                 OR sm.merge_is_ladder_pictograms
                 OR sm.eff_crossing IN ('traffic_signals', 'marked', 'zebra')
                 OR (
                     sm.eff_crossing_markings IS NOT NULL
                     AND sm.eff_crossing_markings NOT IN ('no', 'surface')
                 )
             )
        THEN 'side'::text
        WHEN (
            sm.eff_crossing IN ('traffic_signals', 'marked', 'zebra')
            OR (
                sm.eff_crossing_markings IS NOT NULL
                AND sm.eff_crossing_markings NOT IN ('no', 'surface')
            )
            OR sm.eff_buffer_marking IS NOT NULL
        )
        AND NOT EXISTS (
            SELECT 1
            FROM crossing c
            WHERE c.osm_id = sm.crossing_id
              AND c."crossing:markings" = 'surface'
        )
        THEN 'edge'::text
        ELSE NULL::text
    END AS merge_marking_kind,
    CASE
        WHEN sm.merge_is_zebra THEN 'zebra'::text
        WHEN COALESCE(sm.eff_crossing_markings, '') LIKE 'ladder%'
          OR sm.eff_crossing_markings = 'ladder' THEN 'ladder'::text
        WHEN COALESCE(sm.eff_crossing_markings, '') LIKE 'pictograms%'
          OR sm.eff_crossing_markings = 'pictograms' THEN 'pictograms'::text
        WHEN sm.eff_crossing_markings = 'dots' THEN 'dots'::text
        WHEN sm.eff_crossing_markings = 'dashes' THEN 'dashed'::text
        WHEN sm.eff_crossing_markings = 'lines' THEN 'solid'::text
        WHEN sm.eff_crossing_markings = 'lines:paired' THEN 'double_solid'::text
        WHEN sm.eff_crossing IN ('traffic_signals', 'marked') THEN 'dashed'::text
        ELSE NULL::text
    END AS merge_stroke,
    CASE
        WHEN sm.source_highway = 'cycleway' THEN 'bicycle'::text
        ELSE NULL::text
    END AS merge_marking_type,
    ST_Azimuth(ST_StartPoint(sm.geom), ST_EndPoint(sm.geom)) AS line_azimuth,
    EXISTS (
        SELECT 1
        FROM crossing_filtered c
        WHERE ST_Intersects(c.geom, ST_StartPoint(sm.geom))
           OR ST_Intersects(c.geom, ST_EndPoint(sm.geom))
    ) AS has_node_touch
FROM segments_marked sm;

CREATE INDEX crossing_merge_segments_geom_idx
    ON crossing_merge_segments USING GIST (geom);
CREATE INDEX crossing_merge_segments_seg_id_idx
    ON crossing_merge_segments (seg_id);

DROP TABLE IF EXISTS crossing_centerlines_merged;
CREATE TABLE crossing_centerlines_merged AS
WITH RECURSIVE
merge_pairs AS (
    SELECT
        a.seg_id AS id_a,
        b.seg_id AS id_b
    FROM crossing_merge_segments a
    INNER JOIN crossing_merge_segments b
        ON a.seg_id < b.seg_id
       AND a.layer IS NOT DISTINCT FROM b.layer
       AND a.merge_marking_kind IS NOT DISTINCT FROM b.merge_marking_kind
       AND a.merge_stroke IS NOT DISTINCT FROM b.merge_stroke
       AND a.merge_marking_type IS NOT DISTINCT FROM b.merge_marking_type
       AND a.eff_buffer_marking IS NOT DISTINCT FROM b.eff_buffer_marking
       AND a.is_temporary IS NOT DISTINCT FROM b.is_temporary
       AND LEAST(
               ABS(a.line_azimuth - b.line_azimuth),
               pi() - ABS(a.line_azimuth - b.line_azimuth)
           ) <= RADIANS(:'crossing_merge_angle_tolerance'::double precision)
       AND (
           ST_Equals(ST_StartPoint(a.geom), ST_StartPoint(b.geom))
        OR ST_Equals(ST_StartPoint(a.geom), ST_EndPoint(b.geom))
        OR ST_Equals(ST_EndPoint(a.geom), ST_StartPoint(b.geom))
        OR ST_Equals(ST_EndPoint(a.geom), ST_EndPoint(b.geom))
       )
),
merge_edges AS (
    SELECT id_a AS node, id_b AS neighbor FROM merge_pairs
    UNION ALL
    SELECT id_b, id_a FROM merge_pairs
),
walk AS (
    SELECT seg_id AS node, seg_id AS root
    FROM crossing_merge_segments
    UNION
    SELECT e.neighbor, w.root
    FROM walk w
    INNER JOIN merge_edges e ON w.node = e.node
),
comp AS (
    SELECT node, MIN(root) AS cluster_id
    FROM walk
    GROUP BY node
),
cluster_members AS (
    SELECT
        c.cluster_id,
        s.crossing_id,
        s.anchor_geom,
        s.source,
        s.osm_type,
        s.osm_id,
        s.geom,
        s.width,
        s.layer,
        s.surface,
        s.eff_crossing,
        s.eff_crossing_markings,
        s.eff_crossing_ref,
        s.eff_class,
        s.eff_buffer_marking,
        s.source_highway,
        s.is_temporary,
        s.has_node_touch
    FROM crossing_merge_segments s
    INNER JOIN comp c ON s.seg_id = c.node
),
attr_winners AS (
    SELECT DISTINCT ON (cluster_id)
        cluster_id,
        crossing_id,
        anchor_geom,
        source,
        osm_type,
        osm_id,
        width,
        layer,
        surface,
        eff_crossing,
        eff_crossing_markings,
        eff_crossing_ref,
        eff_class,
        eff_buffer_marking,
        source_highway
    FROM cluster_members
    ORDER BY
        cluster_id,
        has_node_touch DESC,
        ST_Length(geom) DESC,
        crossing_id
),
merged_geom AS (
    SELECT
        cluster_id,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS geom
    FROM cluster_members
    GROUP BY cluster_id
)
SELECT
    aw.crossing_id,
    aw.anchor_geom,
    aw.source,
    aw.osm_type,
    aw.osm_id,
    (d.geom)::geometry(LineString) AS geom,
    aw.width,
    aw.layer,
    aw.surface,
    aw.eff_crossing,
    aw.eff_crossing_markings,
    aw.eff_crossing_ref,
    aw.eff_class,
    aw.eff_buffer_marking,
    aw.source_highway,
    (
        SELECT bool_or(cm.is_temporary)
        FROM cluster_members cm
        WHERE cm.cluster_id = aw.cluster_id
    ) AS is_temporary
FROM attr_winners aw
INNER JOIN merged_geom mg
  ON mg.cluster_id = aw.cluster_id
CROSS JOIN LATERAL ST_Dump(mg.geom) AS d
WHERE mg.geom IS NOT NULL
  AND NOT ST_IsEmpty(mg.geom)
  AND ST_GeometryType((d.geom)) = 'ST_LineString'
  AND ST_Length((d.geom)) > metres(0.01);

CREATE INDEX crossing_centerlines_merged_geom_idx
    ON crossing_centerlines_merged USING GIST (geom);


DROP TABLE IF EXISTS crossing_centerlines_raw;
CREATE TABLE crossing_centerlines_raw AS
SELECT
    crossing_id,
    anchor_geom,
    source,
    osm_type,
    osm_id,
    geom,
    width,
    layer,
    surface,
    eff_crossing,
    eff_crossing_markings,
    eff_crossing_ref,
    eff_class,
    eff_buffer_marking,
    source_highway,
    is_temporary
FROM crossing_centerlines_merged
UNION ALL
SELECT
    crossing_id,
    anchor_geom,
    source,
    osm_type,
    osm_id,
    geom,
    width,
    layer,
    surface,
    eff_crossing,
    eff_crossing_markings,
    eff_crossing_ref,
    eff_class,
    eff_buffer_marking,
    source_highway,
    is_temporary
FROM crossing_node_centerlines
WHERE source = 'crossing_generic';

CREATE INDEX crossing_centerlines_raw_geom_idx
    ON crossing_centerlines_raw USING GIST (geom);


----------------------------------------------------------------------
-- §5) Extend both ends by crossing_extend metres.
--     geom_extended: skipped for kerb-bounded centerlines (§7 centerline rendering).
--     geom_extended_edges: extended for crossing_edge offsets (all sources).
--     Exception (same as road_marking_crossing_edge.sql §2b): bicycle crossing
--     centreline with a matching lanes row skips extend at an end when the
--     connected prev/next bicycle lane has marking_left or marking_right
--     not in (NULL, 'no', 'none').
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_centerlines_extended;
CREATE TABLE crossing_centerlines_extended AS
SELECT
    ccr.*,
    dumped.line_geom,
    dumped.is_kerb_bounded,
    ST_LineExtend(
        dumped.line_geom,
        CASE
            WHEN lane_match.lane_osm_id IS NULL THEN
                metres(:'crossing_extend'::double precision)
            WHEN lane_match.direction = 'backward' THEN
                CASE
                    WHEN lane_match.block_extend_entry THEN 0.0
                    ELSE metres(:'crossing_extend'::double precision)
                END
            ELSE
                CASE
                    WHEN lane_match.block_extend_exit THEN 0.0
                    ELSE metres(:'crossing_extend'::double precision)
                END
        END,
        CASE
            WHEN lane_match.lane_osm_id IS NULL THEN
                metres(:'crossing_extend'::double precision)
            WHEN lane_match.direction = 'backward' THEN
                CASE
                    WHEN lane_match.block_extend_exit THEN 0.0
                    ELSE metres(:'crossing_extend'::double precision)
                END
            ELSE
                CASE
                    WHEN lane_match.block_extend_entry THEN 0.0
                    ELSE metres(:'crossing_extend'::double precision)
                END
        END
    ) AS geom_extended_edges,
    CASE
        WHEN dumped.is_kerb_bounded THEN dumped.line_geom
        ELSE ST_LineExtend(
            dumped.line_geom,
            metres(:'crossing_extend'::double precision),
            metres(:'crossing_extend'::double precision)
        )
    END AS geom_extended
FROM crossing_centerlines_raw ccr
CROSS JOIN LATERAL (
    SELECT
        (d.geom)::geometry(LineString) AS line_geom,
        (
            EXISTS (
                SELECT 1
                FROM barrier_node bn
                WHERE bn.barrier = 'kerb'
                  AND ST_Intersects(bn.geom, ST_StartPoint((d.geom)::geometry(LineString)))
            )
            AND EXISTS (
                SELECT 1
                FROM barrier_node bn
                WHERE bn.barrier = 'kerb'
                  AND ST_Intersects(bn.geom, ST_EndPoint((d.geom)::geometry(LineString)))
            )
        ) AS is_kerb_bounded
    FROM ST_Dump(ccr.geom) AS d
    WHERE ccr.geom IS NOT NULL
      AND NOT ST_IsEmpty(ccr.geom)
      AND ST_GeometryType((d.geom)) = 'ST_LineString'
      AND ST_Length((d.geom)) > metres(0.01)
) dumped
LEFT JOIN LATERAL (
    SELECT
        l.osm_id AS lane_osm_id,
        l.direction,
        (
            l.type = 'bicycle'
            AND l.class = 'crossing'
            AND l_prev.type = 'bicycle'
            AND (
                (
                    l_prev.marking_left IS NOT NULL
                    AND l_prev.marking_left NOT IN ('no', 'none')
                )
                OR (
                    l_prev.marking_right IS NOT NULL
                    AND l_prev.marking_right NOT IN ('no', 'none')
                )
            )
        ) AS block_extend_entry,
        (
            l.type = 'bicycle'
            AND l.class = 'crossing'
            AND l_next.type = 'bicycle'
            AND (
                (
                    l_next.marking_left IS NOT NULL
                    AND l_next.marking_left NOT IN ('no', 'none')
                )
                OR (
                    l_next.marking_right IS NOT NULL
                    AND l_next.marking_right NOT IN ('no', 'none')
                )
            )
        ) AS block_extend_exit
    FROM lanes l
    LEFT JOIN lanes l_prev
      ON l_prev.segment_id = l.prev_segment_id
     AND l_prev.lane_index = l.prev_lane_index
    LEFT JOIN lanes l_next
      ON l_next.segment_id = l.next_segment_id
     AND l_next.lane_index = l.next_lane_index
    WHERE l.osm_id = ccr.osm_id
      AND l.class = 'crossing'
      AND l.type = 'bicycle'
      AND ccr.source = 'crossing_way'
    ORDER BY ST_Length(ST_Intersection(l.geom, dumped.line_geom)) DESC NULLS LAST,
             ST_Length(l.geom) DESC,
             l.lane_index
    LIMIT 1
) lane_match ON true;

CREATE INDEX crossing_centerlines_extended_geom_idx
    ON crossing_centerlines_extended USING GIST (geom_extended);


----------------------------------------------------------------------
-- §6) Marking kind and stroke
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_centerlines_marked;
CREATE TABLE crossing_centerlines_marked AS
SELECT
    cce.*,
    (
        COALESCE(cce.eff_crossing, '') = 'zebra'
        OR COALESCE(cce.eff_crossing_ref, '') = 'zebra'
        OR COALESCE(cce.eff_crossing_markings, '') = 'zebra'
        OR COALESCE(cce.eff_crossing_markings, '') LIKE 'zebra%'
    ) AS is_zebra,
    (
        COALESCE(cce.eff_crossing_markings, '') IN ('ladder', 'pictograms')
        OR COALESCE(cce.eff_crossing_markings, '') LIKE 'ladder%'
        OR COALESCE(cce.eff_crossing_markings, '') LIKE 'pictograms%'
    ) AS is_ladder_pictograms
FROM crossing_centerlines_extended cce;

DROP TABLE IF EXISTS crossing_centerlines_typed;
CREATE TABLE crossing_centerlines_typed AS
SELECT
    ccm.*,
    CASE
        WHEN ccm.is_zebra OR ccm.is_ladder_pictograms THEN 'centerline'::text
        WHEN ccm.eff_buffer_marking IS NOT NULL
             AND NOT (
                 ccm.is_zebra
                 OR ccm.is_ladder_pictograms
                 OR ccm.eff_crossing IN ('traffic_signals', 'marked', 'zebra')
                 OR (
                     ccm.eff_crossing_markings IS NOT NULL
                     AND ccm.eff_crossing_markings NOT IN ('no', 'surface')
                 )
             )
        THEN 'side'::text
        WHEN (
            ccm.eff_crossing IN ('traffic_signals', 'marked', 'zebra')
            OR (
                ccm.eff_crossing_markings IS NOT NULL
                AND ccm.eff_crossing_markings NOT IN ('no', 'surface')
            )
            OR ccm.eff_buffer_marking IS NOT NULL
        )
        AND NOT EXISTS (
            SELECT 1
            FROM crossing c
            WHERE c.osm_id = ccm.crossing_id
              AND c."crossing:markings" = 'surface'
        )
        THEN 'edge'::text
        ELSE NULL::text
    END AS marking_kind,
    CASE
        WHEN ccm.is_zebra THEN 'zebra'::text
        WHEN COALESCE(ccm.eff_crossing_markings, '') LIKE 'ladder%'
          OR ccm.eff_crossing_markings = 'ladder' THEN 'ladder'::text
        WHEN COALESCE(ccm.eff_crossing_markings, '') LIKE 'pictograms%'
          OR ccm.eff_crossing_markings = 'pictograms' THEN 'pictograms'::text
        WHEN ccm.eff_crossing_markings = 'dots' THEN 'dots'::text
        WHEN ccm.eff_crossing_markings = 'dashes' THEN 'dashed'::text
        WHEN ccm.eff_crossing_markings = 'lines' THEN 'solid'::text
        WHEN ccm.eff_crossing_markings = 'lines:paired' THEN 'double_solid'::text
        WHEN ccm.eff_crossing IN ('traffic_signals', 'marked') THEN 'dashed'::text
        ELSE NULL::text
    END AS stroke_raw,
    CASE
        WHEN ccm.source_highway = 'cycleway' THEN 'bicycle'::text
        ELSE NULL::text
    END AS marking_type
FROM crossing_centerlines_marked ccm;

DROP TABLE IF EXISTS crossing_marking_lines_pre_clip;
CREATE TABLE crossing_marking_lines_pre_clip AS

SELECT
    cct.source,
    'crossing'::text AS road_marking,
    cct.osm_type,
    cct.osm_id,
    cct.stroke_raw AS stroke,
    cct.width,
    cct.layer,
    cct.crossing_id,
    cct.anchor_geom,
    cct.geom_extended::geometry(LineString) AS centerline_geom,
    ST_LineLocatePoint(
        cct.geom_extended::geometry(LineString),
        cct.anchor_geom
    ) AS anchor_frac,
    cct.geom_extended AS geom,
    cct.marking_type,
    cct.is_temporary,
    cct.is_kerb_bounded
FROM crossing_centerlines_typed cct
WHERE cct.marking_kind = 'centerline'
  AND cct.stroke_raw IS NOT NULL

UNION ALL

SELECT
    cct.source,
    'crossing_edge'::text AS road_marking,
    cct.osm_type,
    cct.osm_id,
    COALESCE(cct.stroke_raw, 'dashed'::text) AS stroke,
    CASE
        WHEN cct.marking_type = 'bicycle'
        THEN :'wide_stroke_width'::real
        ELSE :'narrow_stroke_width'::real
    END AS width,
    cct.layer,
    cct.crossing_id,
    cct.anchor_geom,
    cct.geom_extended_edges::geometry(LineString) AS centerline_geom,
    ST_LineLocatePoint(
        cct.geom_extended_edges::geometry(LineString),
        cct.anchor_geom
    ) AS anchor_frac,
    line_offset(cct.geom_extended_edges::geometry(LineString), cct.width / 2.0)::geometry AS geom,
    cct.marking_type,
    cct.is_temporary,
    cct.is_kerb_bounded
FROM crossing_centerlines_typed cct
WHERE cct.marking_kind = 'edge'
  AND NOT EXISTS (
      SELECT 1
      FROM road_marking_way rmw
      WHERE rmw.road_marking = 'crossing_edge'
        AND rmw.source = 'osm_feature'
        AND (cct.layer IS NULL OR rmw.layer IS NOT DISTINCT FROM cct.layer)
        AND rmw.geom && ST_Expand(
            cct.anchor_geom,
            metres(cct.width + :'crossing_edge_osm_skip_extra'::double precision)
        )
        AND ST_DWithin(
            cct.anchor_geom,
            rmw.geom,
            metres(cct.width + :'crossing_edge_osm_skip_extra'::double precision)
        )
  )

UNION ALL

SELECT
    cct.source,
    'crossing_edge'::text AS road_marking,
    cct.osm_type,
    cct.osm_id,
    COALESCE(cct.stroke_raw, 'dashed'::text) AS stroke,
    CASE
        WHEN cct.marking_type = 'bicycle'
        THEN :'wide_stroke_width'::real
        ELSE :'narrow_stroke_width'::real
    END AS width,
    cct.layer,
    cct.crossing_id,
    cct.anchor_geom,
    cct.geom_extended_edges::geometry(LineString) AS centerline_geom,
    ST_LineLocatePoint(
        cct.geom_extended_edges::geometry(LineString),
        cct.anchor_geom
    ) AS anchor_frac,
    line_offset(cct.geom_extended_edges::geometry(LineString), -(cct.width / 2.0))::geometry AS geom,
    cct.marking_type,
    cct.is_temporary,
    cct.is_kerb_bounded
FROM crossing_centerlines_typed cct
WHERE cct.marking_kind = 'edge'
  AND NOT EXISTS (
      SELECT 1
      FROM road_marking_way rmw
      WHERE rmw.road_marking = 'crossing_edge'
        AND rmw.source = 'osm_feature'
        AND (cct.layer IS NULL OR rmw.layer IS NOT DISTINCT FROM cct.layer)
        AND rmw.geom && ST_Expand(
            cct.anchor_geom,
            metres(cct.width + :'crossing_edge_osm_skip_extra'::double precision)
        )
        AND ST_DWithin(
            cct.anchor_geom,
            rmw.geom,
            metres(cct.width + :'crossing_edge_osm_skip_extra'::double precision)
        )
  );

CREATE INDEX crossing_marking_lines_pre_clip_geom_idx
    ON crossing_marking_lines_pre_clip USING GIST (geom);


\i 'processing/sql/helper/highway_road_area.sql'


----------------------------------------------------------------------
-- §7) Clip at carriageway boundary; keep fragment on the lane (fragments within crossing_anchor_window from centerline).
--     highway_area: only road carriageways (_highway_road_area), not footway/path polygons.
--     Kerb-bounded centerlines (barrier=kerb at both ends): no extend, no highway_area clip.
----------------------------------------------------------------------

DROP TABLE IF EXISTS crossing_marking_lines_clipped;
CREATE TABLE crossing_marking_lines_clipped AS

-- §7a) Kerb-bounded centerlines: use pre-clip geometry as-is
SELECT
    cm.source,
    cm.road_marking,
    cm.osm_type,
    cm.osm_id,
    cm.stroke,
    cm.width,
    cm.layer,
    cm.crossing_id,
    cm.anchor_geom,
    cm.geom::geometry(LineString) AS geom,
    cm.marking_type,
    cm.is_temporary
FROM crossing_marking_lines_pre_clip cm
CROSS JOIN LATERAL (
    SELECT
        metres(:'crossing_anchor_window'::double precision)
        / NULLIF(ST_Length(cm.centerline_geom), 0) AS w_frac
) ref
WHERE cm.is_kerb_bounded
  AND cm.road_marking = 'crossing'
  AND cm.geom IS NOT NULL
  AND NOT ST_IsEmpty(cm.geom)
  AND ST_GeometryType(cm.geom) = 'ST_LineString'
  AND ST_Length(cm.geom) >= metres(:'crossing_min_length'::double precision)
  AND ref.w_frac IS NOT NULL
  AND (
      EXISTS (
          SELECT 1
          FROM crossing_filtered cf
          WHERE ST_Intersects(cf.geom, cm.centerline_geom)
            AND 1.0 >= ST_LineLocatePoint(cm.centerline_geom, cf.geom) - ref.w_frac
            AND 0.0 <= ST_LineLocatePoint(cm.centerline_geom, cf.geom) + ref.w_frac
      )
      OR (
          cm.anchor_frac IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM crossing_filtered cf
              WHERE ST_Intersects(cf.geom, cm.centerline_geom)
          )
          AND 1.0 >= cm.anchor_frac - ref.w_frac
          AND 0.0 <= cm.anchor_frac + ref.w_frac
      )
  )

UNION ALL

-- §7b) All other markings: clip at highway_area boundary
SELECT
    cm.source,
    cm.road_marking,
    cm.osm_type,
    cm.osm_id,
    cm.stroke,
    cm.width,
    cm.layer,
    cm.crossing_id,
    cm.anchor_geom,
    (frag).geom::geometry(LineString) AS geom,
    cm.marking_type,
    cm.is_temporary
FROM crossing_marking_lines_pre_clip cm
CROSS JOIN LATERAL (
    SELECT ST_Buffer(ST_Union(ha.geom), 0) AS union_geom
    FROM highway_area ha
    WHERE ha.geom && cm.geom
      AND ST_Intersects(ha.geom, cm.geom)
      AND (cm.layer IS NULL OR ha.layer IS NOT DISTINCT FROM cm.layer)
      AND EXISTS (
          SELECT 1
          FROM _highway_road_area rh
          WHERE rh.area_highway = ha."area:highway"
      )
) areas
CROSS JOIN LATERAL ST_Dump(
    ST_Intersection(
        cm.geom,
        areas.union_geom
    )
) AS frag
CROSS JOIN LATERAL (
    SELECT
        LEAST(
            ST_LineLocatePoint(
                cm.centerline_geom,
                ST_ClosestPoint(cm.centerline_geom, ST_StartPoint((frag).geom))
            ),
            ST_LineLocatePoint(
                cm.centerline_geom,
                ST_ClosestPoint(cm.centerline_geom, ST_EndPoint((frag).geom))
            )
        ) AS frag_cl_min,
        GREATEST(
            ST_LineLocatePoint(
                cm.centerline_geom,
                ST_ClosestPoint(cm.centerline_geom, ST_StartPoint((frag).geom))
            ),
            ST_LineLocatePoint(
                cm.centerline_geom,
                ST_ClosestPoint(cm.centerline_geom, ST_EndPoint((frag).geom))
            )
        ) AS frag_cl_max
) fb
CROSS JOIN LATERAL (
    SELECT
        metres(:'crossing_anchor_window'::double precision)
        / NULLIF(ST_Length(cm.centerline_geom), 0) AS w_frac
) ref
WHERE NOT (cm.is_kerb_bounded AND cm.road_marking = 'crossing')
  AND areas.union_geom IS NOT NULL
  AND NOT ST_IsEmpty(areas.union_geom)
  AND (frag).geom IS NOT NULL
  AND NOT ST_IsEmpty((frag).geom)
  AND ST_GeometryType((frag).geom) = 'ST_LineString'
  AND ST_Length((frag).geom) >= metres(:'crossing_min_length'::double precision)
  AND ref.w_frac IS NOT NULL
  AND (
      EXISTS (
          SELECT 1
          FROM crossing_filtered cf
          WHERE ST_Intersects(cf.geom, cm.centerline_geom)
            AND fb.frag_cl_max >= ST_LineLocatePoint(cm.centerline_geom, cf.geom) - ref.w_frac
            AND fb.frag_cl_min <= ST_LineLocatePoint(cm.centerline_geom, cf.geom) + ref.w_frac
      )
      OR (
          cm.anchor_frac IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM crossing_filtered cf
              WHERE ST_Intersects(cf.geom, cm.centerline_geom)
          )
          AND fb.frag_cl_max >= cm.anchor_frac - ref.w_frac
          AND fb.frag_cl_min <= cm.anchor_frac + ref.w_frac
      )
  );

CREATE INDEX crossing_marking_lines_clipped_geom_idx
    ON crossing_marking_lines_clipped USING GIST (geom);

----------------------------------------------------------------------
-- §7.6) Stripe polygons for zebra/ladder crossings (see helper/crossing_stripe_polygons.sql)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_stripe_input;
CREATE TEMP TABLE _crossing_stripe_input AS
SELECT
    cml.source,
    cml.osm_type,
    cml.osm_id,
    cml.stroke,
    cml.width,
    cml.layer,
    cml.crossing_id,
    cml.geom AS crossing_geom,
    cml.is_temporary,
    cf.road_azimuth
FROM crossing_marking_lines_clipped cml
LEFT JOIN crossing_filtered cf
    ON cf.osm_id = cml.crossing_id
WHERE cml.road_marking = 'crossing'
  AND cml.stroke IN ('zebra', 'ladder')
  AND cml.geom IS NOT NULL
  AND NOT ST_IsEmpty(cml.geom)
  AND ST_GeometryType(cml.geom) = 'ST_LineString'
  AND cml.width IS NOT NULL
  AND cml.width > 0.01
  AND ST_Length(cml.geom) >= metres(:'crossing_stripe_width'::double precision);

\i 'processing/sql/helper/crossing_stripe_polygons.sql'

DROP TABLE IF EXISTS crossing_stripe_polygons;
CREATE TEMP TABLE crossing_stripe_polygons AS
SELECT * FROM _crossing_stripe_polygons;

DROP TABLE IF EXISTS _crossing_stripe_input;
DROP TABLE IF EXISTS _crossing_stripe_polygons;


----------------------------------------------------------------------
-- §7.5) Clip zones: remove generic lane markings inside crossing areas
--       (before §8 INSERT). OSM crossings: centerline/edge only (not side-only buffer_marking).
--       Lane crossings: lanes_clipped.class = 'crossing' (no OSM crossing node required).
--       Zone geometry: buffer the crossing centerline extended by crossing_extend.
--       For edge-only crossings use geom_extended_edges (respects bicycle lane
--       extend blocks at prev/next marked cycleway lanes); centerline crossings
--       always use full crossing_extend on line_geom (also kerb-bounded).
--       only polygon fragments that contain an anchor point (crossing node on the way, or
--       primary crossing_id / way midpoint for ways without a node).
--       Exceptions when clipping ways: osm_feature%, stop_line, road_marking_restriction%,
--       surface_colour. Polygons: barred_area at all zones; surface_colour at foreign
--       crossing zones only (zone osm_id != polygon osm_id).
--       source=crossing_way + crossing_edge: clip at other crossings' zones only (§7.5b, §8b).
--       Asymmetric clip: bicycle crossing_edge at all foreign zones; footway/path only at non-bicycle zones.
----------------------------------------------------------------------

DROP TABLE IF EXISTS _clip_zones_diff;
DROP TABLE IF EXISTS crossing_clip_zones_by_crossing;
DROP TABLE IF EXISTS crossing_clip_zones;

DROP TABLE IF EXISTS _crossing_clip_zone_fragments;
CREATE TABLE _crossing_clip_zone_fragments AS
WITH per_crossing AS (
    SELECT
        cce.crossing_id,
        cce.osm_id,
        cce.layer,
        cce.width,
        cce.anchor_geom,
        cce.geom,
        cce.line_geom,
        cce.marking_kind,
        cce.geom_extended_edges,
        cce.source_highway,
        CASE
            WHEN cce.source_highway = 'cycleway' THEN 'bicycle'::text
            ELSE NULL::text
        END AS crossing_type,
        EXISTS (
            SELECT 1
            FROM highway_area ha
            WHERE ha.geom && cce.anchor_geom
              AND ST_Intersects(ha.geom, cce.anchor_geom)
              AND (cce.layer IS NULL OR ha.layer IS NOT DISTINCT FROM cce.layer)
        ) AS has_ha_at_node
    FROM crossing_centerlines_typed cce
    WHERE cce.marking_kind IN ('centerline', 'edge')
      AND cce.line_geom IS NOT NULL
      AND NOT ST_IsEmpty(cce.line_geom)
),
buffered AS (
    SELECT
        pc.*,
        CASE
            WHEN pc.marking_kind = 'edge'
            THEN pc.geom_extended_edges::geometry(LineString)
            ELSE ST_LineExtend(
                pc.line_geom,
                metres(:'crossing_extend'::double precision),
                metres(:'crossing_extend'::double precision)
            )
        END AS centerline_for_clip,
        ST_Buffer(
            CASE
                WHEN pc.marking_kind = 'edge'
                THEN pc.geom_extended_edges::geometry(LineString)
                ELSE ST_LineExtend(
                    pc.line_geom,
                    metres(:'crossing_extend'::double precision),
                    metres(:'crossing_extend'::double precision)
                )
            END,
            metres(pc.width / 2.0 + :'crossing_clip_side_extra'::double precision),
            'endcap=flat join=round'
        ) AS ext_buffer
    FROM per_crossing pc
),
zone_per_row AS (
    SELECT
        b.crossing_id,
        b.osm_id,
        b.layer,
        b.crossing_type,
        b.anchor_geom,
        CASE
            WHEN b.has_ha_at_node THEN
                (
                    SELECT ST_Intersection(b.ext_buffer, areas.union_geom)
                    FROM (
                        SELECT ST_Buffer(ST_Union(ha.geom), 0) AS union_geom
                        FROM highway_area ha
                        WHERE ha.geom && b.ext_buffer
                          AND ST_Intersects(ha.geom, b.ext_buffer)
                          AND (b.layer IS NULL OR ha.layer IS NOT DISTINCT FROM b.layer)
                          AND EXISTS (
                              SELECT 1
                              FROM _highway_road_area rh
                              WHERE rh.area_highway = ha."area:highway"
                          )
                    ) areas
                    WHERE areas.union_geom IS NOT NULL
                      AND NOT ST_IsEmpty(areas.union_geom)
                )
            ELSE
                ST_Buffer(
                    b.centerline_for_clip,
                    metres(b.width / 2.0 + :'crossing_clip_side_extra'::double precision),
                    'endcap=flat join=round'
                )
        END AS zone_geom
    FROM buffered b
)
SELECT
    zpr.crossing_id,
    zpr.osm_id,
    zpr.layer,
    zpr.crossing_type,
    zpr.anchor_geom,
    (dp.geom)::geometry(Polygon) AS geom
FROM zone_per_row zpr
CROSS JOIN LATERAL ST_Dump(zpr.zone_geom) AS dp
WHERE zpr.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(zpr.zone_geom)
  AND ST_GeometryType((dp.geom)) = 'ST_Polygon'
  AND ST_Area((dp.geom)) > 0.01;

INSERT INTO _crossing_clip_zone_fragments (
    crossing_id,
    osm_id,
    layer,
    crossing_type,
    anchor_geom,
    geom
)
WITH lane_crossings AS (
    SELECT
        lc.osm_id AS crossing_id,
        lc.osm_id,
        lc.layer,
        CASE
            WHEN lc.type = 'bicycle' THEN 'bicycle'::text
            ELSE NULL::text
        END AS crossing_type,
        ST_LineInterpolatePoint(lc.geom, 0.5) AS anchor_geom,
        lc.width,
        lc.geom AS line_geom,
        l.direction,
        (
            lc.type = 'bicycle'
            AND l_prev.type = 'bicycle'
            AND (
                (
                    l_prev.marking_left IS NOT NULL
                    AND l_prev.marking_left NOT IN ('no', 'none')
                )
                OR (
                    l_prev.marking_right IS NOT NULL
                    AND l_prev.marking_right NOT IN ('no', 'none')
                )
            )
        ) AS block_extend_entry,
        (
            lc.type = 'bicycle'
            AND l_next.type = 'bicycle'
            AND (
                (
                    l_next.marking_left IS NOT NULL
                    AND l_next.marking_left NOT IN ('no', 'none')
                )
                OR (
                    l_next.marking_right IS NOT NULL
                    AND l_next.marking_right NOT IN ('no', 'none')
                )
            )
        ) AS block_extend_exit
    FROM lanes_clipped lc
    JOIN LATERAL (
        SELECT l.*
        FROM lanes l
        WHERE l.osm_id = lc.osm_id
          AND l.lane_index = lc.lane_index
          AND l.geom && ST_Expand(lc.geom, metres(0.001))
          AND ST_DWithin(l.geom, lc.geom, metres(0.001))
        ORDER BY ST_Length(ST_Intersection(l.geom, lc.geom)) DESC,
                 ST_Length(lc.geom) DESC
        LIMIT 1
    ) l ON true
    LEFT JOIN lanes l_prev
        ON l_prev.segment_id = l.prev_segment_id
       AND l_prev.lane_index = l.prev_lane_index
    LEFT JOIN lanes l_next
        ON l_next.segment_id = l.next_segment_id
       AND l_next.lane_index = l.next_lane_index
    WHERE lc.class = 'crossing'
      AND lc.geom IS NOT NULL
      AND NOT ST_IsEmpty(lc.geom)
      AND ST_GeometryType(lc.geom) = 'ST_LineString'
      AND lc.width IS NOT NULL
      AND lc.width > 0
      AND ST_NPoints(lc.geom) >= 2
),
lane_buffered AS (
    SELECT
        lc.*,
        ST_LineExtend(
            lc.line_geom,
            CASE
                WHEN lc.direction = 'backward' THEN
                    CASE
                        WHEN lc.block_extend_entry THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
                ELSE
                    CASE
                        WHEN lc.block_extend_exit THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
            END,
            CASE
                WHEN lc.direction = 'backward' THEN
                    CASE
                        WHEN lc.block_extend_exit THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
                ELSE
                    CASE
                        WHEN lc.block_extend_entry THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
            END
        ) AS centerline_for_clip
    FROM lane_crossings lc
),
lane_zones AS (
    SELECT
        crossing_id,
        osm_id,
        layer,
        crossing_type,
        anchor_geom,
        ST_Buffer(
            centerline_for_clip,
            metres(width / 2.0 + :'crossing_clip_side_extra'::double precision),
            'endcap=flat join=round'
        ) AS zone_geom
    FROM lane_buffered
)
SELECT
    lz.crossing_id,
    lz.osm_id,
    lz.layer,
    lz.crossing_type,
    lz.anchor_geom,
    (dp.geom)::geometry(Polygon) AS geom
FROM lane_zones lz
CROSS JOIN LATERAL ST_Dump(lz.zone_geom) AS dp
WHERE lz.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(lz.zone_geom)
  AND ST_GeometryType((dp.geom)) = 'ST_Polygon'
  AND ST_Area((dp.geom)) > 0.01;

CREATE TABLE crossing_clip_zones_by_crossing AS
SELECT
    f.crossing_id,
    f.osm_id,
    f.layer,
    f.crossing_type,
    f.geom
FROM _crossing_clip_zone_fragments f
WHERE EXISTS (
    SELECT 1
    FROM crossing_filtered cf
    WHERE ST_Contains(f.geom, cf.geom)
      AND (
          cf.osm_id = f.crossing_id
          OR EXISTS (
              SELECT 1
              FROM highway h
              WHERE h.osm_id = f.osm_id
                AND h.type = 'path'
                AND ST_Intersects(h.geom, cf.geom)
          )
      )
)

UNION ALL

SELECT
    f.crossing_id,
    f.osm_id,
    f.layer,
    f.crossing_type,
    f.geom
FROM _crossing_clip_zone_fragments f
WHERE ST_Contains(f.geom, f.anchor_geom)
  AND NOT EXISTS (
      SELECT 1
      FROM crossing_filtered cf
      WHERE ST_Contains(f.geom, cf.geom)
        AND (
            cf.osm_id = f.crossing_id
            OR EXISTS (
                SELECT 1
                FROM highway h
                WHERE h.osm_id = f.osm_id
                  AND h.type = 'path'
                  AND ST_Intersects(h.geom, cf.geom)
            )
        )
  );

CREATE TABLE _clip_zones_diff AS
SELECT
    f.crossing_id,
    f.osm_id,
    f.layer,
    f.crossing_type,
    f.anchor_geom,
    f.geom,
    ST_Area(f.geom) AS area
FROM _crossing_clip_zone_fragments f
WHERE NOT EXISTS (
    SELECT 1
    FROM crossing_filtered cf
    WHERE ST_Contains(f.geom, cf.geom)
      AND (
          cf.osm_id = f.crossing_id
          OR EXISTS (
              SELECT 1
              FROM highway h
              WHERE h.osm_id = f.osm_id
                AND h.type = 'path'
                AND ST_Intersects(h.geom, cf.geom)
          )
      )
);

DROP TABLE IF EXISTS _crossing_clip_zone_fragments;

CREATE INDEX crossing_clip_zones_by_crossing_geom_idx
    ON crossing_clip_zones_by_crossing USING GIST (geom);
CREATE INDEX crossing_clip_zones_by_crossing_osm_id_idx
    ON crossing_clip_zones_by_crossing (osm_id);

CREATE INDEX _clip_zones_diff_geom_idx
    ON _clip_zones_diff USING GIST (geom);
CREATE INDEX _clip_zones_diff_osm_id_idx
    ON _clip_zones_diff (osm_id);

CREATE TABLE crossing_clip_zones AS
SELECT
    layer,
    ST_Union(geom) AS geom
FROM crossing_clip_zones_by_crossing
GROUP BY layer;

CREATE INDEX crossing_clip_zones_geom_idx
    ON crossing_clip_zones USING GIST (geom);


----------------------------------------------------------------------
-- §7.5b) Remove generic road_marking_way inside clip zones
--
-- Includes highway_attributes lane_divider (marking lines, barred_area Breitstrich,
-- buffer_edge). Excludes osm_feature%, road_marking_restriction%, stop_line,
-- surface_colour.
-- source=crossing_way + crossing_edge: asymmetric foreign-zone clip (see below).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_rmw_clip_parts;
CREATE TEMP TABLE _crossing_rmw_clip_parts AS
WITH candidates AS (
    SELECT r.ctid, r.*
    FROM road_marking_way r
    WHERE r.source NOT LIKE 'osm_feature%'
      AND r.source NOT LIKE 'road_marking_restriction%'
      AND r.road_marking IS DISTINCT FROM 'stop_line'
      AND r.road_marking IS DISTINCT FROM 'surface_colour'
),
affected AS (
    SELECT
        c.*,
        z.geom AS zone_geom
    FROM candidates c
    INNER JOIN crossing_clip_zones z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE NOT (c.source = 'crossing_way' AND c.road_marking = 'crossing_edge')

    UNION ALL

    SELECT
        c.*,
        (
            SELECT ST_Union(z.geom)
            FROM crossing_clip_zones_by_crossing z
            WHERE z.layer IS NOT DISTINCT FROM c.layer
              AND z.osm_id IS DISTINCT FROM c.osm_id
              AND c.geom && z.geom
              AND ST_Intersects(c.geom, z.geom)
              AND (
                  c.type = 'bicycle'
                  OR z.crossing_type IS DISTINCT FROM 'bicycle'
              )
        ) AS zone_geom
    FROM candidates c
    WHERE c.source = 'crossing_way'
      AND c.road_marking = 'crossing_edge'
)
SELECT
    a.source,
    a.road_marking,
    a.osm_type,
    a.osm_id,
    a.stroke,
    a.pattern,
    a.arrow,
    a.symbol,
    a.width,
    a.length,
    a.colour,
    a.direction,
    a.type,
    a.class,
    a.layer,
    a.dasharray,
    (dp.geom)::geometry(LineString) AS geom,
    a.ctid AS orig_ctid
FROM affected a
CROSS JOIN LATERAL ST_Dump(ST_Difference(a.geom, a.zone_geom)) AS dp
WHERE a.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(a.zone_geom)
  AND (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty((dp.geom))
  AND ST_GeometryType((dp.geom)) = 'ST_LineString'
  AND ST_Length((dp.geom))
      >= metres(:'barred_area_crossing_min_fragment_length'::double precision);

DELETE FROM road_marking_way r
USING (
    SELECT DISTINCT orig_ctid
    FROM _crossing_rmw_clip_parts
    UNION
    SELECT c.ctid
    FROM road_marking_way c
    INNER JOIN crossing_clip_zones z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE c.source NOT LIKE 'osm_feature%'
      AND c.source NOT LIKE 'road_marking_restriction%'
      AND c.road_marking IS DISTINCT FROM 'stop_line'
      AND c.road_marking IS DISTINCT FROM 'surface_colour'
      AND NOT (c.source = 'crossing_way' AND c.road_marking = 'crossing_edge')
      AND NOT EXISTS (
          SELECT 1
          FROM _crossing_rmw_clip_parts p
          WHERE p.orig_ctid = c.ctid
      )
    UNION
    SELECT c.ctid
    FROM road_marking_way c
    INNER JOIN crossing_clip_zones_by_crossing z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND z.osm_id IS DISTINCT FROM c.osm_id
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE c.source = 'crossing_way'
      AND c.road_marking = 'crossing_edge'
      AND (
          c.type = 'bicycle'
          OR z.crossing_type IS DISTINCT FROM 'bicycle'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM _crossing_rmw_clip_parts p
          WHERE p.orig_ctid = c.ctid
      )
) doomed
WHERE r.ctid = doomed.orig_ctid;

INSERT INTO road_marking_way (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
FROM _crossing_rmw_clip_parts;

DROP TABLE IF EXISTS _crossing_rmw_clip_parts;

----------------------------------------------------------------------
-- §7.5c) Clip barred_area and surface_colour polygons at crossings
--        barred_area: all crossing zones (crossing_clip_zones union).
--        surface_colour: foreign crossing zones only (zone osm_id != polygon osm_id).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_rmp_clip_parts;
CREATE TEMP TABLE _crossing_rmp_clip_parts AS
WITH candidates_barred AS (
    SELECT r.ctid, r.*
    FROM road_marking_polygon r
    WHERE r.source = 'highway_attributes'
      AND r.road_marking = 'barred_area'
),
affected_barred AS (
    SELECT
        c.*,
        z.geom AS zone_geom
    FROM candidates_barred c
    INNER JOIN crossing_clip_zones z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
),
candidates_surface AS (
    SELECT r.ctid, r.*
    FROM road_marking_polygon r
    WHERE r.road_marking = 'surface_colour'
),
affected_surface AS (
    SELECT
        c.*,
        (
            SELECT ST_Union(z.geom)
            FROM crossing_clip_zones_by_crossing z
            WHERE z.layer IS NOT DISTINCT FROM c.layer
              AND z.osm_id IS DISTINCT FROM c.osm_id
              AND c.geom && z.geom
              AND ST_Intersects(c.geom, z.geom)
        ) AS zone_geom
    FROM candidates_surface c
),
affected AS (
    SELECT * FROM affected_barred
    UNION ALL
    SELECT * FROM affected_surface
)
SELECT
    a.source,
    a.road_marking,
    a.osm_type,
    a.osm_id,
    a.stroke,
    a.pattern,
    a.arrow,
    a.symbol,
    a.width,
    a.length,
    a.colour,
    a.direction,
    a.type,
    a.class,
    a.layer,
    a.dasharray,
    (dp.geom)::geometry(Polygon) AS geom,
    a.ctid AS orig_ctid
FROM affected a
CROSS JOIN LATERAL ST_Dump(ST_Difference(a.geom, a.zone_geom)) AS dp
WHERE a.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(a.zone_geom)
  AND (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty((dp.geom))
  AND ST_GeometryType((dp.geom)) = 'ST_Polygon'
  AND ST_Area((dp.geom)) > 0.01;

DELETE FROM road_marking_polygon r
USING (
    SELECT DISTINCT orig_ctid
    FROM _crossing_rmp_clip_parts
    UNION
    SELECT c.ctid
    FROM road_marking_polygon c
    INNER JOIN crossing_clip_zones z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE c.source = 'highway_attributes'
      AND c.road_marking = 'barred_area'
      AND NOT EXISTS (
          SELECT 1
          FROM _crossing_rmp_clip_parts p
          WHERE p.orig_ctid = c.ctid
      )
    UNION
    SELECT c.ctid
    FROM road_marking_polygon c
    INNER JOIN crossing_clip_zones_by_crossing z
        ON c.layer IS NOT DISTINCT FROM c.layer
       AND z.osm_id IS DISTINCT FROM c.osm_id
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE c.road_marking = 'surface_colour'
      AND NOT EXISTS (
          SELECT 1
          FROM _crossing_rmp_clip_parts p
          WHERE p.orig_ctid = c.ctid
      )
) doomed
WHERE r.ctid = doomed.orig_ctid;

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
FROM _crossing_rmp_clip_parts;

DROP TABLE IF EXISTS _crossing_rmp_clip_parts;

----------------------------------------------------------------------
-- §7.5d) Clip separation lines at crossings
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_separation_clip_parts;
CREATE TEMP TABLE _crossing_separation_clip_parts AS
WITH affected AS (
    SELECT
        s.ctid,
        s.osm_id,
        s.separation,
        s.layer,
        s.geom,
        z.geom AS zone_geom
    FROM separation s
    INNER JOIN crossing_clip_zones z
        ON s.layer IS NOT DISTINCT FROM z.layer
       AND s.geom && z.geom
       AND ST_Intersects(s.geom, z.geom)
)
SELECT
    a.osm_id,
    a.separation,
    a.layer,
    (dp.geom)::geometry(LineString) AS geom,
    a.ctid AS orig_ctid
FROM affected a
CROSS JOIN LATERAL ST_Dump(ST_Difference(a.geom, a.zone_geom)) AS dp
WHERE a.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(a.zone_geom)
  AND (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty((dp.geom))
  AND ST_GeometryType((dp.geom)) = 'ST_LineString'
  AND ST_Length((dp.geom))
      >= metres(:'barred_area_crossing_min_fragment_length'::double precision);

DELETE FROM separation s
USING (
    SELECT DISTINCT orig_ctid
    FROM _crossing_separation_clip_parts
    UNION
    SELECT s2.ctid
    FROM separation s2
    INNER JOIN crossing_clip_zones z
        ON s2.layer IS NOT DISTINCT FROM z.layer
       AND s2.geom && z.geom
       AND ST_Intersects(s2.geom, z.geom)
    WHERE NOT EXISTS (
        SELECT 1
        FROM _crossing_separation_clip_parts p
        WHERE p.orig_ctid = s2.ctid
    )
) doomed
WHERE s.ctid = doomed.orig_ctid;

INSERT INTO separation (osm_id, separation, layer, geom)
SELECT
    osm_id,
    separation,
    layer,
    geom
FROM _crossing_separation_clip_parts;

DROP TABLE IF EXISTS _crossing_separation_clip_parts;

----------------------------------------------------------------------
-- §7.6b) Insert zebra/ladder stripe polygons (built in §7.6)
----------------------------------------------------------------------

ALTER TABLE road_marking_polygon
    ALTER COLUMN geom TYPE geometry(Geometry)
    USING geom::geometry(Geometry);

INSERT INTO road_marking_polygon (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
FROM crossing_stripe_polygons
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

DROP TABLE IF EXISTS crossing_stripe_polygons;

DELETE FROM road_marking_node n
WHERE n.source NOT LIKE 'osm_feature%'
  AND EXISTS (
      SELECT 1
      FROM crossing_clip_zones z
      WHERE n.layer IS NOT DISTINCT FROM z.layer
        AND ST_Intersects(n.geom, z.geom)
  );


----------------------------------------------------------------------
-- §8) Insert into road_marking_way
----------------------------------------------------------------------

INSERT INTO road_marking_way (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    cml.source,
    cml.road_marking,
    cml.osm_type,
    cml.osm_id,
    cml.stroke,
    NULL::text,
    NULL::text,
    NULL::text,
    cml.width::real,
    NULL::real,
    CASE
        WHEN cml.is_temporary
        THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END,
    NULL::real,
    cml.marking_type,
    NULL::text,
    cml.layer,
    CASE
        WHEN cml.road_marking = 'crossing_edge'
         AND cml.stroke LIKE '%dashed%'
        THEN :'dasharray_crossing_edge'::text
        ELSE NULL::text
    END AS dasharray,
    cml.geom
FROM crossing_marking_lines_clipped cml
WHERE cml.geom IS NOT NULL
  AND NOT ST_IsEmpty(cml.geom)
  AND NOT (
      cml.road_marking = 'crossing'
      AND cml.stroke IN ('zebra', 'ladder')
  );


----------------------------------------------------------------------
-- §8b) Clip newly inserted crossing_way crossing_edge at other crossings
--      (§7.5b already clips rows from prior runs; same rule, no self-clip).
--      Asymmetric zone filter: bicycle edges clip at all zones; footway/path only at non-bicycle zones.
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_way_rmw_clip_parts;
CREATE TEMP TABLE _crossing_way_rmw_clip_parts AS
WITH candidates AS (
    SELECT r.ctid, r.*
    FROM road_marking_way r
    WHERE r.source = 'crossing_way'
      AND r.road_marking = 'crossing_edge'
),
affected AS (
    SELECT
        c.*,
        (
            SELECT ST_Union(z.geom)
            FROM crossing_clip_zones_by_crossing z
            WHERE z.layer IS NOT DISTINCT FROM c.layer
              AND z.osm_id IS DISTINCT FROM c.osm_id
              AND c.geom && z.geom
              AND ST_Intersects(c.geom, z.geom)
              AND (
                  c.type = 'bicycle'
                  OR z.crossing_type IS DISTINCT FROM 'bicycle'
              )
        ) AS zone_geom
    FROM candidates c
)
SELECT
    a.source,
    a.road_marking,
    a.osm_type,
    a.osm_id,
    a.stroke,
    a.pattern,
    a.arrow,
    a.symbol,
    a.width,
    a.length,
    a.colour,
    a.direction,
    a.type,
    a.class,
    a.layer,
    a.dasharray,
    (dp.geom)::geometry(LineString) AS geom,
    a.ctid AS orig_ctid
FROM affected a
CROSS JOIN LATERAL ST_Dump(ST_Difference(a.geom, a.zone_geom)) AS dp
WHERE a.zone_geom IS NOT NULL
  AND NOT ST_IsEmpty(a.zone_geom)
  AND (dp.geom) IS NOT NULL
  AND NOT ST_IsEmpty((dp.geom))
  AND ST_GeometryType((dp.geom)) = 'ST_LineString'
  AND ST_Length((dp.geom)) >= metres(0.01);

DELETE FROM road_marking_way r
USING (
    SELECT DISTINCT orig_ctid
    FROM _crossing_way_rmw_clip_parts
    UNION
    SELECT c.ctid
    FROM road_marking_way c
    INNER JOIN crossing_clip_zones_by_crossing z
        ON c.layer IS NOT DISTINCT FROM z.layer
       AND z.osm_id IS DISTINCT FROM c.osm_id
       AND c.geom && z.geom
       AND ST_Intersects(c.geom, z.geom)
    WHERE c.source = 'crossing_way'
      AND c.road_marking = 'crossing_edge'
      AND (
          c.type = 'bicycle'
          OR z.crossing_type IS DISTINCT FROM 'bicycle'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM _crossing_way_rmw_clip_parts p
          WHERE p.orig_ctid = c.ctid
      )
) doomed
WHERE r.ctid = doomed.orig_ctid;

INSERT INTO road_marking_way (
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
)
SELECT
    source,
    road_marking,
    osm_type,
    osm_id,
    stroke,
    pattern,
    arrow,
    symbol,
    width,
    length,
    colour,
    direction,
    type,
    class,
    layer,
    dasharray,
    geom
FROM _crossing_way_rmw_clip_parts;

DROP TABLE IF EXISTS _crossing_way_rmw_clip_parts;


----------------------------------------------------------------------
-- §9) Cleanup intermediate tables
----------------------------------------------------------------------

-- DROP TABLE IF EXISTS crossing_marking_lines_clipped;
-- DROP TABLE IF EXISTS crossing_marking_lines_pre_clip;
-- DROP TABLE IF EXISTS crossing_clip_zones_by_crossing;
-- DROP TABLE IF EXISTS crossing_clip_zones;
DROP TABLE IF EXISTS crossing_centerlines_typed;
DROP TABLE IF EXISTS crossing_centerlines_marked;
DROP TABLE IF EXISTS crossing_centerlines_extended;
DROP TABLE IF EXISTS crossing_centerlines_raw;
DROP TABLE IF EXISTS crossing_centerlines_merged;
DROP TABLE IF EXISTS crossing_merge_segments;
DROP TABLE IF EXISTS crossing_way_only_centerlines;
DROP TABLE IF EXISTS crossing_node_centerlines;
DROP TABLE IF EXISTS crossing_sides_present;
DROP TABLE IF EXISTS crossing_best_segment_per_side;
DROP TABLE IF EXISTS crossing_path_segments_scored;
DROP TABLE IF EXISTS crossing_path_segments;
DROP TABLE IF EXISTS crossing_filtered;
