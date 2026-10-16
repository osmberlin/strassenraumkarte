-- road_marking_stop_lines.sql — Generates stop lines from stop and traffic signal nodes ("generic")
-- and area:highway junction/crossing areas if present ("junction outline")
--
-- Depends on: stop_positions (road_azimuth persisted in §3b of this script)
-- Sections: 1)–3) inputs; 2a) junction-area merge; 4) generic (4a)–4c); 5) junction outline (5a)–5b), 5c) with 5c.1)–5c.6); 6) insert into road_marking_way; 7) drop intermediates.

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/highway_road_area.sql'


-- 1) Filter stop positions: exclude stop_line=no, traffic_signals=emergency,
--    and nodes touched by mapped road_marking=stop_line
DROP TABLE IF EXISTS stop_positions_filtered;
CREATE TABLE stop_positions_filtered AS
SELECT sp.*
FROM stop_positions sp
WHERE
    (sp.stop_line IS NULL OR sp.stop_line != 'no')
    AND NOT (sp.highway = 'traffic_signals' AND sp.traffic_signals = 'emergency')
    AND NOT EXISTS (
        SELECT 1 FROM road_marking_way rm
        WHERE rm.road_marking = 'stop_line'
          AND ST_DWithin(sp.geom, rm.geom, metres(0.5))
    );

DROP INDEX IF EXISTS stop_positions_filtered_geom_idx;
CREATE INDEX stop_positions_filtered_geom_idx ON stop_positions_filtered USING GIST (geom);


-- 2) Filter junction areas (atomic polygons): at least one stop node on the boundary
DROP TABLE IF EXISTS junction_areas_pre_merge;
CREATE TABLE junction_areas_pre_merge AS
SELECT
    ha.osm_id AS junction_id,
    ha.osm_type,
    ha.osm_id,
    ha."area:highway" AS area_highway,
    ha.type,
    ha.class,
    ha.layer,
    ST_ForcePolygonCCW(ha.geom) AS geom
FROM highway_area ha
WHERE ha.type IN ('junction', 'crossing')
  AND EXISTS (
      SELECT 1 FROM stop_positions_filtered sp
      WHERE ST_Intersects(sp.geom, ST_Boundary(ha.geom))
  );

DROP INDEX IF EXISTS junction_areas_pre_merge_geom_idx;
CREATE INDEX junction_areas_pre_merge_geom_idx ON junction_areas_pre_merge USING GIST (geom);


-- 2a) Merge polygons that intersect, share identical area_highway/type/class tags, and are not
--     split by a stop on the interior of a shared boundary line (endpoints / corner touches allowed).
--     junction_id and osm_id follow the largest atomic polygon (tie-break: higher junction_id).
DROP TABLE IF EXISTS junction_areas_filtered;
CREATE TABLE junction_areas_filtered AS
WITH RECURSIVE
merge_pairs AS (
    SELECT
        a.junction_id AS id_a,
        b.junction_id AS id_b
    FROM junction_areas_pre_merge a
    INNER JOIN junction_areas_pre_merge b
        ON a.junction_id < b.junction_id
       AND ST_Intersects(a.geom, b.geom)
       AND (a.area_highway IS NOT DISTINCT FROM b.area_highway)
       AND (a.type IS NOT DISTINCT FROM b.type)
       AND (a.class IS NOT DISTINCT FROM b.class)
       AND NOT EXISTS (
            SELECT 1
            FROM stop_positions_filtered sp
            WHERE EXISTS (
                SELECT 1
                FROM LATERAL ST_Dump(
                    ST_LineMerge(
                        ST_CollectionExtract(
                            ST_Intersection(
                                ST_Boundary(a.geom),
                                ST_Boundary(b.geom)
                            ),
                            2
                        )
                    )
                ) AS d
                WHERE ST_GeometryType((d).geom) = 'ST_LineString'
                  AND ST_Length((d).geom) > 0
                  AND ST_Intersects(sp.geom, (d).geom)
                  AND ST_LineLocatePoint((d).geom, sp.geom) > 0
                  AND ST_LineLocatePoint((d).geom, sp.geom) < 1
            )
        )
),
merge_edges AS (
    SELECT id_a AS node, id_b AS neighbor FROM merge_pairs
    UNION ALL
    SELECT id_b, id_a FROM merge_pairs
),
walk AS (
    SELECT junction_id AS node, junction_id AS root
    FROM junction_areas_pre_merge
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
ranked AS (
    SELECT
        c.cluster_id,
        p.junction_id,
        p.osm_type,
        p.osm_id,
        p.layer,
        p.geom,
        ROW_NUMBER() OVER (
            PARTITION BY c.cluster_id
            ORDER BY ST_Area(p.geom) DESC, p.junction_id DESC
        ) AS rn
    FROM junction_areas_pre_merge p
    INNER JOIN comp c ON p.junction_id = c.node
),
merged AS (
    SELECT cluster_id, ST_UnaryUnion(ST_Collect(geom)) AS geom
    FROM ranked
    GROUP BY cluster_id
)
SELECT
    w.osm_id AS junction_id,
    w.osm_type,
    w.osm_id,
    w.layer,
    ST_ForcePolygonCCW(m.geom) AS geom
FROM merged m
INNER JOIN ranked w
    ON w.cluster_id = m.cluster_id
   AND w.rn = 1;

DROP INDEX IF EXISTS junction_areas_filtered_geom_idx;
CREATE INDEX junction_areas_filtered_geom_idx ON junction_areas_filtered USING GIST (geom);


-- 2b) Precompute junction outlines once (from merged CCW polygons in junction_areas_filtered)
--     Using the outline for stop-node matching automatically excludes nodes inside the area.
DROP TABLE IF EXISTS junction_outlines_filtered;
CREATE TABLE junction_outlines_filtered AS
SELECT
    ja.junction_id,
    ja.osm_type,
    ja.osm_id,
    (ST_Dump(ST_Boundary(ja.geom))).geom AS geom
FROM junction_areas_filtered ja;

-- keep only usable linework
DELETE FROM junction_outlines_filtered
WHERE ST_IsEmpty(geom)
   OR ST_GeometryType(geom) != 'ST_LineString'
   OR ST_Length(geom) <= metres(0.05);

DROP INDEX IF EXISTS junction_outlines_filtered_geom_idx;
CREATE INDEX junction_outlines_filtered_geom_idx ON junction_outlines_filtered USING GIST (geom);


-- 3) Link each stop node to its junction area(s) (boundary touches)
DROP TABLE IF EXISTS stop_positions_junction;
CREATE TABLE stop_positions_junction AS
SELECT
    sp.osm_id,
    sp.geom,
    ja.junction_id
FROM stop_positions_filtered sp
JOIN junction_areas_filtered ja
  ON ST_Intersects(sp.geom, ST_Boundary(ja.geom));

DROP INDEX IF EXISTS stop_positions_junction_geom_idx;
CREATE INDEX stop_positions_junction_geom_idx ON stop_positions_junction USING GIST (geom);


-- 3b) Centerline azimuth at stop nodes (shared helper) + persist on stop_positions.road_azimuth (degrees, integer)
--     road_azimuth is the orientation of the road itself (not a perpendicular axis).
--     Note: azimuth_centerline_towards / approach_azimuth_new below only feed the QC diff
--     approach_azimuth_diff_deg (§4a), which is not used for the actual stop-line geometry
--     (that uses a locally sampled road azimuth + 90° instead) — no downstream adjustment needed.
ALTER TABLE stop_positions ADD COLUMN IF NOT EXISTS road_azimuth integer;

DROP TABLE IF EXISTS _node_road_azimuth_input;
CREATE TEMP TABLE _node_road_azimuth_input AS
SELECT
    osm_id AS node_id,
    geom
FROM stop_positions_filtered;

\i 'processing/sql/helper/node_road_azimuth.sql'

DROP TABLE IF EXISTS stop_positions_centerline_prepared;
CREATE TABLE stop_positions_centerline_prepared AS
SELECT
    inp.node_id AS stop_id,
    inp.geom,
    sp.direction,
    nra.road_azimuth AS azimuth_centerline_towards,
    nra.road_azimuth AS approach_azimuth_new
FROM _node_road_azimuth_input inp
JOIN stop_positions_filtered sp
  ON sp.osm_id = inp.node_id
LEFT JOIN _node_road_azimuth nra
  ON nra.node_id = inp.node_id;

UPDATE stop_positions sp
SET road_azimuth = MOD(ROUND(DEGREES(scp.azimuth_centerline_towards))::integer + 360, 360)
FROM stop_positions_centerline_prepared scp
WHERE sp.osm_id = scp.stop_id
  AND scp.azimuth_centerline_towards IS NOT NULL;

DROP INDEX IF EXISTS stop_positions_centerline_prepared_geom_idx;
CREATE INDEX stop_positions_centerline_prepared_geom_idx ON stop_positions_centerline_prepared USING GIST (geom);

DROP TABLE IF EXISTS _node_road_azimuth_input;
DROP TABLE IF EXISTS _node_road_azimuth;


-- 4) Generic stop lines
--    Permanent: non-junction stops (§4a–4c, sources stop_node_generic*).
--    Temporary: junction stops on highways with turn lanes (for turn-arrow processing).

DROP TABLE IF EXISTS highways_with_turn;
CREATE TEMP TABLE highways_with_turn AS
SELECT DISTINCT l.osm_id
FROM lanes l
WHERE l.turn IS NOT NULL
  AND l.turn NOT IN ('no', 'none');

CREATE INDEX highways_with_turn_osm_id_idx ON highways_with_turn (osm_id);

-- 4a) Raw line perpendicular to the road at the stop (signals / stop signs)
DROP TABLE IF EXISTS highway_stop_lines_raw;
CREATE TABLE highway_stop_lines_raw AS
WITH matched_roads_permanent AS (
    SELECT
        sp.osm_id            AS stop_id,
        hr.osm_id            AS road_id,
        hr.layer,
        sp.direction,
        hr.width,
        hr.placement_offset,
        hr.geom          AS road_geom,
        sp.geom          AS stop_geom,
        sp."stop_line:angle" AS stop_line_angle,
        false AS for_turn_arrows,
        ST_LineLocatePoint(hr.geom, sp.geom) AS frac,
        ROW_NUMBER() OVER (
            PARTITION BY sp.osm_id
            ORDER BY hr.width DESC
        ) AS rn
    FROM stop_positions_filtered sp
    JOIN highway hr
      ON hr.geom && sp.geom
     AND ST_Intersects(sp.geom, hr.geom)
     AND hr.type IN ('road', 'motorway')
    WHERE NOT EXISTS (
        SELECT 1 FROM stop_positions_junction spj
        WHERE spj.osm_id = sp.osm_id
    )
),
matched_roads_temporary AS (
    SELECT
        sp.osm_id            AS stop_id,
        hr.osm_id            AS road_id,
        hr.layer,
        sp.direction,
        hr.width,
        hr.placement_offset,
        hr.geom          AS road_geom,
        sp.geom          AS stop_geom,
        sp."stop_line:angle" AS stop_line_angle,
        true AS for_turn_arrows,
        ST_LineLocatePoint(hr.geom, sp.geom) AS frac,
        ROW_NUMBER() OVER (
            PARTITION BY sp.osm_id
            ORDER BY hr.width DESC
        ) AS rn
    FROM stop_positions sp
    JOIN highway hr
      ON hr.geom && sp.geom
     AND ST_Intersects(sp.geom, hr.geom)
     AND hr.type IN ('road', 'motorway')
    INNER JOIN highways_with_turn ht
      ON ht.osm_id = hr.osm_id
    WHERE (sp.stop_line IS NULL OR sp.stop_line <> 'no')
      AND EXISTS (
          SELECT 1 FROM stop_positions_junction spj
          WHERE spj.osm_id = sp.osm_id
      )
),
matched_roads AS (
    SELECT * FROM matched_roads_permanent
    UNION ALL
    SELECT * FROM matched_roads_temporary
),

