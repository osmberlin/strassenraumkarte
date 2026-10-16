-- road_marking_lane_divider.sql — lane divider lines (Schmal-/Breitstrich) + barred_area Breitstrich + buffer edge
-- Depends on: lanes_clipped (road_marking_lanes_prepare.sql), lanes, highway,
--     highway_area + highway_areas (highway_area_centerline.sql)
-- Output: road_marking_way (lane_divider, barred_area lines)

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/line_offset.sql'
\i 'processing/sql/helper/highway_road_area.sql'

-- 2) Generate lane divider lines from lane attributes

DROP TABLE IF EXISTS _markings_raw;
CREATE TEMP TABLE _markings_raw AS
WITH lane_base AS (
    SELECT
        lc.osm_id,
        lc.lane_index,
        lc.type,
        l.direction,
        l.prev_osm_id,
        l.prev_lane_index,
        l.next_osm_id,
        l.next_lane_index,
        h."lane_markings:temporary" AS lane_markings_temporary,
        lc.width AS lane_width,
        lc.layer,
        lc.marking_left,
        lc.marking_right,
        lc.buffer_left,
        lc.buffer_right,
        lc.class AS lane_class,
        lc.geom AS lane_geom
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
    LEFT JOIN highway h
      ON h.segment_id = l.segment_id
    WHERE lc.class IS DISTINCT FROM 'crossing'
),
lane_marking_sides AS (
    SELECT
        osm_id,
        lane_index,
        type,
        direction,
        prev_osm_id,
        prev_lane_index,
        next_osm_id,
        next_lane_index,
        lane_markings_temporary,
        lane_width,
        layer,
        lane_class,
        lane_geom,
        'left'::text AS side,
        marking_left AS marking_value
    FROM lane_base
    WHERE marking_left IS NOT NULL
      AND marking_left NOT IN ('no', 'none')

    UNION ALL

    SELECT
        osm_id,
        lane_index,
        type,
        direction,
        prev_osm_id,
        prev_lane_index,
        next_osm_id,
        next_lane_index,
        lane_markings_temporary,
        lane_width,
        layer,
        lane_class,
        lane_geom,
        'right'::text AS side,
        marking_right AS marking_value
    FROM lane_base
    WHERE marking_right IS NOT NULL
      AND marking_right NOT IN ('no', 'none')
),
divider_markings AS (
    SELECT
        *,
        CASE
            WHEN marking_value LIKE '%line%' THEN 'line'
            WHEN marking_value = 'barred_area' THEN 'barred_area'
            ELSE 'skip'
        END AS marking_kind
    FROM lane_marking_sides
),
divider_lines AS (
    SELECT
        'lane_divider'::text AS road_marking,
        osm_id,
        lane_index,
        direction,
        prev_osm_id,
        prev_lane_index,
        next_osm_id,
        next_lane_index,
        lane_width,
        layer,
        type,
        side,
        marking_kind,
        CASE
            WHEN marking_kind = 'line' THEN regexp_replace(marking_value, '_line', '', 'g')
            WHEN marking_kind = 'barred_area' THEN 'solid'::text
        END AS stroke,
        NULL::text AS arrow,
        CASE
            WHEN marking_kind = 'barred_area' THEN :'wide_stroke_width'::numeric
            WHEN lane_class IN ('center_running', 'crossing') THEN :'wide_stroke_width'::numeric
            WHEN type = 'bus' THEN :'wide_stroke_width'::numeric
            WHEN type = 'bicycle'
             AND side = CASE WHEN direction = 'backward' THEN 'right' ELSE 'left' END
            THEN :'wide_stroke_width'::numeric
            WHEN type = 'bicycle'
             AND side = CASE WHEN direction = 'backward' THEN 'left' ELSE 'right' END
            THEN :'narrow_stroke_width'::numeric
            ELSE :'narrow_stroke_width'::numeric
        END AS width,
        CASE
            WHEN lane_markings_temporary = 'yes' THEN :'road_marking_temporary_colour'::text
            ELSE :'road_marking_default_colour'::text
        END AS colour,
        CASE
            WHEN direction = 'backward' THEN ST_Reverse(
                line_offset(
                    lane_geom,
                    -- Note: line_offset() uses normal = (tangent.y, -tangent.x), i.e. positive values shift to the RIGHT
                    -- of the line direction. Therefore, left = negative, right = positive.
                    CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
                    0.0
                )
            )
            ELSE line_offset(
                lane_geom,
                -- Note: line_offset() uses normal = (tangent.y, -tangent.x), i.e. positive values shift to the RIGHT
                -- of the line direction. Therefore, left = negative, right = positive.
                CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
                0.0
            )
        END AS geom
    FROM divider_markings
    WHERE marking_kind IN ('line', 'barred_area')
      AND lane_width IS NOT NULL
      AND lane_width > 0
      AND ST_NPoints(lane_geom) >= 2
),
crossing_obstacles AS (
    SELECT
        h.layer,
        h.width,
        h.geom
    FROM highway h
    WHERE h.type = 'service'
      AND h.geom IS NOT NULL
      AND NOT ST_IsEmpty(h.geom)
      AND ST_GeometryType(h.geom) = 'ST_LineString'
      AND h.width IS NOT NULL
      AND h.width > 0
),
-- Buffer-edge lane_divider only on lanes mostly lying on road carriageway areas
-- (mapped highway_area + centerline highway_areas with _highway_road_area values).
lane_road_overlap AS (
    SELECT
        lb.osm_id,
        lb.lane_index,
        CASE
            WHEN ST_Length(lb.lane_geom) <= 0 THEN 0.0
            WHEN ru.union_geom IS NULL OR ST_IsEmpty(ru.union_geom) THEN 0.0
            ELSE COALESCE(
                ST_Length(
                    ST_LineMerge(
                        ST_CollectionExtract(
                            ST_Intersection(lb.lane_geom, ru.union_geom),
                            2
                        )
                    )
                ),
                0.0
            ) / ST_Length(lb.lane_geom)
        END AS road_overlap_frac
    FROM lane_base lb
    LEFT JOIN LATERAL (
        SELECT ST_Union(parts.geom) AS union_geom
        FROM (
            SELECT ha.geom
            FROM highway_area ha
            INNER JOIN _highway_road_area rh
                ON rh.area_highway = ha."area:highway"
            WHERE ha.geom && lb.lane_geom
              AND ST_Intersects(ha.geom, lb.lane_geom)
              AND (lb.layer IS NULL OR ha.layer IS NOT DISTINCT FROM lb.layer)
            UNION ALL
            SELECT hac.geom
            FROM highway_areas hac
            INNER JOIN _highway_road_area rh
                ON rh.area_highway = hac.highway
            WHERE hac.geom && lb.lane_geom
              AND ST_Intersects(hac.geom, lb.lane_geom)
              AND (lb.layer IS NULL OR hac.layer IS NOT DISTINCT FROM lb.layer)
        ) parts
    ) ru ON true
),
buffer_edge_sides AS (
    SELECT
        lb.osm_id,
        lb.lane_index,
        lb.type,
        lb.direction,
        lb.prev_osm_id,
        lb.prev_lane_index,
        lb.next_osm_id,
        lb.next_lane_index,
        lb.lane_markings_temporary,
        lb.lane_width,
        lb.layer,
        lb.lane_class,
        lb.lane_geom,
        'left'::text AS side,
        lb.buffer_left AS buffer_side
    FROM lane_base lb
    INNER JOIN lane_road_overlap lro
        ON lro.osm_id = lb.osm_id
       AND lro.lane_index = lb.lane_index
    WHERE lb.buffer_left > :'buffer_lane_divider_min_m'::numeric
      AND (lb.marking_left IS NULL OR lb.marking_left = 'solid_line')
      AND lro.road_overlap_frac >= :'buffer_lane_divider_min_road_overlap_frac'::double precision

    UNION ALL

    SELECT
        lb.osm_id,
        lb.lane_index,
        lb.type,
        lb.direction,
        lb.prev_osm_id,
        lb.prev_lane_index,
        lb.next_osm_id,
        lb.next_lane_index,
        lb.lane_markings_temporary,
        lb.lane_width,
        lb.layer,
        lb.lane_class,
        lb.lane_geom,
        'right'::text AS side,
        lb.buffer_right AS buffer_side
    FROM lane_base lb
    INNER JOIN lane_road_overlap lro
        ON lro.osm_id = lb.osm_id
       AND lro.lane_index = lb.lane_index
    WHERE lb.buffer_right > :'buffer_lane_divider_min_m'::numeric
      AND (lb.marking_right IS NULL OR lb.marking_right = 'solid_line')
      AND lro.road_overlap_frac >= :'buffer_lane_divider_min_road_overlap_frac'::double precision
),
buffer_with_offset_distance AS (
    SELECT
        bes.*,
        lane_width / 2.0 + buffer_side AS offset_distance
    FROM buffer_edge_sides bes
    WHERE lane_width IS NOT NULL
      AND lane_width > 0
      AND ST_NPoints(lane_geom) >= 2
),
buffer_with_edge AS (
    SELECT
        bod.*,
        CASE
            WHEN direction = 'backward' THEN ST_Reverse(
                line_offset(
                    lane_geom,
                    CASE WHEN side = 'left' THEN -offset_distance ELSE offset_distance END,
                    0.0
                )
            )
            ELSE line_offset(
                lane_geom,
                CASE WHEN side = 'left' THEN -offset_distance ELSE offset_distance END,
                0.0
            )
        END AS edge_geom
    FROM buffer_with_offset_distance bod
),
buffer_with_edge_clipped AS (
    SELECT
        bwe.*,
        cz.zone_geom
    FROM buffer_with_edge bwe
    LEFT JOIN LATERAL (
        SELECT ST_Union(
            ST_Buffer(
                o.geom,
                metres(o.width) / 2.0,
                'endcap=flat join=round'
            )
        ) AS zone_geom
        FROM crossing_obstacles o
        WHERE bwe.layer IS NOT DISTINCT FROM o.layer
          AND bwe.lane_geom && ST_Expand(o.geom, metres(o.width / 2.0 + 0.001))
          AND (
              ST_Crosses(bwe.lane_geom, o.geom)
              OR ST_Touches(bwe.lane_geom, o.geom)
          )
    ) cz ON cz.zone_geom IS NOT NULL
       AND NOT ST_IsEmpty(cz.zone_geom)
),
buffer_edges_clipped AS (
    SELECT
        bwec.*,
        CASE
            WHEN bwec.zone_geom IS NOT NULL AND NOT ST_IsEmpty(bwec.zone_geom)
            THEN ST_Difference(bwec.edge_geom, bwec.zone_geom)
            ELSE bwec.edge_geom
        END AS clipped_edge_geom
    FROM buffer_with_edge_clipped bwec
),
buffer_edge_fragments AS (
    SELECT
        bec.osm_id,
        bec.lane_index,
        bec.type,
        bec.direction,
        bec.prev_osm_id,
        bec.prev_lane_index,
        bec.next_osm_id,
        bec.next_lane_index,
        bec.lane_markings_temporary,
        bec.lane_width,
        bec.layer,
        bec.side,
        (dp).geom::geometry(LineString) AS geom
    FROM buffer_edges_clipped bec
    CROSS JOIN LATERAL ST_Dump(bec.clipped_edge_geom) AS dp
    WHERE bec.clipped_edge_geom IS NOT NULL
      AND NOT ST_IsEmpty(bec.clipped_edge_geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom)
          >= metres(:'barred_area_crossing_min_fragment_length'::numeric)
),
buffer_edge_lines AS (
    SELECT
        'lane_divider'::text AS road_marking,
        osm_id,
        lane_index,
        direction,
        prev_osm_id,
        prev_lane_index,
        next_osm_id,
        next_lane_index,
        lane_width,
        layer,
        type,
        side,
        'buffer_edge'::text AS marking_kind,
        'solid'::text AS stroke,
        NULL::text AS arrow,
        :'narrow_stroke_width'::numeric AS width,
        CASE
            WHEN lane_markings_temporary = 'yes' THEN :'road_marking_temporary_colour'::text
            ELSE :'road_marking_default_colour'::text
        END AS colour,
        geom
    FROM buffer_edge_fragments
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_NPoints(geom) >= 2
)
SELECT
    *
