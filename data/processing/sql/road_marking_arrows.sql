-- road_marking_arrows.sql — Turn-lane arrows + OSM arrow line → point conversion
-- Requires table lanes_clipped_for_arrows: run road_marking_lanes_prepare.sql once before this script
-- (see data/data_preparation.sh). Also requires lanes (prev/next, direction).
-- Requires road_marking_stop_lines.sql (temporary generic stop_lines:
--   source stop_node_generic_temporary / stop_node_generic_angled_temporary).
-- Output: road_marking_arrow_line (merged turn-lane centerlines, end_offset);
--         road_marking_node (turn-lane raster points + OSM arrow ways as midpoint points).

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


----------------------------------------------------------------------
-- 1) Turn-lane segments from lanes_clipped_for_arrows → _markings_raw
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_raw;
CREATE TEMP TABLE _markings_raw AS
SELECT
    'turn_lane_chain'::text AS road_marking,
    lc.osm_id,
    lc.lane_index,
    l.direction,
    l.prev_osm_id,
    l.prev_lane_index,
    l.next_osm_id,
    l.next_lane_index,
    lc.width AS lane_width,
    lc.type,
    NULL::text AS side,
    NULL::text AS stroke,
    NULL::numeric AS width,
    l.turn AS arrow,
    CASE
        WHEN hr."lane_markings:temporary" = 'yes' THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    lc.layer,
    NULL::text AS preset_dasharray,
    CASE
        WHEN l.direction = 'backward' THEN ST_Reverse(lc.geom)
        ELSE lc.geom
    END::geometry(LineString) AS geom
FROM lanes_clipped_for_arrows lc
INNER JOIN lanes l
    ON l.osm_id = lc.osm_id
   AND l.lane_index = lc.lane_index
INNER JOIN highway hr
    ON hr.osm_id = lc.osm_id
WHERE l.turn IS NOT NULL
  AND l.turn NOT IN ('no', 'none')
  AND NOT (
      l.type = 'bicycle'
      AND EXISTS (
          SELECT 1
          FROM lanes l2
          WHERE l2.osm_id = l.osm_id
            AND l2.type IS DISTINCT FROM 'bicycle'
      )
  )
  AND lc.geom IS NOT NULL
  AND NOT ST_IsEmpty(lc.geom)
  AND ST_GeometryType(lc.geom) = 'ST_LineString'
  AND ST_NPoints(lc.geom) >= 2;

CREATE INDEX _markings_raw_idx ON _markings_raw (road_marking, osm_id, lane_index);

DELETE FROM _markings_raw
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_GeometryType(geom) <> 'ST_LineString';


----------------------------------------------------------------------
-- 2) Merge connected segments (shared helper)
----------------------------------------------------------------------

\i 'processing/sql/helper/road_marking_merge_connected_markings.sql'


----------------------------------------------------------------------
-- 3) Persist merged lines → road_marking_arrow_line
----------------------------------------------------------------------

DROP TABLE IF EXISTS road_marking_arrow_line;

CREATE TABLE road_marking_arrow_line AS
SELECT
    row_number() OVER (
        ORDER BY m.osm_id, m.arrow, m.type, m.colour, ST_Length(m.geom) DESC
    )::bigint AS id,
    m.osm_id,
    m.arrow AS turn,
    m.type,
    m.colour,
    m.layer,
    0::double precision AS end_offset,
    m.geom::geometry(LineString) AS geom
FROM _markings_merged m
WHERE m.road_marking = 'turn_lane_chain'
  AND m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
  AND ST_GeometryType(m.geom) = 'ST_LineString'
  AND ST_NPoints(m.geom) >= 2;

CREATE INDEX road_marking_arrow_line_geom_idx
    ON road_marking_arrow_line USING GIST (geom);
CREATE INDEX road_marking_arrow_line_osm_id_idx
    ON road_marking_arrow_line (osm_id);


----------------------------------------------------------------------
-- 4) end_offset: signed distance from ST_EndPoint to nearest generic stop_line
----------------------------------------------------------------------

DROP TABLE IF EXISTS _stop_lines_generic;
CREATE TEMP TABLE _stop_lines_generic AS
SELECT
    row_number() OVER ()::bigint AS sl_id,
    w.geom::geometry(LineString) AS geom,
    sp.direction AS stop_direction
FROM road_marking_way w
INNER JOIN stop_positions sp
    ON sp.osm_id = w.osm_id