selected AS (
    SELECT
        stop_id,
        road_id,
        layer,
        direction,
        width,
        placement_offset,
        road_geom,
        stop_geom,
        stop_line_angle,
        for_turn_arrows,
        GREATEST(0.00001, LEAST(0.99999, frac)) AS frac
    FROM matched_roads
    WHERE rn = 1
),

geometry_base AS (
    SELECT
        *,
        -- exact point on the line
        ST_LineInterpolatePoint(road_geom, frac) AS base_pt,

        -- points a bit before and after this position to get stop line angle
        ST_LineInterpolatePoint(road_geom, frac - 0.00001) AS pt_before,
        ST_LineInterpolatePoint(road_geom, frac + 0.00001) AS pt_after
    FROM selected
),

azimuth_calc AS (
    SELECT
        geometry_base.*,
        ST_Azimuth(pt_before, pt_after) AS azimuth,
        CASE geometry_base.direction
            WHEN 'forward' THEN ST_Azimuth(
                ST_LineInterpolatePoint(road_geom, GREATEST(0.00002, frac - 0.02)),
                ST_LineInterpolatePoint(road_geom, frac)
            )
            ELSE ST_Azimuth(
                ST_LineInterpolatePoint(road_geom, LEAST(0.99998, frac + 0.02)),
                ST_LineInterpolatePoint(road_geom, frac)
            )
        END AS approach_azimuth_old,
        scp.approach_azimuth_new AS approach_azimuth_new,
        DEGREES(ABS(ATAN2(
            SIN(scp.approach_azimuth_new - CASE geometry_base.direction
                WHEN 'forward' THEN ST_Azimuth(
                    ST_LineInterpolatePoint(road_geom, GREATEST(0.00002, frac - 0.02)),
                    ST_LineInterpolatePoint(road_geom, frac)
                )
                ELSE ST_Azimuth(
                    ST_LineInterpolatePoint(road_geom, LEAST(0.99998, frac + 0.02)),
                    ST_LineInterpolatePoint(road_geom, frac)
                )
            END),
            COS(scp.approach_azimuth_new - CASE geometry_base.direction
                WHEN 'forward' THEN ST_Azimuth(
                    ST_LineInterpolatePoint(road_geom, GREATEST(0.00002, frac - 0.02)),
                    ST_LineInterpolatePoint(road_geom, frac)
                )
                ELSE ST_Azimuth(
                    ST_LineInterpolatePoint(road_geom, LEAST(0.99998, frac + 0.02)),
                    ST_LineInterpolatePoint(road_geom, frac)
                )
            END)
        )))::double precision AS approach_azimuth_diff_deg
    FROM geometry_base
    JOIN stop_positions_centerline_prepared scp
      ON scp.stop_id = geometry_base.stop_id
),

final_geom AS (
    SELECT
        stop_id,
        road_id,
        layer,
        direction,
        width,
        placement_offset,
        stop_geom,
        for_turn_arrows,
        approach_azimuth_old AS approach_azimuth,
        approach_azimuth_new,
        approach_azimuth_diff_deg,
        ST_Project(
            base_pt,
            metres((width / 2) - placement_offset),
            line_along_bar + pi()
        ) AS start_pt,
        ST_Project(
            base_pt,
            metres((width / 2) + placement_offset),
            line_along_bar
        ) AS end_pt
    FROM (
        SELECT
            *,
            CASE
                WHEN stop_line_angle IS NOT NULL
                THEN radians(stop_line_angle::double precision)
                ELSE azimuth + pi() / 2
            END AS line_along_bar
        FROM azimuth_calc
    ) oriented
)

SELECT
    stop_id,
    road_id,
    layer,
    direction,
    width,
    placement_offset,
    stop_geom,
    for_turn_arrows,
    approach_azimuth,
    ST_MakeLine(start_pt, end_pt) AS geom
FROM final_geom;

-- create spatial index
DROP INDEX IF EXISTS highway_stop_lines_raw_geom_idx;
CREATE INDEX highway_stop_lines_raw_geom_idx ON highway_stop_lines_raw USING GIST (geom);


-- 4b) Clip to approach lanes (direction + one-sided both_ways; exclude parking)
DROP TABLE IF EXISTS highway_stop_lines_generic;
CREATE TABLE highway_stop_lines_generic AS
WITH stop_buffers AS (
    SELECT
        stop_id,
        stop_geom AS stop_pt,
        direction,
        approach_azimuth,
        -- full-width candidate stop line (before clipping to approach lanes)
        geom AS stop_line_geom,
        ST_Buffer(geom, metres(1.0)) AS stop_buffer
    FROM highway_stop_lines_raw
),

matched_lanes AS (
    SELECT
        sb.stop_id,
        sb.stop_pt,
        sb.stop_line_geom,
        sb.stop_buffer,
        sb.direction,
        sb.approach_azimuth,
        l.osm_id AS lane_id,
        l.direction AS lane_direction,
        l.geom AS lane_geom,
        l.width,
        l.buffer_left,
        l.buffer_right
    FROM stop_buffers sb
    JOIN lanes l
      ON ST_Intersects(l.geom, sb.stop_buffer)
     AND (l.type IS NULL OR l.type IS DISTINCT FROM 'parking')
     AND (
         l.direction = sb.direction
         OR (
             l.direction = 'both_ways'
             AND sb.direction IN ('forward', 'backward')
             AND (
                 SELECT COUNT(*)::int
                 FROM lanes l_bw
                 WHERE l_bw.direction = 'both_ways'
                   AND ST_Intersects(l_bw.geom, sb.stop_buffer)
             ) = 1
         )
     )
),

clipped_lanes AS (
    SELECT
        stop_id,
        stop_pt,
        stop_line_geom,
        approach_azimuth,
        lane_direction,
        width,
        buffer_left,
        buffer_right,
        lane_geom AS lane_geom_full,
        ST_Intersection(lane_geom, stop_buffer) AS geom
    FROM matched_lanes
),

valid_lanes AS (
    SELECT *
    FROM clipped_lanes
    WHERE NOT ST_IsEmpty(geom)
),

lane_polygons AS (
    SELECT
        stop_id,
        stop_line_geom,
        CASE
            WHEN lane_direction IS DISTINCT FROM 'both_ways' THEN
                ST_Union(
                    ST_Buffer(
                        geom,
                        metres(width / 2.0 + buffer_left + 0.12),
                        'side=left'
                    ),
                    ST_Buffer(
                        geom,
                        metres(width / 2.0 + buffer_right + 0.12),
                        'side=right'
                    )
                )
            WHEN cos(
                approach_azimuth - ST_Azimuth(
                    ST_LineInterpolatePoint(
                        lane_geom_full,
                        GREATEST(0.00002,
                            ST_LineLocatePoint(
                                lane_geom_full,
                                ST_ClosestPoint(lane_geom_full, stop_pt)
                            ) - 0.02
                        )
                    ),
                    ST_LineInterpolatePoint(
                        lane_geom_full,
                        LEAST(0.99998,
                            ST_LineLocatePoint(
                                lane_geom_full,
                                ST_ClosestPoint(lane_geom_full, stop_pt)
                            ) + 0.02
                        )
                    )
                )
            ) > 0 THEN
                ST_Buffer(
                    lane_geom_full,
                    metres(width / 2.0 + buffer_right + 0.12),
                    'side=right'
                )
            ELSE
                ST_Buffer(
                    lane_geom_full,
                    metres(width / 2.0 + buffer_left + 0.12),
                    'side=left'
                )
        END AS poly
    FROM valid_lanes
),

merged_polygons AS (
    SELECT
        stop_id,
        stop_line_geom,
        ST_Union(poly) AS poly
    FROM lane_polygons
    GROUP BY stop_id, stop_line_geom
),

final_lines AS (
    SELECT
        stop_id,
        ST_Intersection(stop_line_geom, poly) AS geom
    FROM merged_polygons
),

-- 4c) Optionally extend clipped line (+3 m by direction / oneway) when the stop lies on area:highway
--     and is touched by a road/motorway centerline (not path/service/… alone).
generic_with_extension AS (
    SELECT
        fl.stop_id,
        raw.layer,
        raw.for_turn_arrows,
        CASE
            WHEN ST_GeometryType(fl.geom) != 'ST_LineString' THEN fl.geom
            WHEN NOT EXISTS (
                SELECT 1 FROM highway_area ha
                WHERE ST_Intersects(ha.geom, raw.stop_geom)
            ) THEN fl.geom
            WHEN NOT EXISTS (
                SELECT 1 FROM highway hr_touch
                WHERE hr_touch.geom && raw.stop_geom
                  AND ST_Intersects(hr_touch.geom, raw.stop_geom)
                  AND hr_touch.type IN ('road', 'motorway')
            ) THEN fl.geom
            WHEN hr.oneway IN ('yes', '1', 'true', '-1') THEN
                ST_LineExtend(fl.geom, metres(3.0), metres(3.0))
            WHEN cos(
                ST_Azimuth(ST_StartPoint(fl.geom), ST_EndPoint(fl.geom))
                - (raw.approach_azimuth + pi() / 2)
            ) > 0 THEN
                ST_LineExtend(fl.geom, metres(3.0), 0.0)
            ELSE
                ST_LineExtend(fl.geom, 0.0, metres(3.0))
        END AS geom
    FROM final_lines fl
    JOIN highway_stop_lines_raw raw ON raw.stop_id = fl.stop_id
    JOIN highway hr ON hr.osm_id = raw.road_id
    WHERE NOT ST_IsEmpty(fl.geom)
),