FROM divider_lines

UNION ALL

SELECT
    *
FROM buffer_edge_lines;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id, lane_index);

-- Keep only proper LineStrings.
DELETE FROM _markings_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) <> 'ST_LineString';

----------------------------------------------------------------------
-- Remove barred_area Breitstrich lines where OSM feature polygon exists
-- (same overlap criteria as road_marking_barred_area.sql)
----------------------------------------------------------------------

DELETE FROM _markings_raw m
USING lanes_clipped lc
WHERE m.marking_kind = 'barred_area'
  AND lc.osm_id = m.osm_id
  AND lc.lane_index = m.lane_index
  AND CASE WHEN m.side = 'left' THEN lc.buffer_left ELSE lc.buffer_right END IS NOT NULL
  AND CASE WHEN m.side = 'left' THEN lc.buffer_left ELSE lc.buffer_right END > 0
  AND EXISTS (
      SELECT 1
      FROM LATERAL (
          SELECT ST_Buffer(
              m.geom,
              metres(CASE WHEN m.side = 'left' THEN lc.buffer_left ELSE lc.buffer_right END),
              CASE
                  WHEN m.direction = 'backward' THEN
                      CASE
                          WHEN m.side = 'left' THEN 'endcap=flat join=round side=right'
                          ELSE 'endcap=flat join=round side=left'
                      END
                  ELSE
                      CASE
                          WHEN m.side = 'left' THEN 'endcap=flat join=round side=left'
                          ELSE 'endcap=flat join=round side=right'
                      END
              END
          ) AS candidate_geom
      ) cand
      CROSS JOIN LATERAL (
          SELECT ST_Union(rmp.geom) AS features_geom
          FROM road_marking_polygon rmp
          WHERE rmp.source = 'osm_feature'
            AND rmp.road_marking IN ('restriction', 'barred_area')
            AND rmp.geom IS NOT NULL
            AND NOT ST_IsEmpty(rmp.geom)
            AND m.layer IS NOT DISTINCT FROM rmp.layer
            AND cand.candidate_geom && rmp.geom
            AND ST_Intersects(cand.candidate_geom, rmp.geom)
      ) feat
      CROSS JOIN LATERAL (
          SELECT
              ST_Area(cand.candidate_geom) AS candidate_area,
              2.0 * sqrt(
                  ST_Area(ST_MinimumBoundingCircle(cand.candidate_geom)) / pi()
              ) AS candidate_diameter,
              ST_Area(feat.features_geom) AS feature_area,
              2.0 * sqrt(
                  ST_Area(ST_MinimumBoundingCircle(feat.features_geom)) / pi()
              ) AS feature_diameter,
              ST_Area(ST_Intersection(cand.candidate_geom, feat.features_geom))
                  AS overlap_area
      ) metrics
      WHERE cand.candidate_geom IS NOT NULL
        AND NOT ST_IsEmpty(cand.candidate_geom)
        AND feat.features_geom IS NOT NULL
        AND NOT ST_IsEmpty(feat.features_geom)
        AND metrics.overlap_area > 0
        AND (
            (
                metrics.feature_area / NULLIF(metrics.candidate_area, 0)
                    BETWEEN 1.0
                        / :'barred_area_osm_feature_max_size_ratio'::double precision
                        AND :'barred_area_osm_feature_max_size_ratio'::double precision
                AND metrics.feature_diameter / NULLIF(metrics.candidate_diameter, 0)
                    BETWEEN 1.0
                        / :'barred_area_osm_feature_max_size_ratio'::double precision
                        AND :'barred_area_osm_feature_max_size_ratio'::double precision
            )
            OR metrics.overlap_area
                >= :'barred_area_osm_feature_overlap_min_frac'::double precision
                   * metrics.candidate_area
        )
  );