WHERE w.road_marking = 'stop_line'
  AND w.source IN (
      'stop_node_generic',
      'stop_node_generic_angled',
      'stop_node_generic_temporary',
      'stop_node_generic_angled_temporary'
  )
  AND w.geom IS NOT NULL
  AND NOT ST_IsEmpty(w.geom)
  AND ST_GeometryType(w.geom) = 'ST_LineString'
  AND ST_Length(w.geom) > metres(0.01);

CREATE INDEX _stop_lines_generic_geom_idx ON _stop_lines_generic USING GIST (geom);

DROP TABLE IF EXISTS _arrow_end;
CREATE TEMP TABLE _arrow_end AS
SELECT
    id AS arrow_id,
    osm_id,
    geom,
    ST_EndPoint(geom)::geometry(Point) AS end_pt
FROM road_marking_arrow_line;

CREATE INDEX _arrow_end_geom_idx ON _arrow_end USING GIST (geom);
CREATE INDEX _arrow_end_end_pt_idx ON _arrow_end USING GIST (end_pt);
CREATE INDEX _arrow_end_osm_id_idx ON _arrow_end (osm_id);

WITH
candidates_pre AS (
    -- Pre-selection: touch arrow, touch sibling arrow (same osm_id), or within 7.5 m of end
    SELECT
        a.arrow_id,
        a.end_pt,
        sl.sl_id,
        sl.geom AS sl_geom,
        sl.stop_direction
    FROM _arrow_end a
    INNER JOIN _stop_lines_generic sl
        ON ST_Intersects(sl.geom, a.geom)
        OR ST_DWithin(a.end_pt, sl.geom, metres(:'stop_line_candidate_max_dist'::double precision))
        OR EXISTS (
            SELECT 1
            FROM road_marking_arrow_line a2
            WHERE a2.osm_id = a.osm_id
              AND a2.id <> a.arrow_id
              AND ST_Intersects(sl.geom, a2.geom)
        )
),
candidates AS (
    -- Exclude stop_lines far from this arrow's end (e.g. sibling touch only, elsewhere on the way)
    SELECT
        p.arrow_id,
        p.sl_id,
        p.sl_geom,
        p.stop_direction,
        ST_Distance(p.end_pt, p.sl_geom) AS dist_m
    FROM candidates_pre p
    WHERE ST_DWithin(
        p.end_pt,
        p.sl_geom,
        metres(:'stop_line_max_end_dist'::double precision)
    )
),
best AS (
    SELECT DISTINCT ON (arrow_id)
        arrow_id,
        sl_geom,
        stop_direction,
        dist_m
    FROM candidates
    ORDER BY arrow_id, dist_m ASC
),
signed AS (
    -- Side of stop_line in geometry direction (ST_StartPoint -> ST_EndPoint).
    -- stop_direction=backward: bar was built for the opposite travel direction → flip sign.
    -- 2D cross (sl_end - sl_start) x (end_pt - sl_start): >0 left, <0 right of the bar.
    SELECT
        b.arrow_id,
        CASE
            WHEN flip.signed_cross_z = 0 THEN 0::double precision
            ELSE b.dist_m * (flip.signed_cross_z / ABS(flip.signed_cross_z))
        END AS end_offset
    FROM best b
    INNER JOIN _arrow_end a
        ON a.arrow_id = b.arrow_id
    CROSS JOIN LATERAL (
        SELECT
            ST_StartPoint(b.sl_geom)::geometry(Point) AS sl_start,
            ST_EndPoint(b.sl_geom)::geometry(Point) AS sl_end
    ) sl
    CROSS JOIN LATERAL (
        SELECT
            (ST_X(sl.sl_end) - ST_X(sl.sl_start)) * (ST_Y(a.end_pt) - ST_Y(sl.sl_start))
            - (ST_Y(sl.sl_end) - ST_Y(sl.sl_start)) * (ST_X(a.end_pt) - ST_X(sl.sl_start))
            AS cross_z
    ) side
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN b.stop_direction = 'backward' THEN -side.cross_z
            ELSE side.cross_z
        END AS signed_cross_z
    ) flip
    WHERE ST_Length(b.sl_geom) > metres(0.01)
)
UPDATE road_marking_arrow_line r
SET end_offset = s.end_offset
FROM signed s
WHERE r.id = s.arrow_id;


----------------------------------------------------------------------
-- 5) Turn arrow points along arrow lines → road_marking_node
----------------------------------------------------------------------

DELETE FROM road_marking_node
WHERE source = 'highway_turn_arrow';