-- 4d) Clip extended generic stop lines back to road carriageway highway_area
--     when the stop node lies on any highway_area (same gate as 4c).
--     Selection is via area:highway ∈ _highway_road_area (includes junction/crossing
--     polygons of those classes; regular carriageways often have type NULL).
generic_clipped_to_highway_area AS (
    SELECT
        g.stop_id,
        g.layer,
        g.for_turn_arrows,
        CASE
            WHEN NOT EXISTS (
                SELECT 1 FROM highway_area ha
                WHERE ST_Intersects(ha.geom, raw.stop_geom)
            ) THEN g.geom
            WHEN clip.poly IS NULL OR ST_IsEmpty(clip.poly) THEN g.geom
            WHEN clipped.geom IS NULL OR ST_IsEmpty(clipped.geom) THEN g.geom
            ELSE clipped.geom
        END AS geom
    FROM generic_with_extension g
    JOIN highway_stop_lines_raw raw ON raw.stop_id = g.stop_id
    LEFT JOIN LATERAL (
        SELECT ST_UnaryUnion(ST_Collect(ha.geom)) AS poly
        FROM highway_area ha
        WHERE EXISTS (
                SELECT 1 FROM _highway_road_area rh
                WHERE rh.area_highway = ha."area:highway"
            )
          AND ha.geom && g.geom
          AND ST_Intersects(ha.geom, g.geom)
    ) clip ON TRUE
    LEFT JOIN LATERAL (
        SELECT ST_CollectionExtract(ST_Intersection(g.geom, clip.poly), 2) AS geom
        WHERE clip.poly IS NOT NULL
          AND NOT ST_IsEmpty(clip.poly)
    ) clipped ON TRUE
)

SELECT
    CASE
        WHEN g.for_turn_arrows THEN
            CASE
                WHEN sp."stop_line:angle" IS NOT NULL THEN 'stop_node_generic_angled_temporary'::text
                ELSE 'stop_node_generic_temporary'::text
            END
        WHEN sp."stop_line:angle" IS NOT NULL THEN 'stop_node_generic_angled'::text
        ELSE 'stop_node_generic'::text
    END AS source,
    'stop_line'::text AS road_marking,
    sp.osm_type,
    sp.osm_id AS osm_id,
    NULL::bigint AS osm_id_highway_area,
    NULL::int AS candidate_id,
    NULL::int AS seg_index,
    sp.direction AS direction_stop_node,
    'no_touch/other'::text AS direction_lane,
    :'stop_line_stroke'::text AS stroke,
    :'stop_line_width'::double precision AS width,
    CASE
        WHEN sp.temporary = 'yes' THEN :'stop_line_colour_temporary'::text
        ELSE :'stop_line_colour'::text
    END AS colour,
    g.layer,
    g.geom
FROM generic_clipped_to_highway_area g
JOIN stop_positions sp
  ON sp.osm_id = g.stop_id
WHERE g.geom IS NOT NULL
  AND NOT ST_IsEmpty(g.geom);

-- create spatial index
DROP INDEX IF EXISTS highway_stop_lines_generic_geom_idx;
CREATE INDEX highway_stop_lines_generic_geom_idx ON highway_stop_lines_generic USING GIST (geom);



-- 5) Junction preparation (Iteration 1): build enriched stop-node records
DROP TABLE IF EXISTS stop_positions_junction_enriched;
CREATE TABLE stop_positions_junction_enriched AS
WITH

-- 5a) Junction reference areas / outlines: reuse precomputed outline + CCW polygon
junction_areas_reference AS (
    SELECT
        ja.junction_id,
        ja.osm_type,
        ja.osm_id,
        ja.geom
    FROM junction_areas_filtered ja
),
junction_outlines_reference AS (
    SELECT
        jo.junction_id,
        jo.geom
    FROM junction_outlines_filtered jo
),

-- 5b) Stop-node / junction combinations (1:n for multi-junction touch cases)
stop_junction_pairs AS (
    SELECT
        sp.osm_id AS stop_id,
        sp.osm_type,
        sp.direction,
        sp.temporary,
        sp.geom AS stop_geom,
        ja.junction_id,
        ja.geom AS junction_geom
    FROM stop_positions_filtered sp
    JOIN junction_areas_reference ja
      ON EXISTS (
          SELECT 1
          FROM junction_outlines_reference jo
          WHERE jo.junction_id = ja.junction_id
            AND ST_Intersects(sp.geom, jo.geom)
      )
),
stop_junction_pairs_with_counts AS (
    SELECT
        sjp.*,
        COUNT(*) OVER (PARTITION BY sjp.stop_id) AS count_junctions
    FROM stop_junction_pairs sjp
),

-- 5c) Roads touching each stop-node and local splitting at stop point
roads_at_stop AS (
    SELECT DISTINCT
        sjp.stop_id,
        sjp.stop_geom,
        hr.osm_id AS road_id,
        hr.geom AS road_geom
    FROM stop_junction_pairs_with_counts sjp
    JOIN highway hr
      ON hr.geom && sjp.stop_geom
     AND ST_Intersects(hr.geom, sjp.stop_geom)
     AND hr.type IN ('road', 'motorway')
),
road_parts AS (
    SELECT
        ras.stop_id,
        ras.stop_geom,
        ras.road_id,
        (d.geom)::geometry(LineString) AS geom
    FROM roads_at_stop ras
    CROSS JOIN LATERAL (
        SELECT geom
        FROM (
            SELECT (ST_Dump(
                CASE
                    WHEN ST_Intersects(ST_StartPoint(ras.road_geom), ras.stop_geom)
                      OR ST_Intersects(ST_EndPoint(ras.road_geom), ras.stop_geom)
                    THEN ras.road_geom
                    ELSE ST_Split(ras.road_geom, ras.stop_geom)
                END
            )).geom
        ) p
        WHERE ST_GeometryType(p.geom) = 'ST_LineString'
          AND ST_Length(p.geom) > metres(0.01)
          AND ST_Intersects(p.geom, ras.stop_geom)
    ) d
),
road_parts_with_azimuth AS (
    SELECT
        rp.stop_id,
        rp.road_id,
        ROW_NUMBER() OVER (PARTITION BY rp.stop_id ORDER BY rp.road_id, ST_AsBinary(rp.geom)) AS segment_id,
        rp.geom,
        CASE
            WHEN ST_Distance(ST_StartPoint(rp.geom), rp.stop_geom)
                 <= ST_Distance(ST_EndPoint(rp.geom), rp.stop_geom)
            THEN ST_Azimuth(
                ST_PointN(rp.geom, 1),
                ST_PointN(rp.geom, LEAST(2, ST_NPoints(rp.geom)))
            )
            ELSE ST_Azimuth(
                ST_PointN(rp.geom, ST_NPoints(rp.geom)),
                ST_PointN(rp.geom, GREATEST(1, ST_NPoints(rp.geom) - 1))
            )
        END AS segment_azimuth
    FROM road_parts rp
    WHERE ST_NPoints(rp.geom) >= 2
),

-- 5d) Inner/outer classification per stop-node / junction combination
segments_by_pair AS (
    SELECT
        sjp.stop_id,
        sjp.osm_type,
        sjp.direction,
        sjp.temporary,
        sjp.stop_geom,
        sjp.junction_id,
        sjp.count_junctions,
        rpa.segment_id,
        rpa.geom AS segment_geom,
        rpa.segment_azimuth,
        ST_Equals(ST_StartPoint(rpa.geom), sjp.stop_geom) AS segment_start_on_stop,
        ST_Equals(ST_EndPoint(rpa.geom), sjp.stop_geom) AS segment_end_on_stop,
        ST_Length(ST_Intersection(rpa.geom, sjp.junction_geom)) > 0.0 AS is_inner
    FROM stop_junction_pairs_with_counts sjp
    JOIN road_parts_with_azimuth rpa
      ON rpa.stop_id = sjp.stop_id
),
pair_counts AS (
    SELECT
        sbp.stop_id,
        sbp.junction_id,
        COUNT(*) FILTER (WHERE sbp.is_inner) AS count_highway_segs_inner,
        COUNT(*) FILTER (WHERE NOT sbp.is_inner) AS count_highway_segs_outer
    FROM segments_by_pair sbp
    GROUP BY sbp.stop_id, sbp.junction_id
),
segments_for_azimuth AS (
    SELECT
        sbp.stop_id,
        sbp.junction_id,
        sbp.segment_azimuth
    FROM segments_by_pair sbp
    JOIN pair_counts pc
      ON pc.stop_id = sbp.stop_id
     AND pc.junction_id = sbp.junction_id
    WHERE
        (pc.count_highway_segs_outer <= pc.count_highway_segs_inner AND NOT sbp.is_inner)
        OR
        (pc.count_highway_segs_outer > pc.count_highway_segs_inner AND sbp.is_inner)
),
pair_azimuth AS (
    SELECT
        sfa.stop_id,
        sfa.junction_id,
        ROUND(
            MOD(
                (DEGREES(
                    CASE
                        WHEN COUNT(*) = 1 THEN MAX(sfa.segment_azimuth)
                        ELSE ATAN2(AVG(SIN(sfa.segment_azimuth)), AVG(COS(sfa.segment_azimuth)))
                    END
                ) + 360.0)::numeric,
                360.0::numeric
            ),
            1
        )::double precision AS azimut_centerline
    FROM segments_for_azimuth sfa
    GROUP BY sfa.stop_id, sfa.junction_id
),

-- 5e) Highway direction at stop node (does centerline geometry run into or out of the junction?)
pair_highway_direction AS (
    WITH dir_flags AS (
        SELECT
            stop_id,
            junction_id,
            COUNT(*) FILTER (WHERE NOT is_inner) AS outer_count,
            BOOL_AND(segment_end_on_stop) FILTER (WHERE NOT is_inner) AS outer_all_end_on_stop,
            BOOL_AND(segment_start_on_stop) FILTER (WHERE NOT is_inner) AS outer_all_start_on_stop,
            COUNT(*) FILTER (WHERE is_inner) AS inner_count,
            BOOL_AND(segment_start_on_stop) FILTER (WHERE is_inner) AS inner_all_start_on_stop,
            BOOL_AND(segment_end_on_stop) FILTER (WHERE is_inner) AS inner_all_end_on_stop
        FROM segments_by_pair
        GROUP BY stop_id, junction_id
    )
    SELECT
        df.stop_id,
        df.junction_id,
        CASE
            -- prefer OUTER segments if they are consistent
            WHEN df.outer_count > 0
             AND (df.outer_all_end_on_stop OR df.outer_all_start_on_stop)
             AND NOT (df.outer_all_end_on_stop AND df.outer_all_start_on_stop)
            THEN CASE
                WHEN df.outer_all_end_on_stop THEN 'in'::text
                WHEN df.outer_all_start_on_stop THEN 'out'::text
                ELSE NULL::text
            END

            -- otherwise try INNER segments if they are consistent (note: mapping is inverted)
            WHEN df.inner_count > 0
             AND (df.inner_all_start_on_stop OR df.inner_all_end_on_stop)
             AND NOT (df.inner_all_start_on_stop AND df.inner_all_end_on_stop)
            THEN CASE
                WHEN df.inner_all_start_on_stop THEN 'in'::text
                WHEN df.inner_all_end_on_stop THEN 'out'::text
                ELSE NULL::text
            END

            ELSE NULL::text
        END AS highway_direction
    FROM dir_flags df
)
SELECT
    sbp.stop_id AS osm_id,
    sbp.osm_type,
    sbp.direction,
    sbp.temporary,
    sbp.stop_geom AS geom,
    sbp.junction_id,
    sbp.count_junctions,
    pc.count_highway_segs_inner,
    pc.count_highway_segs_outer,
    paz.azimut_centerline,
    phd.highway_direction