----------------------------------------------------------------------
-- 2.6) barred_area Breitstrich: dashed inside crossing/touching service-way corridors
--
-- Segments inside width/2 buffers around service highways that cross or touch the
-- source lane keep stroke dashed + dasharray_bicycle; outside remains solid.
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_raw_crossing;
CREATE TEMP TABLE _markings_raw_crossing AS
WITH
crossing_obstacles AS (
    SELECT
        h.layer,
        h.width,
        h.geom
    FROM highway h
    WHERE h.type = 'service'
      AND h.geom IS NOT NULL
      AND NOT ST_IsEmpty(h.geom)
      AND ST_GeometryType(h.geom) = 'ST_LineString'
      AND h.width IS NOT NULL
      AND h.width > 0
),
crossing_candidates AS (
    SELECT
        m.osm_id,
        m.lane_index,
        m.direction,
        m.prev_osm_id,
        m.prev_lane_index,
        m.next_osm_id,
        m.next_lane_index,
        m.lane_width,
        m.road_marking,
        m.type,
        m.side,
        m.stroke,
        m.width,
        m.arrow,
        m.colour,
        m.layer,
        m.geom,
        m.marking_kind,
        cz.zone_geom
    FROM _markings_raw m
    INNER JOIN lanes_clipped lc
        ON lc.osm_id = m.osm_id
       AND lc.lane_index = m.lane_index
    JOIN LATERAL (
        SELECT l2.geom AS lane_geom
        FROM lanes l2
        WHERE l2.osm_id = lc.osm_id
          AND l2.lane_index = lc.lane_index
          AND l2.geom && ST_Expand(lc.geom, metres(0.001))
          AND ST_DWithin(l2.geom, lc.geom, metres(0.001))
        ORDER BY ST_Length(ST_Intersection(l2.geom, lc.geom)) DESC,
                 ST_Length(lc.geom) DESC
        LIMIT 1
    ) lane_match ON true
    INNER JOIN LATERAL (
        SELECT ST_Union(
            ST_Buffer(
                o.geom,
                metres(o.width) / 2.0,
                'endcap=flat join=round'
            )
        ) AS zone_geom
        FROM crossing_obstacles o
        WHERE m.layer IS NOT DISTINCT FROM o.layer
          AND lane_match.lane_geom && ST_Expand(o.geom, metres(o.width / 2.0 + 0.001))
          AND (
              ST_Crosses(lane_match.lane_geom, o.geom)
              OR ST_Touches(lane_match.lane_geom, o.geom)
          )
    ) cz ON cz.zone_geom IS NOT NULL
       AND NOT ST_IsEmpty(cz.zone_geom)
    WHERE m.marking_kind = 'barred_area'
),
pass_through AS (
    SELECT
        m.osm_id,
        m.lane_index,
        m.direction,
        m.prev_osm_id,
        m.prev_lane_index,
        m.next_osm_id,
        m.next_lane_index,
        m.lane_width,
        m.road_marking,
        m.type,
        m.side,
        m.stroke,
        m.width,
        m.arrow,
        m.colour,
        m.layer,
        m.geom,
        NULL::text AS preset_dasharray
    FROM _markings_raw m
    WHERE m.marking_kind IS DISTINCT FROM 'barred_area'
       OR NOT EXISTS (
           SELECT 1
           FROM crossing_candidates cc
           WHERE cc.osm_id = m.osm_id
             AND cc.lane_index = m.lane_index
             AND cc.side = m.side
       )
),
inside_parts AS (
    SELECT
        cc.osm_id,
        cc.lane_index,
        cc.direction,
        cc.prev_osm_id,
        cc.prev_lane_index,
        cc.next_osm_id,
        cc.next_lane_index,
        cc.lane_width,
        cc.road_marking,
        cc.type,
        cc.side,
        'dashed'::text AS stroke,
        cc.width,
        cc.arrow,
        cc.colour,
        cc.layer,
        (dp).geom::geometry(LineString) AS geom,
        :'dasharray_bicycle'::text AS preset_dasharray
    FROM crossing_candidates cc
    CROSS JOIN LATERAL ST_Dump(ST_Intersection(cc.geom, cc.zone_geom)) AS dp
    WHERE (dp).geom IS NOT NULL
      AND NOT ST_IsEmpty((dp).geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom)
          >= metres(:'barred_area_crossing_min_fragment_length'::numeric)
),
outside_parts AS (
    SELECT
        cc.osm_id,
        cc.lane_index,
        cc.direction,
        cc.prev_osm_id,
        cc.prev_lane_index,
        cc.next_osm_id,
        cc.next_lane_index,
        cc.lane_width,
        cc.road_marking,
        cc.type,
        cc.side,
        'solid'::text AS stroke,
        cc.width,
        cc.arrow,
        cc.colour,
        cc.layer,
        (dp).geom::geometry(LineString) AS geom,
        NULL::text AS preset_dasharray
    FROM crossing_candidates cc
    CROSS JOIN LATERAL ST_Dump(ST_Difference(cc.geom, cc.zone_geom)) AS dp
    WHERE (dp).geom IS NOT NULL
      AND NOT ST_IsEmpty((dp).geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom)
          >= metres(:'barred_area_crossing_min_fragment_length'::numeric)
)
SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM pass_through

