-- road_marking_crossing_edge.sql — crossing_edge from crossing lanes and cycleway boundaries
-- Depends on: lanes_clipped, highway_area (highway_area_centerline.sql)
-- Output: road_marking_way (crossing_edge); dasharray update on all road_marking_way rows

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/line_offset.sql'

----------------------------------------------------------------------
-- 2b) crossing_edge from centerline-derived crossing lanes (class=crossing)
--
-- Same offset logic as lane dividers, but road_marking=crossing_edge.
-- Centerline extended by crossing_extend at both ends before offset.
-- Exception: bicycle crossing lanes skip extend at an end when the
-- connected prev/next bicycle lane has marking_left or marking_right
-- not in (NULL, 'no', 'none').
-- Skip ways processed as separate OSM crossing lines in road_marking_crossing.sql
-- (type=path with class=crossing or crossing tags on the way).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _crossing_lane_edges_raw;
CREATE TEMP TABLE _crossing_lane_edges_raw AS
WITH lane_base AS (
    SELECT
        lc.osm_id,
        lc.lane_index,
        lc.type,
        lc.class AS lane_class,
        l.direction,
        l.prev_segment_id,
        l.prev_lane_index,
        l.next_segment_id,
        l.next_lane_index,
        lc.width AS lane_width,
        lc.layer,
        lc.marking_left,
        lc.marking_right,
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
    JOIN highway h
      ON h.segment_id = l.segment_id
    WHERE lc.class = 'crossing'
      AND NOT (
          h.type = 'path'
          AND (
              h.class = 'crossing'
              OR h."crossing" IN ('traffic_signals', 'marked', 'zebra')
              OR (
                  h."crossing:markings" IS NOT NULL
                  AND h."crossing:markings" NOT IN ('no', 'surface')
              )
              OR (
                  h."crossing_ref" IS NOT NULL
                  AND h."crossing_ref" NOT IN ('no', 'none')
              )
          )
      )
),
lane_with_extend AS (
    SELECT
        lb.*,
        (
            lb.type = 'bicycle'
            AND lb.lane_class = 'crossing'
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
            lb.type = 'bicycle'
            AND lb.lane_class = 'crossing'
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
    FROM lane_base lb
    LEFT JOIN lanes l_prev
        ON l_prev.segment_id = lb.prev_segment_id
       AND l_prev.lane_index = lb.prev_lane_index
    LEFT JOIN lanes l_next
        ON l_next.segment_id = lb.next_segment_id
       AND l_next.lane_index = lb.next_lane_index
),
lane_extended AS (
    SELECT
        lwe.*,
        -- ST_LineExtend: 1st arg = extend at line end, 2nd = extend at line start.
        -- forward: prev at start (entry), next at end (exit).
        -- backward: prev at end (entry), next at start (exit).
        ST_LineExtend(
            lwe.lane_geom,
            CASE
                WHEN lwe.direction = 'backward' THEN
                    CASE
                        WHEN lwe.block_extend_entry THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
                ELSE
                    CASE
                        WHEN lwe.block_extend_exit THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
            END,
            CASE
                WHEN lwe.direction = 'backward' THEN
                    CASE
                        WHEN lwe.block_extend_exit THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
                ELSE
                    CASE
                        WHEN lwe.block_extend_entry THEN 0.0
                        ELSE metres(:'crossing_extend'::double precision)
                    END
            END
        ) AS lane_geom_extended
    FROM lane_with_extend lwe
),
lane_marking_sides AS (
    SELECT
        osm_id,
        lane_index,
        type,
        direction,
        lane_width,
        layer,
        lane_geom_extended AS lane_geom,
        'left'::text AS side,
        marking_left AS marking_value
    FROM lane_extended
    WHERE marking_left IS NOT NULL
      AND marking_left NOT IN ('no', 'none')

    UNION ALL

    SELECT
        osm_id,
        lane_index,
        type,
        direction,
        lane_width,
        layer,
        lane_geom_extended AS lane_geom,
        'right'::text AS side,
        marking_right AS marking_value
    FROM lane_extended
    WHERE marking_right IS NOT NULL
      AND marking_right NOT IN ('no', 'none')
),
edge_markings AS (
    SELECT
        osm_id,
        lane_index,
        type,
        direction,
        lane_width,
        layer,
        side,
        CASE
            WHEN marking_value LIKE '%line%' THEN regexp_replace(marking_value, '_line', '', 'g')
            WHEN marking_value = 'barred_area' THEN 'solid'::text
        END AS stroke,
        lane_geom
    FROM lane_marking_sides
    WHERE marking_value LIKE '%line%'
       OR marking_value = 'barred_area'
)
SELECT
    osm_id,
    type,
    layer,
    COALESCE(stroke, 'dashed'::text) AS stroke,
    :'wide_stroke_width'::numeric AS width,
    :'road_marking_default_colour'::text AS colour,
    CASE
        WHEN direction = 'backward' THEN ST_Reverse(
            line_offset(
                lane_geom,
                CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
                0.0
            )
        )
        ELSE line_offset(
            lane_geom,
            CASE WHEN side = 'left' THEN -lane_width / 2.0 ELSE lane_width / 2.0 END,
            0.0
        )
    END AS geom
FROM edge_markings
WHERE lane_width IS NOT NULL
  AND lane_width > 0
  AND ST_NPoints(lane_geom) >= 2;

DELETE FROM _crossing_lane_edges_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) <> 'ST_LineString';