FROM (
    SELECT DISTINCT
        stop_id, osm_type, direction, temporary, stop_geom, junction_id, count_junctions
    FROM segments_by_pair
) sbp
JOIN pair_counts pc
  ON pc.stop_id = sbp.stop_id
 AND pc.junction_id = sbp.junction_id
LEFT JOIN pair_azimuth paz
  ON paz.stop_id = sbp.stop_id
 AND paz.junction_id = sbp.junction_id
LEFT JOIN pair_highway_direction phd
  ON phd.stop_id = sbp.stop_id
 AND phd.junction_id = sbp.junction_id
-- we only need the cases where the geometry direction matches the direction attribute of the stop node
WHERE NOT (
    (sbp.direction = 'forward'  AND phd.highway_direction = 'out')
 OR (sbp.direction = 'backward' AND phd.highway_direction = 'in')
);

DROP INDEX IF EXISTS stop_positions_junction_enriched_geom_idx;
CREATE INDEX stop_positions_junction_enriched_geom_idx ON stop_positions_junction_enriched USING GIST (geom);


-- 5f) Junction outline: real azimuth at stop nodes + outline preparation & grouping (no lanes yet)

-- 5f.1) Explode raw junction outlines into CCW segments (stable seg_idx_ccw)
DROP TABLE IF EXISTS junction_outline_segments_raw;
CREATE TABLE junction_outline_segments_raw AS
WITH outlines_raw AS (
    SELECT
        ja.junction_id,
        row_number() OVER (PARTITION BY ja.junction_id) AS fragment_id,
        (ST_Dump(ST_Boundary(ja.geom))).geom AS geom
    FROM junction_areas_filtered ja
),
segments_raw AS (
    SELECT
        o.junction_id,
        o.fragment_id,
        (ds).path[1] AS seg_idx_ccw,
        (ds).geom AS geom
    FROM outlines_raw o
    CROSS JOIN LATERAL ST_DumpSegments(o.geom) AS ds
    WHERE ST_GeometryType((ds).geom) = 'ST_LineString'
      AND ST_Length((ds).geom) > 0.02
),
annotated AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        geom,
        ST_StartPoint(geom) AS start_pt,
        ST_EndPoint(geom) AS end_pt,
        ST_Azimuth(ST_StartPoint(geom), ST_EndPoint(geom)) AS azimuth_rad
    FROM segments_raw
)
SELECT
    junction_id,
    fragment_id,
    seg_idx_ccw,
    geom,
    start_pt,
    end_pt,
    azimuth_rad,
    ROUND(
        MOD((DEGREES(azimuth_rad) + 360.0)::numeric, 360.0::numeric),
        1
    )::double precision AS azimuth_deg
FROM annotated;

DROP INDEX IF EXISTS junction_outline_segments_raw_geom_idx;
CREATE INDEX junction_outline_segments_raw_geom_idx ON junction_outline_segments_raw USING GIST (geom);


-- 5f.2) Real azimuth at stop node from outline direction at the stop (prev/next segment)
DROP TABLE IF EXISTS stop_positions_junction_outline_azimuth;
CREATE TABLE stop_positions_junction_outline_azimuth AS
WITH stop_base AS (
    SELECT
        sp.osm_id AS stop_id,
        sp.junction_id,
        sp.geom AS stop_geom,
        sp.azimut_centerline
    FROM stop_positions_junction_enriched sp
),
outline_candidates AS (
    SELECT
        sb.stop_id,
        sb.junction_id,
        seg.fragment_id,
        seg.seg_idx_ccw,
        seg.azimuth_deg,
        sb.azimut_centerline,
        LEAST(
            ABS(ATAN2(
                SIN(RADIANS(seg.azimuth_deg - MOD((sb.azimut_centerline + 90.0)::numeric, 360.0::numeric)::double precision)),
                COS(RADIANS(seg.azimuth_deg - MOD((sb.azimut_centerline + 90.0)::numeric, 360.0::numeric)::double precision))
            )),
            ABS(ATAN2(
                SIN(RADIANS(seg.azimuth_deg - MOD((sb.azimut_centerline + 270.0)::numeric, 360.0::numeric)::double precision)),
                COS(RADIANS(seg.azimuth_deg - MOD((sb.azimut_centerline + 270.0)::numeric, 360.0::numeric)::double precision))
            ))
        ) AS angle_diff_rad
    FROM stop_base sb
    JOIN junction_outline_segments_raw seg
      ON seg.junction_id = sb.junction_id
     AND (ST_Equals(seg.start_pt, sb.stop_geom) OR ST_Equals(seg.end_pt, sb.stop_geom))
),
picked AS (
    SELECT DISTINCT ON (stop_id, junction_id)
        stop_id,
        junction_id,
        azimuth_deg AS azimut_outline
    FROM outline_candidates
    ORDER BY stop_id, junction_id, angle_diff_rad ASC, seg_idx_ccw ASC
)
SELECT * FROM picked;

DROP INDEX IF EXISTS stop_positions_junction_outline_azimuth_stop_idx;
CREATE INDEX stop_positions_junction_outline_azimuth_stop_idx
    ON stop_positions_junction_outline_azimuth (stop_id, junction_id);

ALTER TABLE stop_positions_junction_enriched
    ADD COLUMN IF NOT EXISTS azimut_outline double precision;
UPDATE stop_positions_junction_enriched sp
SET azimut_outline = so.azimut_outline
FROM stop_positions_junction_outline_azimuth so
WHERE so.stop_id = sp.osm_id
  AND so.junction_id = sp.junction_id;


-- 5f.3) Apply kerb/landuse difference to segments (seg_idx_ccw stays stable; may duplicate after dump)
DROP TABLE IF EXISTS junction_outline_segments_diff;
CREATE TABLE junction_outline_segments_diff AS
WITH junction_kerb AS (
    SELECT
        ja.junction_id,
        ST_Buffer(ST_Collect(sub.geom), metres(0.01)) AS geom
    FROM junction_areas_filtered ja
    LEFT JOIN LATERAL (
        SELECT bw.geom
        FROM barrier_way bw
        WHERE bw.barrier = 'kerb'
          AND ST_DWithin(bw.geom, ja.geom, metres(0.5))
        UNION ALL
        SELECT (ST_Dump(ST_Boundary(bp.geom))).geom
        FROM barrier_polygon bp
        WHERE bp.barrier = 'kerb'
          AND ST_DWithin(bp.geom, ja.geom, metres(0.5))
    ) sub ON TRUE
    GROUP BY ja.junction_id
),
junction_landuse AS (
    SELECT
        ja.junction_id,
        ST_Union(l.geom) AS geom
    FROM junction_areas_filtered ja
    LEFT JOIN landuse l
      ON ST_DWithin(l.geom, ja.geom, metres(0.5))
    GROUP BY ja.junction_id
),
junction_restriction_marking AS (
    SELECT
        ja.junction_id,
        ST_Union(rmp.geom) AS geom
    FROM junction_areas_filtered ja
    LEFT JOIN road_marking_polygon rmp
      ON rmp.road_marking = 'restriction'
     AND ST_DWithin(rmp.geom, ja.geom, metres(0.5))
    GROUP BY ja.junction_id
),
diffed AS (
    SELECT
        seg.junction_id,
        seg.fragment_id,
        seg.seg_idx_ccw,
        seg.azimuth_deg,
        CASE
            WHEN k.geom IS NOT NULL THEN ST_Difference(seg.geom, k.geom)
            ELSE seg.geom
        END AS geom_kerb
    FROM junction_outline_segments_raw seg
    LEFT JOIN junction_kerb k
      ON k.junction_id = seg.junction_id
),
diffed2 AS (
    SELECT
        d.junction_id,
        d.fragment_id,
        d.seg_idx_ccw,
        d.azimuth_deg,
        CASE
            WHEN lu.geom IS NOT NULL THEN ST_Difference(d.geom_kerb, lu.geom)
            ELSE d.geom_kerb
        END AS geom
    FROM diffed d
    LEFT JOIN junction_landuse lu
      ON lu.junction_id = d.junction_id
),
diffed3 AS (
    SELECT
        d.junction_id,
        d.fragment_id,
        d.seg_idx_ccw,
        d.azimuth_deg,
        CASE
            WHEN rm.geom IS NOT NULL THEN ST_Difference(d.geom, rm.geom)
            ELSE d.geom
        END AS geom
    FROM diffed2 d
    LEFT JOIN junction_restriction_marking rm
      ON rm.junction_id = d.junction_id
),
dumped AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        azimuth_deg,
        (ST_Dump(geom)).geom AS geom
    FROM diffed3
)
SELECT
    junction_id,
    fragment_id,
    seg_idx_ccw,
    azimuth_deg,
    geom
FROM dumped
WHERE NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > metres(0.05);

DROP INDEX IF EXISTS junction_outline_segments_diff_geom_idx;
CREATE INDEX junction_outline_segments_diff_geom_idx ON junction_outline_segments_diff USING GIST (geom);