INSERT INTO road_marking_node (
    source,
    road_marking,
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
    osm_type,
    osm_id,
    geom
)
WITH
params AS (
    SELECT
        metres(:'turn_arrow_start_offset'::double precision) AS first_offset_m,
        metres(:'turn_arrow_spacing'::double precision) AS spacing_m,
        metres(:'turn_arrow_spacing_motorway'::double precision) AS spacing_motorway_m,
        metres(:'turn_arrow_min_dist_from_end'::double precision) AS min_from_end_m,
        metres(:'turn_arrow_min_dist_from_start'::double precision) AS min_from_start_m,
        :'turn_arrow_length'::double precision AS arrow_len_m,
        :'turn_arrow_length_motorway'::double precision AS arrow_len_motorway_m,
        :'turn_arrow_length_bicycle'::double precision AS arrow_len_bicycle_m
),
arrow_frame AS (
    SELECT
        r.id AS arrow_id,
        r.osm_id,
        r.geom,
        r.turn,
        r.type,
        r.colour,
        r.layer,
        r.end_offset,
        ST_Length(r.geom) AS line_len,
        EXISTS (
            SELECT 1
            FROM highway h
            WHERE h.osm_id = r.osm_id
              AND (
                  h.highway IN ('motorway', 'motorway_link')
                  OR (
                      h.highway = 'construction'
                      AND h.construction IN ('motorway', 'motorway_link')
                  )
              )
        ) AS is_motorway
    FROM road_marking_arrow_line r
    WHERE r.geom IS NOT NULL
      AND NOT ST_IsEmpty(r.geom)
      AND ST_Length(r.geom) > metres(0.01)
),
-- Grid anchored at end_offset + 7.5 m from ST_EndPoint (toward ST_StartPoint).
-- Spacing 12 m, or 24 m on motorway/motorway_link (not bicycle).
-- Regular: anchor + k*spacing (k>=0). Extension: anchor - m*spacing (m>=1).
arrow_k AS (
    SELECT
        f.*,
        sp.spacing_m,
        p.min_from_end_m,
        p.min_from_start_m,
        CASE
            WHEN f.type = 'bicycle' THEN p.arrow_len_bicycle_m
            WHEN f.is_motorway THEN p.arrow_len_motorway_m
            ELSE p.arrow_len_m
        END AS arrow_len_m,
        f.end_offset + p.first_offset_m AS d_anchor,
        LEAST(
            40,
            GREATEST(
                0,
                ceil(
                    (f.line_len - p.min_from_start_m) / NULLIF(sp.spacing_m, 0)
                )::int + 2
            )
        ) AS k_max_reg,
        LEAST(
            40,
            GREATEST(
                0,
                floor(
                    (f.end_offset + p.first_offset_m - p.min_from_end_m)
                    / NULLIF(sp.spacing_m, 0)
                )::int
            )
        ) AS m_max_ext
    FROM arrow_frame f
    CROSS JOIN params p
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN f.type IS DISTINCT FROM 'bicycle' AND f.is_motorway
            THEN p.spacing_motorway_m
            ELSE p.spacing_m
        END AS spacing_m
    ) sp
),
arrow_pts_reg AS (
    SELECT
        k.arrow_id,
        k.osm_id,
        k.geom,
        k.turn,
        k.type,
        k.colour,
        k.layer,
        k.line_len,
        k.arrow_len_m,
        k.min_from_end_m,
        k.min_from_start_m,
        'reg'::text AS pt_kind,
        gs.k AS seq_k,
        k.d_anchor + gs.k * k.spacing_m AS d_from_end,
        1.0 - (k.d_anchor + gs.k * k.spacing_m) / k.line_len AS frac_along
    FROM arrow_k k
    CROSS JOIN LATERAL generate_series(0, k.k_max_reg) AS gs(k)
),
arrow_pts_ext AS (
    SELECT
        k.arrow_id,
        k.osm_id,
        k.geom,
        k.turn,
        k.type,
        k.colour,
        k.layer,
        k.line_len,
        k.arrow_len_m,
        k.min_from_end_m,
        k.min_from_start_m,
        'ext'::text AS pt_kind,
        gs.m AS seq_k,
        k.d_anchor - gs.m * k.spacing_m AS d_from_end,
        1.0 - (k.d_anchor - gs.m * k.spacing_m) / k.line_len AS frac_along
    FROM arrow_k k
    CROSS JOIN LATERAL generate_series(1, k.m_max_ext) AS gs(m)
    WHERE k.d_anchor > k.min_from_end_m
),
arrow_pts_raw AS (
    SELECT * FROM arrow_pts_reg
    UNION ALL
    SELECT * FROM arrow_pts_ext
),
arrow_pts_on_line AS (
    SELECT
        r.*,
        GREATEST(0.0, LEAST(1.0, r.frac_along)) AS frac_clamped,
        ST_LineInterpolatePoint(
            r.geom,
            GREATEST(0.0, LEAST(1.0, r.frac_along))
        )::geometry(Point) AS pt
    FROM arrow_pts_raw r
    WHERE r.d_from_end > 0
      AND r.d_from_end <= r.line_len
      AND (
          r.seq_k > 0
          OR r.d_from_end >= r.min_from_end_m
      )
),
arrow_last_k AS (
    SELECT
        arrow_id,
        max(seq_k) AS last_seq_k
    FROM arrow_pts_on_line
    WHERE line_len - d_from_end >= min_from_start_m
    GROUP BY arrow_id
),
arrow_pts AS (
    SELECT p.*
    FROM arrow_pts_on_line p
    INNER JOIN arrow_last_k lk
        ON lk.arrow_id = p.arrow_id
       AND p.seq_k <= lk.last_seq_k
    WHERE p.pt IS NOT NULL
      AND NOT ST_IsEmpty(p.pt)
),
arrow_azimuth AS (
    SELECT
        ap.*,
        MOD(
            (
                DEGREES(
                    ST_Azimuth(
                        ST_LineInterpolatePoint(
                            ap.geom,
                            GREATEST(0.00002, ap.frac_clamped - 0.02)
                        ),
                        ST_LineInterpolatePoint(
                            ap.geom,
                            LEAST(0.99998, ap.frac_clamped + 0.02)
                        )
                    )
                )
                + 360.0
            )::numeric % 360.0,
            360.0
        )::double precision AS dir_deg
    FROM arrow_pts ap
)
SELECT
    'highway_turn_arrow'::text,
    'arrow'::text,
    NULL::text,
    NULL::text,
    az.turn,
    NULL::text,
    NULL::real,
    az.arrow_len_m::real,
    az.colour,
    ROUND(az.dir_deg::numeric, 1)::real,
    az.type,
    NULL::text,
    az.layer,
    COALESCE(hr.osm_type, 'W'::text),
    (-(abs(hashtext(az.arrow_id::text || ':' || az.pt_kind || ':' || az.seq_k::text))) % 2147483647)::bigint,
    az.pt