CREATE INDEX _crossing_lane_edges_raw_geom_idx
    ON _crossing_lane_edges_raw USING GIST (geom);
----------------------------------------------------------------------
-- 5) crossing_edge from area:highway=cycleway polygon boundaries (junction areas only)
--
-- Full boundary (exterior + interior rings), 2-point edges, drop edges
-- already covered by road_marking_way or barrier=kerb lines, merge per ring.
-- Keep only cycleways inside a junction: type=junction on the cycleway itself, or
-- positive-area overlap with a junction highway_area (boundary touch alone is not enough);
-- subtract ST_Boundary of non-junction highway_areas sharing an outline with the cycleway;
-- junction membership via EXISTS (not ST_Intersection — that splits boundary lines at polygon vertices).
----------------------------------------------------------------------

DROP TABLE IF EXISTS _cycleway_boundary_raw;
CREATE TEMP TABLE _cycleway_boundary_raw AS
WITH areas AS (
    SELECT
        ha.osm_type,
        ha.osm_id,
        ha.layer,
        ha.geom
    FROM highway_area ha
    WHERE ha."area:highway" = 'cycleway'
      AND ha.geom IS NOT NULL
      AND NOT ST_IsEmpty(ha.geom)
),
boundary_lines AS (
    SELECT
        a.osm_type,
        a.osm_id,
        a.layer,
        (bd).path[1] AS fragment_id,
        (bd).geom AS geom
    FROM areas a
    CROSS JOIN LATERAL ST_Dump(ST_Boundary(a.geom)) AS bd
    WHERE NOT ST_IsEmpty((bd).geom)
),
segments AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        fragment_id,
        (ds).path[1] AS seg_idx,
        (ds).geom AS geom
    FROM boundary_lines
    CROSS JOIN LATERAL ST_DumpSegments(geom) AS ds
    WHERE ST_GeometryType((ds).geom) = 'ST_LineString'
      AND ST_Length((ds).geom) > metres(:'cycleway_boundary_min_length'::numeric)
)
SELECT
    osm_type,
    osm_id,
    layer,
    fragment_id,
    seg_idx,
    geom
FROM segments;

CREATE INDEX _cycleway_boundary_raw_geom_idx
    ON _cycleway_boundary_raw USING GIST (geom);


DROP TABLE IF EXISTS _cycleway_boundary_deduped;
CREATE TEMP TABLE _cycleway_boundary_deduped AS
SELECT
    s.osm_type,
    s.osm_id,
    s.layer,
    s.fragment_id,
    s.seg_idx,
    s.geom
FROM _cycleway_boundary_raw s
WHERE NOT EXISTS (
    SELECT 1
    FROM road_marking_way rm
    WHERE rm.geom IS NOT NULL
      AND NOT ST_IsEmpty(rm.geom)
      AND ST_GeometryType(rm.geom) = 'ST_LineString'
      AND rm.geom && s.geom
      AND ST_Intersects(rm.geom, s.geom)
      AND ST_Covers(rm.geom, s.geom)
)
  AND NOT EXISTS (
    SELECT 1
    FROM barrier_way bw
    WHERE bw.barrier = 'kerb'
      AND bw.geom IS NOT NULL
      AND NOT ST_IsEmpty(bw.geom)
      AND ST_GeometryType(bw.geom) = 'ST_LineString'
      AND bw.geom && s.geom
      AND ST_Intersects(bw.geom, s.geom)
      AND ST_Covers(bw.geom, s.geom)
);