UNION ALL

SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM inside_parts

UNION ALL

SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM outside_parts;

DROP TABLE IF EXISTS _markings_raw;
ALTER TABLE _markings_raw_crossing RENAME TO _markings_raw;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id, lane_index);
CREATE INDEX _markings_raw_geom_idx ON _markings_raw USING GIST (geom);

----------------------------------------------------------------------
-- 2.7) Junction styling for dashed bicycle lane_divider
--
-- Inside highway_area junction polygons: wide stroke both sides,
-- dasharray_bicycle_crossing. If >= junction_bicycle_dashed_whole_line_frac
-- of the line lies in junction, style the whole line; otherwise split at
-- the polygon boundary (inside vs outside; outside keeps prior width/dash).
-- Only when the bicycle source lane centerline lies within
-- junction_bicycle_motorized_lane_distance of a vehicle/bus lane on
-- highway type road/motorway. lanes_clipped fragments are matched to
-- lanes segments spatially; the marking is tied to that segment centerline.
-- Runs before merge so per-segment osm_id and style attributes stay correct.
----------------------------------------------------------------------

DROP TABLE IF EXISTS _junction_area_union;
CREATE TEMP TABLE _junction_area_union AS
SELECT
    layer,
    ST_UnaryUnion(ST_Collect(geom)) AS geom