-- 5f.3b) Anchor groups (chain-based) directly after kerb/landuse punching
--
-- anchor_id groups segments into chains of consecutive seg_idx_ccw indices (ring),
-- separated by gaps caused by kerb/landuse punching. Only chains that touch at least
-- one stop node get an anchor_id. Numbering is unique per junction_id and starts at 1.
DROP TABLE IF EXISTS junction_outline_segments_diff_anchored;
CREATE TABLE junction_outline_segments_diff_anchored AS
WITH
present_idx AS (
    SELECT DISTINCT
        junction_id,
        fragment_id,
        seg_idx_ccw
    FROM junction_outline_segments_diff
),
seg_max AS (
    SELECT
        junction_id,
        fragment_id,
        MAX(seg_idx_ccw) AS seg_idx_max
    FROM junction_outline_segments_raw
    GROUP BY junction_id, fragment_id
),
ordered_increasing AS (
    SELECT
        p.*,
        LEAD(p.seg_idx_ccw) OVER (
            PARTITION BY p.junction_id, p.fragment_id
            ORDER BY p.seg_idx_ccw
        ) AS next_idx
    FROM present_idx p
),
first_last AS (
    SELECT
        junction_id,
        fragment_id,
        MIN(seg_idx_ccw) AS first_idx,
        MAX(seg_idx_ccw) AS last_idx
    FROM present_idx
    GROUP BY junction_id, fragment_id
),
gaps AS (
    SELECT
        o.junction_id,
        o.fragment_id,
        o.seg_idx_ccw AS gap_from,
        o.next_idx AS gap_to,
        (o.next_idx - o.seg_idx_ccw - 1) AS gap_len
    FROM ordered_increasing o
    WHERE o.next_idx IS NOT NULL

    UNION ALL

    SELECT
        fl.junction_id,
        fl.fragment_id,
        fl.last_idx AS gap_from,
        fl.first_idx AS gap_to,
        (fl.first_idx + sm.seg_idx_max - fl.last_idx - 1) AS gap_len
    FROM first_last fl
    JOIN seg_max sm
      ON sm.junction_id = fl.junction_id
     AND sm.fragment_id = fl.fragment_id
),
anchor_idx AS (
    SELECT DISTINCT ON (junction_id, fragment_id)
        junction_id,
        fragment_id,
        gap_to AS anchor_idx
    FROM gaps
    ORDER BY
        junction_id,
        fragment_id,
        gap_len DESC,
        gap_to ASC
),
anchor_idx_fallback AS (
    SELECT
        fl.junction_id,
        fl.fragment_id,
        COALESCE(ai.anchor_idx, fl.first_idx) AS anchor_idx
    FROM first_last fl
    LEFT JOIN anchor_idx ai
      ON ai.junction_id = fl.junction_id
     AND ai.fragment_id = fl.fragment_id
),
ordered_cyclic AS (
    SELECT
        p.junction_id,
        p.fragment_id,
        p.seg_idx_ccw,
        a.anchor_idx,
        ROW_NUMBER() OVER (
            PARTITION BY p.junction_id, p.fragment_id
            ORDER BY
                CASE WHEN p.seg_idx_ccw >= a.anchor_idx THEN 0 ELSE 1 END,
                p.seg_idx_ccw
        ) AS cyc_pos
    FROM present_idx p
    JOIN anchor_idx_fallback a
      ON a.junction_id = p.junction_id
     AND a.fragment_id = p.fragment_id
),
with_prev AS (
    SELECT
        o.*,
        LAG(o.seg_idx_ccw) OVER (
            PARTITION BY o.junction_id, o.fragment_id
            ORDER BY o.cyc_pos
        ) AS prev_idx
    FROM ordered_cyclic o
),
chains AS (
    SELECT
        wp.junction_id,
        wp.fragment_id,
        wp.seg_idx_ccw,
        (
            SUM(
                CASE
                    WHEN wp.prev_idx IS NULL THEN 0
                    WHEN wp.seg_idx_ccw = wp.prev_idx + 1 THEN 0
                    -- wrap-around adjacency on the ring: max -> 1 is consecutive
                    WHEN wp.prev_idx = sm.seg_idx_max AND wp.seg_idx_ccw = 1 THEN 0
                    ELSE 1
                END
            ) OVER (
                PARTITION BY wp.junction_id, wp.fragment_id
                ORDER BY wp.cyc_pos
            ) + 1
        )::int AS chain_id
    FROM with_prev wp
    JOIN seg_max sm
      ON sm.junction_id = wp.junction_id
     AND sm.fragment_id = wp.fragment_id
),
anchored_chains AS (
    SELECT
        c.junction_id,
        c.fragment_id,
        c.chain_id,
        EXISTS (
            SELECT 1
            FROM chains c2
            JOIN junction_outline_segments_diff seg
              ON seg.junction_id = c2.junction_id
             AND seg.fragment_id = c2.fragment_id
             AND seg.seg_idx_ccw = c2.seg_idx_ccw
            JOIN stop_positions_junction_enriched sp
              ON sp.junction_id = seg.junction_id
             AND ST_Intersects(seg.geom, sp.geom)
            WHERE c2.junction_id = c.junction_id
              AND c2.fragment_id = c.fragment_id
              AND c2.chain_id = c.chain_id
        ) AS has_anchor
    FROM (SELECT DISTINCT junction_id, fragment_id, chain_id FROM chains) c
),
anchor_ids AS (
    SELECT
        ac.junction_id,
        ac.fragment_id,
        ac.chain_id,
        DENSE_RANK() OVER (
            PARTITION BY ac.junction_id
            ORDER BY ac.fragment_id, ac.chain_id
        )::int AS anchor_id
    FROM anchored_chains ac
    WHERE ac.has_anchor
),
idx_to_anchor AS (
    SELECT
        c.junction_id,
        c.fragment_id,
        c.seg_idx_ccw,
        ai.anchor_id
    FROM chains c
    JOIN anchor_ids ai
      ON ai.junction_id = c.junction_id
     AND ai.fragment_id = c.fragment_id
     AND ai.chain_id = c.chain_id
)
SELECT
    d.*,
    a.anchor_id
FROM junction_outline_segments_diff d
LEFT JOIN idx_to_anchor a
  ON a.junction_id = d.junction_id
 AND a.fragment_id = d.fragment_id
 AND a.seg_idx_ccw = d.seg_idx_ccw
;

DROP INDEX IF EXISTS junction_outline_segments_diff_anchored_geom_idx;
CREATE INDEX junction_outline_segments_diff_anchored_geom_idx
    ON junction_outline_segments_diff_anchored USING GIST (geom);


-- 5f.4) Assign each remaining segment to one stop-node/azimuth group (±25° around azimut_outline)
DROP TABLE IF EXISTS junction_outline_segments_grouped;
CREATE TABLE junction_outline_segments_grouped AS
WITH seg_max AS (
    SELECT
        junction_id,
        fragment_id,
        MAX(seg_idx_ccw) AS seg_idx_max
    FROM junction_outline_segments_raw
    GROUP BY junction_id, fragment_id
),
stop_anchor_ids AS (
    SELECT DISTINCT
        sp.junction_id,
        sp.osm_id AS stop_id,
        seg.anchor_id
    FROM stop_positions_junction_enriched sp
    JOIN junction_outline_segments_diff_anchored seg
      ON seg.junction_id = sp.junction_id
     AND seg.anchor_id IS NOT NULL
     AND ST_Intersects(seg.geom, sp.geom)
),
segment_stop_matches AS (
    SELECT
        seg.junction_id,
        seg.fragment_id,
        seg.seg_idx_ccw,
        seg.azimuth_deg,
        seg.geom,
        seg.anchor_id,
        sp.osm_id AS group_key,
        sp.geom AS stop_geom,
        ST_Distance(sp.geom, seg.geom) AS dist,
        ABS(ATAN2(
            SIN(RADIANS(seg.azimuth_deg - sp.azimut_outline)),
            COS(RADIANS(seg.azimuth_deg - sp.azimut_outline))
        )) AS angle_diff_rad
    FROM junction_outline_segments_diff_anchored seg
    JOIN stop_positions_junction_enriched sp
      ON sp.junction_id = seg.junction_id
     AND sp.azimut_outline IS NOT NULL
    WHERE seg.anchor_id IS NOT NULL
      AND EXISTS (
          SELECT 1
          FROM stop_anchor_ids sai
          WHERE sai.junction_id = seg.junction_id
            AND sai.stop_id = sp.osm_id
            AND sai.anchor_id = seg.anchor_id
      )
      AND ABS(ATAN2(
            SIN(RADIANS(seg.azimuth_deg - sp.azimut_outline)),
            COS(RADIANS(seg.azimuth_deg - sp.azimut_outline))
        )) <= RADIANS(25)
),
picked AS (
    SELECT DISTINCT ON (junction_id, fragment_id, seg_idx_ccw, ST_AsBinary(geom))
        junction_id,
        fragment_id,
        seg_idx_ccw,
        azimuth_deg,
        geom,
        anchor_id,
        group_key
    FROM segment_stop_matches
    ORDER BY junction_id, fragment_id, seg_idx_ccw, ST_AsBinary(geom),
             dist ASC, angle_diff_rad ASC, group_key ASC
),
grp AS (
    SELECT
        p.*,
        LEAD(p.seg_idx_ccw) OVER (
            PARTITION BY p.junction_id, p.fragment_id, p.group_key
            ORDER BY p.seg_idx_ccw
        ) AS next_idx
    FROM picked p
),
first_last AS (
    SELECT
        junction_id, fragment_id, group_key,
        MIN(seg_idx_ccw) AS first_idx,
        MAX(seg_idx_ccw) AS last_idx
    FROM grp
    GROUP BY junction_id, fragment_id, group_key
),
gaps AS (
    SELECT
        g.junction_id, g.fragment_id, g.group_key,
        g.seg_idx_ccw AS gap_from,
        g.next_idx AS gap_to,
        (g.next_idx - g.seg_idx_ccw - 1) AS gap_len
    FROM grp g
    WHERE g.next_idx IS NOT NULL

    UNION ALL

    SELECT
        fl.junction_id, fl.fragment_id, fl.group_key,
        fl.last_idx AS gap_from,
        fl.first_idx AS gap_to,
        (fl.first_idx + sm.seg_idx_max - fl.last_idx - 1) AS gap_len
    FROM first_last fl
    JOIN seg_max sm
      ON sm.junction_id = fl.junction_id
     AND sm.fragment_id = fl.fragment_id
),
anchor AS (
    SELECT DISTINCT ON (junction_id, fragment_id, group_key)
        junction_id, fragment_id, group_key,
        gap_to AS anchor_idx
    FROM gaps
    ORDER BY junction_id, fragment_id, group_key,
             gap_len DESC,
             gap_to ASC
),
ranked AS (
    SELECT
        p.junction_id,
        p.fragment_id,
        p.seg_idx_ccw,
        p.azimuth_deg,
        p.geom,
        p.anchor_id,
        p.group_key,
        ROW_NUMBER() OVER (
            PARTITION BY p.junction_id, p.fragment_id, p.group_key
            ORDER BY
                CASE WHEN p.seg_idx_ccw >= a.anchor_idx THEN 0 ELSE 1 END,
                p.seg_idx_ccw
        ) AS group_id
    FROM picked p
    JOIN anchor a
      ON a.junction_id = p.junction_id
     AND a.fragment_id = p.fragment_id
     AND a.group_key = p.group_key
)
SELECT * FROM ranked;

DROP INDEX IF EXISTS junction_outline_segments_grouped_geom_idx;
CREATE INDEX junction_outline_segments_grouped_geom_idx ON junction_outline_segments_grouped USING GIST (geom);