DROP TABLE IF EXISTS _cycleway_boundary_merged;
CREATE TEMP TABLE _cycleway_boundary_merged AS
WITH dissolved AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        fragment_id,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS geom
    FROM _cycleway_boundary_deduped
    GROUP BY osm_type, osm_id, layer, fragment_id
),
dumped AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        (d).geom AS geom
    FROM dissolved
    CROSS JOIN LATERAL ST_Dump(geom) AS d
    WHERE (d).geom IS NOT NULL
      AND NOT ST_IsEmpty((d).geom)
)
SELECT
    d.osm_type,
    d.osm_id,
    d.layer,
    d.geom::geometry(LineString) AS geom
FROM dumped d
WHERE ST_GeometryType(d.geom) = 'ST_LineString'
  AND ST_Length(d.geom) > metres(:'cycleway_boundary_min_length'::numeric);

CREATE INDEX _cycleway_boundary_merged_geom_idx
    ON _cycleway_boundary_merged USING GIST (geom);


DROP TABLE IF EXISTS _cycleway_boundary_junction_clipped;
CREATE TEMP TABLE _cycleway_boundary_junction_clipped AS
SELECT DISTINCT ON (d.osm_type, d.osm_id, d.layer, ST_AsBinary((frag).geom))
    d.osm_type,
    d.osm_id,
    d.layer,
    (frag).geom::geometry(LineString) AS geom
FROM _cycleway_boundary_merged d
INNER JOIN highway_area cycle
    ON cycle.osm_type = d.osm_type
   AND cycle.osm_id = d.osm_id
   AND cycle.layer IS NOT DISTINCT FROM d.layer
   AND cycle."area:highway" = 'cycleway'
CROSS JOIN LATERAL (
    SELECT ST_Union(ST_Boundary(other.geom)) AS other_boundary
    FROM highway_area other
    WHERE (other.type IS NULL OR other.type IS DISTINCT FROM 'junction')
      AND other.geom IS NOT NULL
      AND NOT ST_IsEmpty(other.geom)
      AND other.geom && cycle.geom
      AND ST_Intersects(ST_Boundary(cycle.geom), ST_Boundary(other.geom))
      AND NOT (other.osm_type = cycle.osm_type AND other.osm_id = cycle.osm_id)
      AND (d.layer IS NULL OR other.layer IS NOT DISTINCT FROM d.layer)
) others
CROSS JOIN LATERAL ST_Dump(
    CASE
        WHEN others.other_boundary IS NOT NULL
         AND NOT ST_IsEmpty(others.other_boundary)
        THEN ST_Difference(d.geom, others.other_boundary)
        ELSE d.geom
    END
) AS frag
WHERE (frag).geom IS NOT NULL
  AND NOT ST_IsEmpty((frag).geom)
  AND ST_GeometryType((frag).geom) = 'ST_LineString'
  AND ST_Length((frag).geom) > metres(:'cycleway_boundary_min_length'::numeric)
  AND (
      cycle.type = 'junction'
      OR EXISTS (
          SELECT 1
          FROM highway_area ha
          WHERE ha.type = 'junction'
            AND ha.geom IS NOT NULL
            AND NOT ST_IsEmpty(ha.geom)
            AND ha.geom && cycle.geom
            AND ST_Area(ST_Intersection(cycle.geom, ha.geom)) > 0
            AND NOT (ha.osm_type = cycle.osm_type AND ha.osm_id = cycle.osm_id)
            AND (d.layer IS NULL OR ha.layer IS NOT DISTINCT FROM d.layer)
      )
  )
  AND NOT EXISTS (
      SELECT 1
      FROM highway_area other
      WHERE (other.type IS NULL OR other.type IS DISTINCT FROM 'junction')
        AND other.geom IS NOT NULL
        AND NOT ST_IsEmpty(other.geom)
        AND other.geom && cycle.geom
        AND ST_Intersects(ST_Boundary(cycle.geom), ST_Boundary(other.geom))
        AND NOT (other.osm_type = cycle.osm_type AND other.osm_id = cycle.osm_id)
        AND (d.layer IS NULL OR other.layer IS NOT DISTINCT FROM d.layer)
        AND ST_Length(
            ST_Intersection((frag).geom, ST_Boundary(other.geom))
        ) > metres(:'cycleway_boundary_min_length'::numeric)
  )
ORDER BY d.osm_type, d.osm_id, d.layer, ST_AsBinary((frag).geom);