FROM highway_area ha
WHERE ha.type = 'junction'
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
GROUP BY layer;

CREATE INDEX _junction_area_union_geom_idx
    ON _junction_area_union USING GIST (geom);

DROP TABLE IF EXISTS _markings_raw_junction;
CREATE TEMP TABLE _markings_raw_junction AS
WITH
pass_through AS (
    SELECT
        m.osm_id,
        m.lane_index,
        m.direction,
        m.prev_osm_id,
        m.prev_lane_index,
        m.next_osm_id,
        m.next_lane_index,
        m.lane_width,
        m.road_marking,
        m.type,
        m.side,
        m.stroke,
        m.width,
        m.arrow,
        m.colour,
        m.layer,
        m.geom,
        m.preset_dasharray
    FROM _markings_raw m
    WHERE NOT (
        m.road_marking = 'lane_divider'
        AND m.type = 'bicycle'
        AND m.stroke LIKE '%dashed%'
        AND EXISTS (
            SELECT 1
            FROM lanes_clipped lc
            JOIN lanes l_bike
              ON l_bike.osm_id = lc.osm_id
             AND l_bike.lane_index = lc.lane_index
             AND l_bike.type = 'bicycle'
             AND l_bike.geom && ST_Expand(lc.geom, metres(0.001))
             AND ST_DWithin(l_bike.geom, lc.geom, metres(0.001))
            JOIN lanes l_rm
              ON l_bike.geom && ST_Expand(
                  l_rm.geom,
                  metres(:'junction_bicycle_motorized_lane_distance'::numeric)
              )
             AND ST_DWithin(
                  l_bike.geom,
                  l_rm.geom,
                  metres(:'junction_bicycle_motorized_lane_distance'::numeric)
              )
            JOIN highway h_rm
              ON h_rm.segment_id = l_rm.segment_id
            WHERE lc.osm_id = m.osm_id
              AND lc.lane_index = m.lane_index
              AND lc.type = 'bicycle'
              AND l_rm.type IN ('vehicle', 'bus')
              AND h_rm.type IN ('road', 'motorway')
              AND m.geom && l_bike.geom
              AND ST_DWithin(
                  m.geom,
                  l_bike.geom,
                  metres(lc.width / 2.0 + 0.001)
              )
        )
        AND EXISTS (
            SELECT 1
            FROM _junction_area_union ju
            WHERE m.layer IS NOT DISTINCT FROM ju.layer
              AND m.geom && ju.geom
              AND ST_Intersects(m.geom, ju.geom)
        )
    )
),
candidates AS (
    SELECT
        m.osm_id,
        m.lane_index,
        m.direction,
        m.prev_osm_id,
        m.prev_lane_index,
        m.next_osm_id,
        m.next_lane_index,
        m.lane_width,
        m.road_marking,
        m.type,
        m.side,
        m.stroke,
        m.width,
        m.arrow,
        m.colour,
        m.layer,
        m.geom,
        ju.geom AS junction_geom,
        ST_Length(ST_Intersection(m.geom, ju.geom)) AS inside_len,
        ST_Length(ST_Intersection(m.geom, ju.geom))
            / NULLIF(ST_Length(m.geom), 0) AS junction_frac
    FROM _markings_raw m
    INNER JOIN _junction_area_union ju
        ON m.layer IS NOT DISTINCT FROM ju.layer
       AND m.geom && ju.geom
       AND ST_Intersects(m.geom, ju.geom)
    WHERE m.road_marking = 'lane_divider'
      AND m.type = 'bicycle'
      AND m.stroke LIKE '%dashed%'
      AND EXISTS (
          SELECT 1
          FROM lanes_clipped lc
          JOIN lanes l_bike
            ON l_bike.osm_id = lc.osm_id
           AND l_bike.lane_index = lc.lane_index
           AND l_bike.type = 'bicycle'
           AND l_bike.geom && ST_Expand(lc.geom, metres(0.001))
           AND ST_DWithin(l_bike.geom, lc.geom, metres(0.001))
          JOIN lanes l_rm
            ON l_bike.geom && ST_Expand(
                l_rm.geom,
                metres(:'junction_bicycle_motorized_lane_distance'::numeric)
            )
           AND ST_DWithin(
                l_bike.geom,
                l_rm.geom,
                metres(:'junction_bicycle_motorized_lane_distance'::numeric)
            )
          JOIN highway h_rm
            ON h_rm.segment_id = l_rm.segment_id
          WHERE lc.osm_id = m.osm_id
            AND lc.lane_index = m.lane_index
            AND lc.type = 'bicycle'
            AND l_rm.type IN ('vehicle', 'bus')
            AND h_rm.type IN ('road', 'motorway')
            AND m.geom && l_bike.geom
            AND ST_DWithin(
                m.geom,
                l_bike.geom,
                metres(lc.width / 2.0 + 0.001)
            )
      )
),
whole_line AS (
    SELECT
        c.osm_id,
        c.lane_index,
        c.direction,
        c.prev_osm_id,
        c.prev_lane_index,
        c.next_osm_id,
        c.next_lane_index,
        c.lane_width,
        c.road_marking,
        c.type,
        c.side,
        c.stroke,
        :'wide_stroke_width'::numeric AS width,
        c.arrow,
        c.colour,
        c.layer,
        c.geom,
        :'dasharray_bicycle_crossing'::text AS preset_dasharray
    FROM candidates c
    WHERE c.junction_frac >= :'junction_bicycle_dashed_whole_line_frac'::numeric
),
split_candidates AS (
    SELECT c.*
    FROM candidates c
    WHERE c.junction_frac < :'junction_bicycle_dashed_whole_line_frac'::numeric
       OR c.junction_frac IS NULL
),
inside_parts AS (
    SELECT
        sc.osm_id,
        sc.lane_index,
        sc.direction,
        sc.prev_osm_id,
        sc.prev_lane_index,
        sc.next_osm_id,
        sc.next_lane_index,
        sc.lane_width,
        sc.road_marking,
        sc.type,
        sc.side,
        sc.stroke,
        :'wide_stroke_width'::numeric AS width,
        sc.arrow,
        sc.colour,
        sc.layer,
        (dp).geom::geometry(LineString) AS geom,
        :'dasharray_bicycle_crossing'::text AS preset_dasharray
    FROM split_candidates sc
    CROSS JOIN LATERAL ST_Dump(
        ST_Intersection(sc.geom, sc.junction_geom)
    ) AS dp
    WHERE (dp).geom IS NOT NULL
      AND NOT ST_IsEmpty((dp).geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom) >= metres(:'junction_bicycle_dashed_min_fragment_length'::numeric)
),
outside_parts AS (
    SELECT
        sc.osm_id,
        sc.lane_index,
        sc.direction,
        sc.prev_osm_id,
        sc.prev_lane_index,
        sc.next_osm_id,
        sc.next_lane_index,
        sc.lane_width,
        sc.road_marking,
        sc.type,
        sc.side,
        sc.stroke,
        sc.width,
        sc.arrow,
        sc.colour,
        sc.layer,
        (dp).geom::geometry(LineString) AS geom,
        NULL::text AS preset_dasharray
    FROM split_candidates sc
    CROSS JOIN LATERAL ST_Dump(
        ST_Difference(sc.geom, sc.junction_geom)
    ) AS dp
    WHERE (dp).geom IS NOT NULL
      AND NOT ST_IsEmpty((dp).geom)
      AND ST_GeometryType((dp).geom) = 'ST_LineString'
      AND ST_Length((dp).geom) >= metres(:'junction_bicycle_dashed_min_fragment_length'::numeric)
)
SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM pass_through