-- 5f.5) Keep grouped outline segments (no split by both_ways lanes)
DROP TABLE IF EXISTS junction_outline_segments_grouped_split;
CREATE TABLE junction_outline_segments_grouped_split AS
SELECT
    g.junction_id,
    g.fragment_id,
    g.seg_idx_ccw,
    g.azimuth_deg,
    g.anchor_id,
    g.group_key,
    g.group_id,
    g.geom
FROM junction_outline_segments_grouped g
WHERE NOT ST_IsEmpty(g.geom)
  AND ST_GeometryType(g.geom) = 'ST_LineString'
  AND ST_Length(g.geom) > metres(0.02);

DROP INDEX IF EXISTS junction_outline_segments_grouped_split_geom_idx;
CREATE INDEX junction_outline_segments_grouped_split_geom_idx
    ON junction_outline_segments_grouped_split USING GIST (geom);


-- 5f.5b) Normalize lanes: split any non-forward/backward lane into two offset half-width lanes
--         This is used only for the following steps; the original lanes table remains unchanged.
DROP TABLE IF EXISTS lanes_directional_tmp;
CREATE TABLE lanes_directional_tmp AS
WITH base AS (
    SELECT *
    FROM lanes
),
fw_bw AS (
    SELECT
        l.osm_id,
        l.direction,
        l.width,
        l.type,
        l.class,
        l.geom
    FROM base l
    WHERE l.direction IN ('forward', 'backward')
),
other AS (
    SELECT
        l.osm_id,
        l.direction,
        l.width,
        l.type,
        l.class,
        l.geom
    FROM base l
    WHERE l.direction IS NULL OR l.direction NOT IN ('forward', 'backward')
),
split_forward AS (
    SELECT
        o.osm_id,
        'forward'::text AS direction,
        (o.width / 2.0)::double precision AS width,
        o.type,
        o.class,
        line_offset(o.geom, (o.width / 4.0)::double precision) AS geom
    FROM other o
    WHERE o.geom IS NOT NULL
      AND NOT ST_IsEmpty(o.geom)
      AND o.width IS NOT NULL
      AND o.width > 0
),
split_backward AS (
    SELECT
        o.osm_id,
        'backward'::text AS direction,
        (o.width / 2.0)::double precision AS width,
        o.type,
        o.class,
        line_offset(o.geom, -(o.width / 4.0)::double precision) AS geom
    FROM other o
    WHERE o.geom IS NOT NULL
      AND NOT ST_IsEmpty(o.geom)
      AND o.width IS NOT NULL
      AND o.width > 0
)
SELECT osm_id, direction, width, type, class, geom FROM fw_bw
UNION ALL
SELECT osm_id, direction, width, type, class, geom FROM split_forward
UNION ALL
SELECT osm_id, direction, width, type, class, geom FROM split_backward
;

DROP INDEX IF EXISTS lanes_directional_tmp_geom_idx;
CREATE INDEX lanes_directional_tmp_geom_idx ON lanes_directional_tmp USING GIST (geom);


-- 5f.6) For each junction-outline stop-line candidate, count lanes by direction (forward/backward)
DROP TABLE IF EXISTS junction_outline_stop_line_candidates_lane_counts;
CREATE TABLE junction_outline_stop_line_candidates_lane_counts AS
SELECT
    c.*,
    COALESCE(lc.lanes_forward, 0)  AS lanes_forward,
    COALESCE(lc.lanes_backward, 0) AS lanes_backward
FROM junction_outline_segments_grouped_split c
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE l.direction = 'forward')::int  AS lanes_forward,
        COUNT(*) FILTER (WHERE l.direction = 'backward')::int AS lanes_backward
    FROM lanes_directional_tmp l
    WHERE l.direction IN ('forward', 'backward')
      AND NOT (l.type = 'parking' AND l.class IS DISTINCT FROM 'lane')
      AND ST_Intersects(l.geom, c.geom)
) lc ON TRUE;

DROP INDEX IF EXISTS junction_outline_stop_line_candidates_lane_counts_geom_idx;
CREATE INDEX junction_outline_stop_line_candidates_lane_counts_geom_idx
    ON junction_outline_stop_line_candidates_lane_counts USING GIST (geom);


-- 5f.7) Split candidates touched by forward + backward lanes "between directions" (proportional to lane widths)
DROP TABLE IF EXISTS junction_outline_segments_split;
CREATE TABLE junction_outline_segments_split AS
WITH
base AS (
    SELECT *
    FROM junction_outline_stop_line_candidates_lane_counts c
),
lane_hits_raw AS (
    SELECT
        c.junction_id,
        c.fragment_id,
        c.seg_idx_ccw,
        c.group_key,
        c.group_id,
        c.geom AS seg_geom,
        l.direction AS lane_direction,
        COALESCE(l.width, 0.0)::double precision AS lane_width,
        ST_Intersection(c.geom, l.geom) AS hit_geom
    FROM base c
    JOIN lanes_directional_tmp l
      ON l.direction IN ('forward', 'backward')
     AND NOT (l.type = 'parking' AND l.class IS DISTINCT FROM 'lane')
     AND ST_Intersects(l.geom, c.geom)
),
lane_hit_points AS (
    -- intersection points
    SELECT
        r.junction_id,
        r.fragment_id,
        r.seg_idx_ccw,
        r.group_key,
        r.group_id,
        r.seg_geom,
        r.lane_direction,
        r.lane_width,
        (dp).geom::geometry(Point) AS hit_pt
    FROM lane_hits_raw r
    CROSS JOIN LATERAL (
        SELECT (ST_Dump(ST_CollectionExtract(r.hit_geom, 1))).geom
    ) dp
    WHERE r.hit_geom IS NOT NULL
      AND NOT ST_IsEmpty(r.hit_geom)

    UNION ALL

    -- overlap lines: take endpoints as touch points
    SELECT
        r.junction_id,
        r.fragment_id,
        r.seg_idx_ccw,
        r.group_key,
        r.group_id,
        r.seg_geom,
        r.lane_direction,
        r.lane_width,
        ST_StartPoint((dl).geom)::geometry(Point) AS hit_pt
    FROM lane_hits_raw r
    CROSS JOIN LATERAL (
        SELECT (ST_Dump(ST_CollectionExtract(r.hit_geom, 2))).geom
    ) dl
    WHERE r.hit_geom IS NOT NULL
      AND NOT ST_IsEmpty(r.hit_geom)

    UNION ALL

    SELECT
        r.junction_id,
        r.fragment_id,
        r.seg_idx_ccw,
        r.group_key,
        r.group_id,
        r.seg_geom,
        r.lane_direction,
        r.lane_width,
        ST_EndPoint((dl).geom)::geometry(Point) AS hit_pt
    FROM lane_hits_raw r
    CROSS JOIN LATERAL (
        SELECT (ST_Dump(ST_CollectionExtract(r.hit_geom, 2))).geom
    ) dl
    WHERE r.hit_geom IS NOT NULL
      AND NOT ST_IsEmpty(r.hit_geom)
),
hits_located AS (
    SELECT
        h.junction_id,
        h.fragment_id,
        h.seg_idx_ccw,
        h.group_key,
        h.group_id,
        h.lane_direction,
        h.lane_width,
        ST_LineLocatePoint(h.seg_geom, h.hit_pt)::double precision AS frac,
        h.seg_geom
    FROM lane_hit_points h
    WHERE h.hit_pt IS NOT NULL
      AND NOT ST_IsEmpty(h.hit_pt)
),
tp AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        group_key,
        group_id,
        lane_direction,
        lane_width,
        (ROUND(frac::numeric, 5))::double precision AS frac,
        seg_geom
    FROM hits_located
    WHERE lane_direction IN ('forward', 'backward')
      AND frac IS NOT NULL
),
segments_with_multi_tp AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        group_key,
        group_id
    FROM tp
    GROUP BY junction_id, fragment_id, seg_idx_ccw, group_key, group_id
    HAVING COUNT(DISTINCT frac) >= 2
),
-- pick ONE representative touchpoint per fraction (widest wins)
tp_one_per_frac AS (
    SELECT DISTINCT ON (junction_id, fragment_id, seg_idx_ccw, group_key, group_id, frac)
        junction_id,
        fragment_id,
        seg_idx_ccw,
        group_key,
        group_id,
        frac,
        lane_direction,
        lane_width,
        seg_geom
    FROM tp
    ORDER BY
        junction_id, fragment_id, seg_idx_ccw, group_key, group_id, frac,
        lane_width DESC, lane_direction ASC
),
ordered AS (
    SELECT
        t.*,
        LAG(t.frac) OVER w AS prev_frac,
        LAG(t.lane_direction) OVER w AS prev_dir,
        LAG(t.lane_width) OVER w AS prev_width
    FROM tp_one_per_frac t
    JOIN segments_with_multi_tp ms
      ON ms.junction_id = t.junction_id
     AND ms.fragment_id = t.fragment_id
     AND ms.seg_idx_ccw = t.seg_idx_ccw
     AND ms.group_key = t.group_key
     AND ms.group_id = t.group_id
    WINDOW w AS (
        PARTITION BY t.junction_id, t.fragment_id, t.seg_idx_ccw, t.group_key, t.group_id
        ORDER BY t.frac ASC
    )
),
events AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        group_key,
        group_id,
        prev_width,
        lane_width AS next_width,
        prev_frac,
        frac AS next_frac,
        CASE
            WHEN prev_frac IS NULL OR frac IS NULL OR frac <= prev_frac THEN NULL::double precision
            WHEN NULLIF(prev_width + lane_width, 0.0) IS NULL
            THEN (prev_frac + (frac - prev_frac) * 0.5)::double precision
            ELSE (prev_frac + (frac - prev_frac) * (prev_width / NULLIF(prev_width + lane_width, 0.0)))::double precision
        END AS split_frac_raw,
        seg_geom
    FROM ordered
    WHERE prev_frac IS NOT NULL
      AND frac IS NOT NULL
      AND frac > prev_frac
),
split_blades AS (
    SELECT
        e.junction_id,
        e.fragment_id,
        e.seg_idx_ccw,
        e.group_key,
        e.group_id,
        ST_MakeLine(
            ST_Translate(
                ST_LineInterpolatePoint(
                    e.seg_geom,
                    GREATEST(0.00001, LEAST(0.99999, e.split_frac_raw))
                ),
                0.0, metres(0.1)
            ),
            ST_Translate(
                ST_LineInterpolatePoint(
                    e.seg_geom,
                    GREATEST(0.00001, LEAST(0.99999, e.split_frac_raw))
                ),
                0.0, metres(-0.1)
            )
        ) AS blade_geom
    FROM events e
    WHERE e.split_frac_raw IS NOT NULL
),
blades_per_seg AS (
    SELECT
        junction_id,
        fragment_id,
        seg_idx_ccw,
        group_key,
        group_id,
        ST_UnaryUnion(ST_Collect(blade_geom)) AS blade_geom
    FROM split_blades
    GROUP BY junction_id, fragment_id, seg_idx_ccw, group_key, group_id
),
split_raw AS (
    SELECT
        b.junction_id,
        b.fragment_id,
        b.seg_idx_ccw,
        b.azimuth_deg,
        b.anchor_id,
        b.group_key,
        b.group_id,
        ST_Split(b.geom, blades.blade_geom) AS geom
    FROM base b
    JOIN blades_per_seg blades
      ON blades.junction_id = b.junction_id
     AND blades.fragment_id = b.fragment_id
     AND blades.seg_idx_ccw = b.seg_idx_ccw
     AND blades.group_key = b.group_key
     AND blades.group_id = b.group_id
),
split_dumped AS (
    SELECT
        r.junction_id,
        r.fragment_id,
        r.seg_idx_ccw,
        r.azimuth_deg,
        r.anchor_id,
        r.group_key,
        r.group_id,
        (dp).geom AS geom
    FROM split_raw r
    CROSS JOIN LATERAL ST_Dump(r.geom) dp
),
split_valid AS (
    SELECT *
    FROM split_dumped
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_GeometryType(geom) = 'ST_LineString'
      AND ST_Length(geom) > metres(0.02)
)
-- unchanged segments: only those without split result
SELECT
    b.junction_id,
    b.fragment_id,
    b.seg_idx_ccw,
    b.azimuth_deg,
    b.anchor_id,
    b.group_key,
    b.group_id,
    b.geom