CREATE INDEX _cycleway_boundary_junction_clipped_geom_idx
    ON _cycleway_boundary_junction_clipped USING GIST (geom);
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
    'crossing_edge'::text,
    'W'::text,
    osm_id,
    stroke,
    NULL::text,
    NULL::text,
    NULL::text,
    width::real,
    NULL::real,
    colour,
    NULL::real,
    type,
    NULL::text,
    layer,
    CASE
        WHEN stroke LIKE '%dashed%' THEN :'dasharray_bicycle_crossing'::text
        ELSE NULL::text
    END,
    geom
FROM _crossing_lane_edges_raw
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
;

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
    'highway_area'::text,
    'crossing_edge'::text,
    osm_type,
    osm_id,
    'dashed'::text,
    NULL::text,
    NULL::text,
    NULL::text,
    :'wide_stroke_width'::real,
    NULL::real,
    :'road_marking_default_colour'::text,
    NULL::real,
    'bicycle'::text,
    NULL::text,
    layer,
    :'dasharray_bicycle_crossing'::text,
    geom
FROM _cycleway_boundary_junction_clipped
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
;


----------------------------------------------------------------------
-- 6) Set dasharray on all road_marking_way rows (OSM import + generated)
--
-- NULL when stroke has no 'dashed' and is not sharks_teeth; otherwise
-- keep OSM tag or apply defaults. Run after all inserts into this table.
----------------------------------------------------------------------

UPDATE road_marking_way rmw
SET dasharray = CASE
    WHEN (rmw.stroke IS NULL OR rmw.stroke NOT LIKE '%dashed%')
     AND (rmw.stroke IS NULL OR rmw.stroke IS DISTINCT FROM 'sharks_teeth')
    THEN NULL
    ELSE COALESCE(
        NULLIF(btrim(rmw.dasharray), ''),
        CASE
            WHEN rmw.road_marking = 'crossing_edge' THEN :'dasharray_crossing_edge'::text
            WHEN rmw.type = 'bicycle' THEN :'dasharray_bicycle'::text
            WHEN rmw.type = 'bus' THEN :'dasharray_bus'::text
            WHEN rmw.type = 'parking' THEN :'dasharray_parking'::text
            WHEN rmw.road_marking = 'stop_line' OR rmw.stroke = 'sharks_teeth'
            THEN :'dasharray_stop_line'::text
            WHEN rmw.road_marking = 'edge_line' THEN :'dasharray_edge_line'::text
            WHEN EXISTS (
                SELECT 1
                FROM highway h
                WHERE h.osm_id = rmw.osm_id
                  AND (
                      h.highway IN ('motorway', 'motorway_link')
                      OR (
                          h.highway = 'construction'
                          AND h.construction IN ('motorway', 'motorway_link')
                      )
                  )
            ) THEN :'dasharray_motorway'::text
            ELSE :'dasharray_default'::text
        END
    )
END;

----------------------------------------------------------------------
-- 6b) Motorway stroke widths (Schmal-/Breitstrich)
--
-- Remap generated and OSM-default widths on motorway / motorway_link
-- (incl. construction=*). Explicit OSM widths other than the defaults
-- stay unchanged.
----------------------------------------------------------------------

UPDATE road_marking_way rmw
SET width = CASE
    WHEN abs(rmw.width::double precision - :'narrow_stroke_width'::double precision) < 0.005
    THEN :'narrow_stroke_width_motorway'::real
    WHEN abs(rmw.width::double precision - :'wide_stroke_width'::double precision) < 0.005
    THEN :'wide_stroke_width_motorway'::real
    ELSE rmw.width
END
WHERE rmw.width IS NOT NULL
  AND (
      abs(rmw.width::double precision - :'narrow_stroke_width'::double precision) < 0.005
      OR abs(rmw.width::double precision - :'wide_stroke_width'::double precision) < 0.005
  )
  AND EXISTS (
      SELECT 1
      FROM highway h
      WHERE h.osm_id = rmw.osm_id
        AND (
            h.highway IN ('motorway', 'motorway_link')
            OR (
                h.highway = 'construction'
                AND h.construction IN ('motorway', 'motorway_link')
            )
        )
  );

-- Cleanup temporary tables
DROP TABLE IF EXISTS _crossing_lane_edges_raw;
DROP TABLE IF EXISTS _cycleway_boundary_raw;
DROP TABLE IF EXISTS _cycleway_boundary_deduped;
DROP TABLE IF EXISTS _cycleway_boundary_merged;
DROP TABLE IF EXISTS _cycleway_boundary_junction_clipped;