UNION ALL

SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM whole_line

UNION ALL

SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM inside_parts

UNION ALL

SELECT
    osm_id,
    lane_index,
    direction,
    prev_osm_id,
    prev_lane_index,
    next_osm_id,
    next_lane_index,
    lane_width,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    geom,
    preset_dasharray
FROM outside_parts;

DROP TABLE IF EXISTS _markings_raw;
ALTER TABLE _markings_raw_junction RENAME TO _markings_raw;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id, lane_index);
CREATE INDEX _markings_raw_geom_idx ON _markings_raw USING GIST (geom);


-- 3) Merge connected marking lines (shared helper)
\i 'processing/sql/helper/road_marking_merge_connected_markings.sql'

----------------------------------------------------------------------
-- 3.5) Trim small lane-divider overhangs past stop lines
--
-- Lane divider lines are generated by offsetting lane centerlines by width/2.
-- If stop lines are slightly skewed, the divider may extend a bit beyond the
-- stop line. We trim only the *tail* (end of the oriented line) when:
-- - the end point is close to a stop line
-- - the closest point on the divider to that stop line lies inside the line
-- - the portion behind the stop line is shorter than 2 meters
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_merged_trimmed;
CREATE TEMP TABLE _markings_merged_trimmed AS
WITH lane_dividers AS (
    SELECT
        m.osm_id,
        m.road_marking,
        m.type,
        m.side,
        m.stroke,
        m.width,
        m.arrow,
        m.colour,
        m.layer,
        m.preset_dasharray,
        m.geom
    FROM _markings_merged m
    WHERE m.road_marking = 'lane_divider'
),
candidates AS (
    SELECT
        ld.*,
        sl.geom AS stop_geom,
        CASE
            WHEN sl.geom IS NULL THEN NULL::double precision
            ELSE ST_LineLocatePoint(ld.geom, ST_ClosestPoint(ld.geom, sl.geom))
        END AS cut_frac,
        CASE
            WHEN sl.geom IS NULL THEN NULL::double precision
            ELSE ST_Distance(ST_EndPoint(ld.geom), sl.geom)
        END AS end_dist
    FROM lane_dividers ld
    LEFT JOIN LATERAL (
        SELECT geom
        FROM road_marking_way sl
        WHERE sl.road_marking = 'stop_line'
          AND sl.source IN (
              'stop_node_generic',
              'stop_node_generic_angled',
              'stop_node_highway_area'
          )
          AND ST_DWithin(ST_EndPoint(ld.geom), sl.geom, metres(3.0))
        ORDER BY ST_EndPoint(ld.geom) <-> sl.geom
        LIMIT 1
    ) sl ON true
),
cut AS (
    SELECT
        *,
        CASE
            WHEN cut_frac IS NULL THEN NULL::geometry(LineString)
            ELSE ST_LineSubstring(geom, GREATEST(0.0, LEAST(1.0, cut_frac)), 1.0)
        END AS tail_geom,
        CASE
            WHEN cut_frac IS NULL THEN geom
            ELSE ST_LineSubstring(geom, 0.0, GREATEST(0.0, LEAST(1.0, cut_frac)))
        END AS head_geom
    FROM candidates
),
fixed AS (
    SELECT
        osm_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        CASE
            WHEN cut_frac IS NOT NULL
             AND cut_frac > 0.01
             AND cut_frac < 0.999
             AND end_dist <= metres(3.0)
             AND tail_geom IS NOT NULL
             AND ST_Length(tail_geom) < metres(2.0)
            THEN head_geom
            ELSE geom
        END::geometry(LineString) AS geom
    FROM cut
)
SELECT
    m.osm_id,
    m.road_marking,
    m.type,
    m.side,
    m.stroke,
    m.width,
    m.arrow,
    m.colour,
    m.layer,
    m.preset_dasharray,
    m.geom