FROM base b
WHERE NOT EXISTS (
    SELECT 1
    FROM split_valid sv
    WHERE sv.junction_id = b.junction_id
      AND sv.fragment_id = b.fragment_id
      AND sv.seg_idx_ccw = b.seg_idx_ccw
      AND sv.group_key = b.group_key
      AND sv.group_id = b.group_id
)

UNION ALL

-- split parts
SELECT
    sv.junction_id,
    sv.fragment_id,
    sv.seg_idx_ccw,
    sv.azimuth_deg,
    sv.anchor_id,
    sv.group_key,
    sv.group_id,
    sv.geom
FROM split_valid sv
;

DROP INDEX IF EXISTS junction_outline_segments_split_geom_idx;
CREATE INDEX junction_outline_segments_split_geom_idx
    ON junction_outline_segments_split USING GIST (geom);


-- 5g) Lane-touch classification and filtering of junction-outline segments
--
-- lanes_touch:
-- - untouched: no lane intersects
-- - forward: only forward lanes intersect
-- - backward: only backward lanes intersect
-- - mixed: both forward and backward lanes intersect
--
-- Filtering:
-- 1) For untouched segments: drop if a higher group_id in same (junction_id, anchor_id, group_key) has lanes_touch
--    forward/backward that contradicts the stop node direction.
-- 2) Drop direction-mismatching segments (stop node direction vs lanes_touch forward/backward)
-- 3) If a forward/backward segment is invalid by lane-azimuth check, also drop the contiguous
--    untouched prefix immediately before it (same junction_id, fragment_id, group_key).
--
-- lanes_azimuth:
-- - circular mean of lane azimuths at the touch point(s), in degrees 0..360
DROP TABLE IF EXISTS junction_outline_segments_with_touch;
CREATE TABLE junction_outline_segments_with_touch AS
WITH seg AS (
    SELECT
        s.*,
        sp.direction AS stop_dir
    FROM junction_outline_segments_split s
    LEFT JOIN stop_positions_junction_enriched sp
      ON sp.junction_id = s.junction_id
     AND sp.osm_id = s.group_key
),
touch_flags AS (
    SELECT
        seg.*,
        EXISTS (
            SELECT 1
            FROM lanes_directional_tmp l
            WHERE l.direction = 'forward'
              AND ST_Intersects(l.geom, seg.geom)
        ) AS touch_forward,
        EXISTS (
            SELECT 1
            FROM lanes_directional_tmp l
            WHERE l.direction = 'backward'
              AND ST_Intersects(l.geom, seg.geom)
        ) AS touch_backward
    FROM seg
),
touch_labeled AS (
    SELECT
        tf.*,
        CASE
            WHEN NOT tf.touch_forward AND NOT tf.touch_backward THEN 'untouched'::text
            WHEN tf.touch_forward AND NOT tf.touch_backward THEN 'forward'::text
            WHEN NOT tf.touch_forward AND tf.touch_backward THEN 'backward'::text
            ELSE 'mixed'::text
        END AS lanes_touch
    FROM touch_flags tf
)
SELECT
    tf.*,
    az.lanes_azimuth
FROM touch_labeled tf
LEFT JOIN LATERAL (
    WITH params AS (
        SELECT
            0.001::double precision AS eps_m,
            0.05::double precision AS tangent_m,
            0.01::double precision AS df_max,
            0.000001::double precision AS df_min
    ),
    touched_lanes AS (
        SELECT
            l.osm_id AS lane_osm_id,
            l.geom AS lane_geom
        FROM lanes_directional_tmp l
        WHERE l.geom IS NOT NULL
          AND NOT ST_IsEmpty(l.geom)
          AND ST_Intersects(l.geom, tf.geom)
    ),
    hits_raw AS (
        SELECT
            tl.lane_osm_id,
            tl.lane_geom,
            ST_Intersection(tl.lane_geom, tf.geom) AS hit_geom
        FROM touched_lanes tl
    ),
    hit_points AS (
        -- intersection points
        SELECT
            r.lane_osm_id,
            r.lane_geom,
            (dp).geom::geometry(Point) AS hit_pt
        FROM hits_raw r
        CROSS JOIN LATERAL (
            SELECT (ST_Dump(ST_CollectionExtract(r.hit_geom, 1))).geom
        ) dp
        WHERE r.hit_geom IS NOT NULL
          AND NOT ST_IsEmpty(r.hit_geom)

        UNION ALL

        -- overlap lines: use midpoint as representative touch point
        SELECT
            r.lane_osm_id,
            r.lane_geom,
            ST_LineInterpolatePoint((dl).geom, 0.5)::geometry(Point) AS hit_pt
        FROM hits_raw r
        CROSS JOIN LATERAL (
            SELECT (ST_Dump(ST_CollectionExtract(r.hit_geom, 2))).geom
        ) dl
        WHERE r.hit_geom IS NOT NULL
          AND NOT ST_IsEmpty(r.hit_geom)
          AND ST_Length((dl).geom) > 0
    ),
    hit_points_valid AS (
        SELECT
            hp.lane_osm_id,
            hp.lane_geom,
            hp.hit_pt,
            ST_LineLocatePoint(hp.lane_geom, hp.hit_pt)::double precision AS frac,
            ST_NPoints(hp.lane_geom) AS npts,
            ST_Length(hp.lane_geom)::double precision AS lane_len
        FROM hit_points hp
        WHERE hp.hit_pt IS NOT NULL
          AND NOT ST_IsEmpty(hp.hit_pt)
    ),
    nearest_vertex AS (
        SELECT
            v.*,
            nv.idx AS nearest_idx,
            nv.pt AS nearest_pt,
            nv.dist_m AS dist_to_vertex_m
        FROM hit_points_valid v
        CROSS JOIN LATERAL (
            SELECT
                i AS idx,
                ST_PointN(v.lane_geom, i)::geometry(Point) AS pt,
                ST_Distance(v.hit_pt, ST_PointN(v.lane_geom, i))::double precision AS dist_m
            FROM generate_series(1, v.npts) AS i
            ORDER BY dist_m ASC, i ASC
            LIMIT 1
        ) nv
    ),
    per_hit_az AS (
        SELECT
            nv.lane_osm_id,
            CASE
                WHEN nv.npts < 2 THEN NULL::double precision

                -- hit is (almost) exactly on a vertex
                WHEN nv.dist_to_vertex_m <= (SELECT eps_m FROM params) THEN
                    CASE
                        WHEN nv.nearest_idx <= 1 THEN
                            MOD((DEGREES(ST_Azimuth(
                                ST_PointN(nv.lane_geom, 1),
                                ST_PointN(nv.lane_geom, 2)
                            )) + 360.0)::numeric, 360.0::numeric)::double precision
                        WHEN nv.nearest_idx >= nv.npts THEN
                            MOD((DEGREES(ST_Azimuth(
                                ST_PointN(nv.lane_geom, nv.npts - 1),
                                ST_PointN(nv.lane_geom, nv.npts)
                            )) + 360.0)::numeric, 360.0::numeric)::double precision
                        ELSE
                            MOD((
                                DEGREES(ATAN2(
                                    SIN(RADIANS(DEGREES(ST_Azimuth(ST_PointN(nv.lane_geom, nv.nearest_idx - 1), ST_PointN(nv.lane_geom, nv.nearest_idx))))) +
                                    SIN(RADIANS(DEGREES(ST_Azimuth(ST_PointN(nv.lane_geom, nv.nearest_idx), ST_PointN(nv.lane_geom, nv.nearest_idx + 1))))),
                                    COS(RADIANS(DEGREES(ST_Azimuth(ST_PointN(nv.lane_geom, nv.nearest_idx - 1), ST_PointN(nv.lane_geom, nv.nearest_idx))))) +
                                    COS(RADIANS(DEGREES(ST_Azimuth(ST_PointN(nv.lane_geom, nv.nearest_idx), ST_PointN(nv.lane_geom, nv.nearest_idx + 1)))))
                                )) + 360.0
                            )::numeric, 360.0::numeric)::double precision
                    END

                -- hit is between vertices: local tangent via two interpolated points
                ELSE
                    (
                        WITH dff AS (
                            SELECT
                                LEAST(
                                    (SELECT df_max FROM params),
                                    GREATEST(
                                        (SELECT df_min FROM params),
                                        (SELECT tangent_m FROM params) / NULLIF(nv.lane_len, 0.0)
                                    )
                                ) AS df
                        ),
                        pts AS (
                            SELECT
                                ST_LineInterpolatePoint(
                                    nv.lane_geom,
                                    GREATEST(0.0, LEAST(1.0, nv.frac - (SELECT df FROM dff)))
                                ) AS p_before,
                                ST_LineInterpolatePoint(
                                    nv.lane_geom,
                                    GREATEST(0.0, LEAST(1.0, nv.frac + (SELECT df FROM dff)))
                                ) AS p_after
                        )
                        SELECT
                            MOD((DEGREES(ST_Azimuth(p_before, p_after)) + 360.0)::numeric, 360.0::numeric)::double precision
                        FROM pts
                    )
            END AS az_deg
        FROM nearest_vertex nv
    ),
    per_lane AS (
        SELECT
            lane_osm_id,
            MOD((
                DEGREES(ATAN2(AVG(SIN(RADIANS(az_deg))), AVG(COS(RADIANS(az_deg))))) + 360.0
            )::numeric, 360.0::numeric)::double precision AS lane_az_deg
        FROM per_hit_az
        WHERE az_deg IS NOT NULL
        GROUP BY lane_osm_id
    )
    SELECT
        MOD((
            DEGREES(ATAN2(AVG(SIN(RADIANS(lane_az_deg))), AVG(COS(RADIANS(lane_az_deg))))) + 360.0
        )::numeric, 360.0::numeric)::double precision AS lanes_azimuth
    FROM per_lane
) az ON TRUE
;