FROM arrow_azimuth az
INNER JOIN highway hr ON hr.osm_id = az.osm_id;


----------------------------------------------------------------------
-- 6) OSM arrow ways (road_marking=arrow) → midpoint points in road_marking_node
----------------------------------------------------------------------

INSERT INTO road_marking_node (
    source,
    road_marking,
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
    osm_type,
    osm_id,
    geom
)
SELECT
    w.source,
    w.road_marking,
    NULL::text,
    NULL::text,
    w.arrow,
    NULL::text,
    w.width,
    CASE
        WHEN w.length IS NOT NULL THEN w.length::real
        ELSE ROUND(ST_Length(w.geom)::numeric, 1)::real
    END,
    w.colour,
    CASE
        WHEN w.direction IS NOT NULL THEN ROUND(w.direction::numeric, 1)::real
        ELSE ROUND(
            (
                MOD(
                    (
                        DEGREES(
                            ST_Azimuth(
                                ST_LineInterpolatePoint(w.geom, 0.02),
                                ST_LineInterpolatePoint(w.geom, 0.98)
                            )
                        )
                        + 360.0
                    )::numeric % 360.0,
                    360.0
                )
            )::numeric,
            1
        )::real
    END,
    w.type,
    w.class,
    w.layer,
    w.osm_type,
    w.osm_id,
    ST_LineInterpolatePoint(w.geom, 0.5)::geometry(Point)
FROM road_marking_way w
WHERE w.road_marking = 'arrow'
  AND w.geom IS NOT NULL
  AND NOT ST_IsEmpty(w.geom)
  AND ST_GeometryType(w.geom) = 'ST_LineString'
  AND ST_Length(w.geom) > metres(0.01);

DELETE FROM road_marking_way
WHERE road_marking = 'arrow';


----------------------------------------------------------------------
-- 7) Remove temporary generic stop_lines (used only for arrow processing)
----------------------------------------------------------------------

DELETE FROM road_marking_way
WHERE source IN (
    'stop_node_generic_temporary',
    'stop_node_generic_angled_temporary'
);


----------------------------------------------------------------------
-- 8) Cleanup
----------------------------------------------------------------------

DROP TABLE IF EXISTS _markings_raw;
DROP TABLE IF EXISTS _markings_raw_seg;
DROP TABLE IF EXISTS _markings_endpoints;
DROP TABLE IF EXISTS _markings_merged;
DROP TABLE IF EXISTS _stop_lines_generic;
DROP TABLE IF EXISTS _arrow_end;