FROM _markings_merged m
WHERE m.road_marking IS DISTINCT FROM 'lane_divider'

UNION ALL

SELECT
    osm_id,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    preset_dasharray,
    geom
FROM fixed
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString';

CREATE INDEX _markings_merged_trimmed_geom_idx ON _markings_merged_trimmed USING GIST (geom);


----------------------------------------------------------------------
-- 3.6) Split dashed lane dividers at all stop lines
--
-- Divider lines are oriented so ST_EndPoint lies toward the intersection (see §2).
-- All road_marking_way stop_line rows (generic, junction outline, etc.).
-- MIN(cut_frac) over all hits: one dashed [0..min_cut] + one solid [min_cut..1].
-- Solid tail only if its length is in [0.3, lane_divider_stop_solid_max_length) m; otherwise
-- the whole line stays dashed (avoids long false "junction" solid runs).
-- Replaces the original line (no duplicate rows).
-- No split (entire line stays dashed) when the divider intersects a highway_area
-- polygon with type=junction and markings=yes — same
-- convention as lanes_clipped / highway_junctions_clipping_areas_markings_yes.
-- DISABLED — re-enable block below if needed.
/*
----------------------------------------------------------------------

DROP TABLE IF EXISTS _stop_lines_lane_split;
CREATE TEMP TABLE _stop_lines_lane_split AS
SELECT
    row_number() OVER ()::bigint AS sl_id,
    w.geom::geometry(LineString) AS geom
FROM road_marking_way w
WHERE w.road_marking = 'stop_line'
  AND w.geom IS NOT NULL
  AND NOT ST_IsEmpty(w.geom)
  AND ST_GeometryType(w.geom) = 'ST_LineString'
  AND ST_Length(w.geom) > metres(0.01);

CREATE INDEX _stop_lines_lane_split_geom_idx
    ON _stop_lines_lane_split USING GIST (geom);

DROP TABLE IF EXISTS _markings_merged_trimmed_split;
CREATE TEMP TABLE _markings_merged_trimmed_split AS
WITH
pass_through AS (
    SELECT
        osm_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        geom
    FROM _markings_merged_trimmed
    WHERE road_marking IS DISTINCT FROM 'lane_divider'
       OR stroke IS DISTINCT FROM 'dashed'
),
dashed AS (
    SELECT
        row_number() OVER (ORDER BY osm_id, type, side, width, colour, layer, geom) AS div_id,
        osm_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        geom
    FROM _markings_merged_trimmed
    WHERE road_marking = 'lane_divider'
      AND stroke = 'dashed'
),
valid_cuts AS (
    SELECT DISTINCT
        d.div_id,
        ST_LineLocatePoint(d.geom, ST_ClosestPoint(d.geom, sl.geom)) AS cut_frac
    FROM dashed d
    INNER JOIN _stop_lines_lane_split sl
        ON ST_Intersects(d.geom, sl.geom)
    WHERE ST_LineLocatePoint(d.geom, ST_ClosestPoint(d.geom, sl.geom))
        > 0.01
      AND ST_LineLocatePoint(d.geom, ST_ClosestPoint(d.geom, sl.geom))
        < 0.99
),
min_cut AS (
    SELECT
        div_id,
        MIN(cut_frac) AS min_cut_frac
    FROM valid_cuts
    GROUP BY div_id
),
split_eligible AS (
    SELECT
        d.div_id,
        d.osm_id,
        d.road_marking,
        d.type,
        d.side,
        d.width,
        d.arrow,
        d.colour,
        d.layer,
        d.preset_dasharray,
        d.geom,
        mc.min_cut_frac
    FROM dashed d
    INNER JOIN min_cut mc
        ON mc.div_id = d.div_id
    CROSS JOIN LATERAL (
        SELECT ST_LineSubstring(d.geom, mc.min_cut_frac, 1.0)::geometry(LineString) AS tail_geom
    ) tail
    WHERE ST_Length(tail.tail_geom) >= metres(0.3)
      AND ST_Length(tail.tail_geom) < metres(:'lane_divider_stop_solid_max_length'::numeric)
      AND NOT EXISTS (
        SELECT 1
        FROM highway_area ha
        WHERE ha.geom && d.geom
          AND ha.geom IS NOT NULL
          AND NOT ST_IsEmpty(ha.geom)
          AND ST_Intersects(d.geom, ha.geom)
          AND ha.type = 'junction'
          AND ha.markings = 'yes'
    )
),
dashed_no_split AS (
    SELECT
        d.osm_id,
        d.road_marking,
        d.type,
        d.side,
        d.stroke,
        d.width,
        d.arrow,
        d.colour,
        d.layer,
        d.preset_dasharray,
        d.geom
    FROM dashed d
    WHERE NOT EXISTS (
        SELECT 1
        FROM split_eligible se
        WHERE se.div_id = d.div_id
    )
),
split_dashed_part AS (
    SELECT
        se.osm_id,
        se.road_marking,
        se.type,
        se.side,
        'dashed'::text AS stroke,
        se.width,
        se.arrow,
        se.colour,
        se.layer,
        se.preset_dasharray,
        ST_LineSubstring(se.geom, 0.0, se.min_cut_frac)::geometry(LineString) AS geom
    FROM split_eligible se
),
split_solid_part AS (
    SELECT
        se.osm_id,
        se.road_marking,
        se.type,
        se.side,
        'solid'::text AS stroke,
        se.width,
        se.arrow,
        se.colour,
        se.layer,
        NULL::text AS preset_dasharray,
        ST_LineSubstring(se.geom, se.min_cut_frac, 1.0)::geometry(LineString) AS geom
    FROM split_eligible se
),
split_two AS (
    SELECT
        osm_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        geom
    FROM split_dashed_part
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_GeometryType(geom) = 'ST_LineString'
      AND ST_Length(geom) >= metres(0.3)

    UNION ALL

    SELECT
        osm_id,
        road_marking,
        type,
        side,
        stroke,
        width,
        arrow,
        colour,
        layer,
        preset_dasharray,
        geom
    FROM split_solid_part
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_GeometryType(geom) = 'ST_LineString'
      AND ST_Length(geom) >= metres(0.3)
)
SELECT
    osm_id,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    preset_dasharray,
    geom
FROM pass_through

UNION ALL

SELECT
    osm_id,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    preset_dasharray,
    geom
FROM dashed_no_split
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'

UNION ALL

SELECT
    osm_id,
    road_marking,
    type,
    side,
    stroke,
    width,
    arrow,
    colour,
    layer,
    preset_dasharray,
    geom
FROM split_two;

DROP TABLE IF EXISTS _markings_merged_trimmed;
ALTER TABLE _markings_merged_trimmed_split RENAME TO _markings_merged_trimmed;

CREATE INDEX _markings_merged_trimmed_geom_idx ON _markings_merged_trimmed USING GIST (geom);
*/
----------------------------------------------------------------------
-- 4) Merge derived lane divider lines into road_marking_way
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
    'highway_attributes'::text,
    m.road_marking,
    'W'::text,
    m.osm_id,
    m.stroke,
    NULL::text,
    m.arrow,
    NULL::text,
    m.width::real,
    NULL::real,
    m.colour,
    NULL::real,
    m.type,
    NULL::text,
    m.layer,
    NULLIF(btrim(m.preset_dasharray), ''),
    m.geom
FROM _markings_merged_trimmed m
WHERE m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
;


-- Cleanup temporary tables
DROP TABLE IF EXISTS _markings_raw;
DROP TABLE IF EXISTS _markings_raw_seg;
DROP TABLE IF EXISTS _markings_endpoints;
DROP TABLE IF EXISTS _markings_merged;
DROP TABLE IF EXISTS _markings_merged_trimmed;
DROP TABLE IF EXISTS _junction_area_union;