DROP TABLE IF EXISTS junction_outline_segments_filtered;
CREATE TABLE junction_outline_segments_filtered AS
WITH base AS (
    SELECT *
    FROM junction_outline_segments_with_touch
),
untouched_filtered AS (
    SELECT *
    FROM base b
    WHERE NOT (
        b.lanes_touch = 'untouched'
        AND EXISTS (
            SELECT 1
            FROM base bx
            WHERE bx.junction_id = b.junction_id
              AND bx.anchor_id IS NOT DISTINCT FROM b.anchor_id
              AND bx.group_key = b.group_key
              AND bx.group_id > b.group_id
              AND bx.lanes_touch IN ('forward', 'backward')
              AND bx.lanes_touch IS DISTINCT FROM b.stop_dir
        )
    )
),
direction_filtered AS (
    SELECT *
    FROM untouched_filtered b
    WHERE NOT (
        (b.stop_dir = 'forward'  AND b.lanes_touch = 'backward')
     OR (b.stop_dir = 'backward' AND b.lanes_touch = 'forward')
    )
),
invalid_segments AS (
    -- Segments that would be filtered out by the lane-azimuth plausibility check
    SELECT
        b.junction_id,
        b.fragment_id,
        b.group_key,
        b.group_id
    FROM direction_filtered b
    WHERE b.lanes_touch IN ('forward', 'backward')
      AND b.lanes_azimuth IS NOT NULL
      AND (
            (
                b.lanes_touch = 'forward'
                AND ABS(DEGREES(ATAN2(
                    SIN(RADIANS(
                        b.lanes_azimuth
                        - (MOD((b.azimuth_deg - 90.0 + 360.0)::numeric, 360.0::numeric))::double precision
                    )),
                    COS(RADIANS(
                        b.lanes_azimuth
                        - (MOD((b.azimuth_deg - 90.0 + 360.0)::numeric, 360.0::numeric))::double precision
                    ))
                ))) > 90.0
            )
         OR (
                b.lanes_touch = 'backward'
                AND ABS(DEGREES(ATAN2(
                    SIN(RADIANS(
                        (MOD((b.lanes_azimuth + 180.0)::numeric, 360.0::numeric))::double precision
                        - (MOD((b.azimuth_deg - 90.0 + 360.0)::numeric, 360.0::numeric))::double precision
                    )),
                    COS(RADIANS(
                        (MOD((b.lanes_azimuth + 180.0)::numeric, 360.0::numeric))::double precision
                        - (MOD((b.azimuth_deg - 90.0 + 360.0)::numeric, 360.0::numeric))::double precision
                    ))
                ))) > 90.0
            )
      )
),
untouched_before_invalid AS (
    -- contiguous untouched prefix immediately before an invalid segment:
    -- for u < i, there is no non-untouched segment between u and i
    SELECT u.*
    FROM direction_filtered u
    WHERE u.lanes_touch = 'untouched'
      AND EXISTS (
          SELECT 1
          FROM invalid_segments i
          WHERE i.junction_id = u.junction_id
            AND i.fragment_id = u.fragment_id
            AND i.group_key = u.group_key
            AND i.group_id > u.group_id
            AND NOT EXISTS (
                SELECT 1
                FROM direction_filtered mid
                WHERE mid.junction_id = u.junction_id
                  AND mid.fragment_id = u.fragment_id
                  AND mid.group_key = u.group_key
                  AND mid.group_id > u.group_id
                  AND mid.group_id < i.group_id
                  AND mid.lanes_touch <> 'untouched'
            )
      )
),
valid_filtered AS (
    SELECT *
    FROM direction_filtered b
    WHERE
        NOT EXISTS (
            SELECT 1
            FROM invalid_segments i
            WHERE i.junction_id = b.junction_id
              AND i.fragment_id = b.fragment_id
              AND i.group_key = b.group_key
              AND i.group_id = b.group_id
        )
        AND NOT EXISTS (
            SELECT 1
            FROM untouched_before_invalid u
            WHERE u.junction_id = b.junction_id
              AND u.fragment_id = b.fragment_id
              AND u.group_key = b.group_key
              AND u.group_id = b.group_id
        )
)
SELECT
    junction_id,
    fragment_id,
    seg_idx_ccw,
    azimuth_deg,
    anchor_id,
    group_key,
    group_id,
    lanes_touch,
    lanes_azimuth,
    stop_dir,
    geom
FROM valid_filtered
;

-- Sanity checks (run manually if needed):
-- 1) count how many were invalid by azimuth check:
--    SELECT COUNT(*) FROM invalid_segments;
-- 2) count untouched-prefix drops:
--    SELECT COUNT(*) FROM untouched_before_invalid;
-- 3) inspect examples:
--    SELECT u.junction_id, u.fragment_id, u.group_key, u.group_id
--    FROM untouched_before_invalid u
--    ORDER BY u.junction_id, u.fragment_id, u.group_key, u.group_id
--    LIMIT 50;

DROP INDEX IF EXISTS junction_outline_segments_filtered_geom_idx;
CREATE INDEX junction_outline_segments_filtered_geom_idx
    ON junction_outline_segments_filtered USING GIST (geom);


-- 5h) Finalize junction stop lines: merge connected segments per stop/junction and extend by 0.125 m
DROP TABLE IF EXISTS junction_outline_stop_lines_final;
CREATE TABLE junction_outline_stop_lines_final AS
WITH merged AS (
    SELECT
        s.junction_id,
        s.group_key AS stop_id,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(s.geom))) AS geom
    FROM junction_outline_segments_filtered s
    WHERE s.geom IS NOT NULL
      AND NOT ST_IsEmpty(s.geom)
    GROUP BY s.junction_id, s.group_key
),
dumped AS (
    SELECT
        m.junction_id,
        m.stop_id,
        (dp).geom AS geom
    FROM merged m
    CROSS JOIN LATERAL ST_Dump(m.geom) dp
),
valid AS (
    SELECT
        d.junction_id,
        d.stop_id,
        ST_LineExtend(d.geom, metres(0.125), metres(0.125)) AS geom
    FROM dumped d
    WHERE d.geom IS NOT NULL
      AND NOT ST_IsEmpty(d.geom)
      AND ST_GeometryType(d.geom) = 'ST_LineString'
      AND ST_Length(d.geom) > metres(0.05)
)
SELECT
    'stop_node_highway_area'::text AS source,
    'stop_line'::text AS road_marking,
    'N'::text AS osm_type,
    v.stop_id::bigint AS osm_id,
    v.junction_id::bigint AS osm_id_highway_area,
    NULL::int AS candidate_id,
    NULL::int AS seg_index,
    sp.direction AS direction_stop_node,
    'junction_outline'::text AS direction_lane,
    :'stop_line_stroke'::text AS stroke,
    :'stop_line_width'::double precision AS width,
    CASE
        WHEN sp.temporary = 'yes' THEN :'stop_line_colour_temporary'::text
        ELSE :'stop_line_colour'::text
    END AS colour,
    ja.layer,
    v.geom
FROM valid v
JOIN stop_positions_junction_enriched sp
  ON sp.junction_id = v.junction_id
 AND sp.osm_id = v.stop_id
JOIN junction_areas_filtered ja
  ON ja.junction_id = v.junction_id
WHERE NOT ST_IsEmpty(v.geom)
;

DROP INDEX IF EXISTS junction_outline_stop_lines_final_geom_idx;
CREATE INDEX junction_outline_stop_lines_final_geom_idx
    ON junction_outline_stop_lines_final USING GIST (geom);


-- 6) Merge derived stop lines into road_marking_way (replace output of previous runs of this script)
DELETE FROM road_marking_way
WHERE source IN (
    'stop_node_generic',
    'stop_node_generic_angled',
    'stop_node_generic_temporary',
    'stop_node_generic_angled_temporary',
    'stop_node_highway_area'
);

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
    geom
)
SELECT
    u.source,
    u.road_marking,
    u.osm_type,
    u.osm_id,
    u.stroke,
    NULL::text,
    NULL::text,
    NULL::text,
    u.width::real,
    NULL::real,
    u.colour,
    NULL::real,
    NULL::text,
    NULL::text,
    u.layer,
    (d).geom
FROM (
    SELECT source, road_marking, osm_type, osm_id, stroke, width, colour, layer, direction_stop_node, geom
    FROM highway_stop_lines_generic
    UNION ALL
    SELECT source, road_marking, osm_type, osm_id, stroke, width, colour, layer, direction_stop_node, geom
    FROM junction_outline_stop_lines_final
) u
CROSS JOIN LATERAL ST_Dump(u.geom) AS d
WHERE (d).geom IS NOT NULL
  AND NOT ST_IsEmpty((d).geom)
  AND ST_GeometryType((d).geom) = 'ST_LineString'
  AND ST_Length((d).geom) > 0;

-- 7) Drop intermediate tables (nothing retained)
DROP TABLE IF EXISTS junction_outline_stop_lines_final;
DROP TABLE IF EXISTS junction_outline_segments_filtered;
DROP TABLE IF EXISTS junction_outline_segments_with_touch;
DROP TABLE IF EXISTS junction_outline_segments_split;
DROP TABLE IF EXISTS junction_outline_stop_line_candidates_lane_counts;
DROP TABLE IF EXISTS lanes_directional_tmp;
DROP TABLE IF EXISTS junction_outline_segments_grouped_split;
DROP TABLE IF EXISTS junction_outline_segments_grouped;
DROP TABLE IF EXISTS junction_outline_segments_diff_anchored;
DROP TABLE IF EXISTS junction_outline_segments_diff;
DROP TABLE IF EXISTS stop_positions_junction_outline_azimuth;
DROP TABLE IF EXISTS junction_outline_segments_raw;
DROP TABLE IF EXISTS stop_positions_junction_enriched;
DROP TABLE IF EXISTS highway_stop_lines_generic;
DROP TABLE IF EXISTS highway_stop_lines_raw;
DROP TABLE IF EXISTS highways_with_turn;
DROP TABLE IF EXISTS stop_positions_junction;
DROP TABLE IF EXISTS stop_positions_centerline_prepared;
DROP TABLE IF EXISTS junction_outlines_filtered;
DROP TABLE IF EXISTS junction_areas_filtered;
DROP TABLE IF EXISTS junction_areas_pre_merge;
DROP TABLE IF EXISTS stop_positions_filtered;