-- Spreads street segments of dual carriageways at their junction points
-- where they split from or merge into a shared carriageway
--
-- Shift amount is the distance from this segment's OSM centerline to its
-- left carriageway edge, taken from the lanes of *this* segment (start vs
-- end, including transition). highway.left_offset is only a fallback: it is
-- a length-weighted median along the whole road_segment_id and can reflect
-- a neighbour's placement tag (e.g. placement=right_of:1) rather than the
-- geometry at this junction.

DROP TABLE IF EXISTS highway_transformed;

CREATE TABLE highway_transformed AS
WITH

-- 1) Select only dual carriageways
dual AS (
    SELECT *
    FROM highway
    WHERE dual_carriageway = 'yes'
),

-- 1b) Left-edge distance at each end, from this segment's own lanes
dual_lane_left AS (
    SELECT
        l.segment_id,
        GREATEST(-MIN(l."offset" - l.width / 2.0), 0) AS left_at_start,
        GREATEST(
            -MIN((l."offset" + COALESCE(l.transition, 0)) - l.width / 2.0),
            0
        ) AS left_at_end
    FROM lanes l
    WHERE l.width IS NOT NULL
    GROUP BY l.segment_id
),

-- 2) extract endpoints
dual_endpoints AS (
    SELECT
        d.*,
        COALESCE(ll.left_at_start, GREATEST(d.left_offset, 0)) AS spread_left_start,
        COALESCE(ll.left_at_end, GREATEST(d.left_offset, 0)) AS spread_left_end,
        ST_StartPoint(geom) AS start_pt,
        ST_EndPoint(geom)   AS end_pt,
        ST_NPoints(geom)    AS npts
    FROM dual d
    LEFT JOIN dual_lane_left ll ON ll.segment_id = d.segment_id
),

-- 3) find matching single carriageways at start point
start_candidates AS (
    SELECT
        d.segment_id,
        d.osm_id,
        d.geom,
        d.start_pt,
        d.spread_left_start AS left_offset,
        s.geom AS single_geom,

        -- direction of dual segment (start → next point)
        ST_Azimuth(
            d.start_pt,
            ST_PointN(d.geom, 2)
        ) AS az_dual,

        -- direction of single segment
        CASE
            WHEN ST_Equals(ST_StartPoint(s.geom), d.start_pt) THEN
                ST_Azimuth(
                    ST_StartPoint(s.geom),
                    ST_PointN(s.geom, 2)
                )
            ELSE
                ST_Azimuth(
                    ST_EndPoint(s.geom),
                    ST_PointN(s.geom, ST_NPoints(s.geom) - 1)
                )
        END AS az_single

    FROM dual_endpoints d
    JOIN highway s
      ON s.name = d.name
     AND s.highway = d.highway
     AND (s.dual_carriageway IS DISTINCT FROM 'yes')
     AND (
         ST_Equals(ST_StartPoint(s.geom), d.start_pt)
         OR
         ST_Equals(ST_EndPoint(s.geom), d.start_pt)
     )
),

-- 4) select best matching segment (smallest angle difference)
start_best AS (
    SELECT DISTINCT ON (segment_id)
        *,
        LEAST(
            abs(az_dual - az_single),
            2*pi() - abs(az_dual - az_single)
        ) AS angle_diff
    FROM start_candidates
    ORDER BY segment_id, angle_diff
),

-- 5) compute shifted start point
start_shifted AS (
    SELECT
        segment_id,
        ST_Translate(
            start_pt,
            sin(az_single + pi()/2) * -metres(left_offset),
            cos(az_single + pi()/2) * -metres(left_offset)
        ) AS new_start_pt
    FROM start_best
),

-- 5b) Fallback: start candidates ignoring name (require same highway),
--      only if exactly one single segment is present at the junction
start_candidates_any AS (
    SELECT
        d.segment_id,
        d.osm_id,
        d.geom,
        d.start_pt,
        d.spread_left_start AS left_offset,
        s.geom AS single_geom,
        -- dual direction from start
        ST_Azimuth(
            d.start_pt,
            ST_PointN(d.geom, 2)
        ) AS az_dual,
        -- single direction away from the junction point
        CASE
            WHEN ST_Equals(ST_StartPoint(s.geom), d.start_pt) THEN
                ST_Azimuth(
                    ST_StartPoint(s.geom),
                    ST_PointN(s.geom, 2)
                )
            ELSE
                ST_Azimuth(
                    ST_EndPoint(s.geom),
                    ST_PointN(s.geom, ST_NPoints(s.geom) - 1)
                )
        END AS az_single
    FROM dual_endpoints d
    JOIN highway s
      ON s.highway = d.highway
     AND (s.dual_carriageway IS DISTINCT FROM 'yes')
     AND s.name IS DISTINCT FROM d.name
     AND (
         ST_Equals(ST_StartPoint(s.geom), d.start_pt)
         OR
         ST_Equals(ST_EndPoint(s.geom), d.start_pt)
     )
),

start_candidates_any_unique AS (
    SELECT *
    FROM (
        SELECT
            sca.*,
            COUNT(*) OVER (PARTITION BY sca.segment_id) AS candidate_count
        FROM start_candidates_any sca
    ) x
    WHERE candidate_count = 1
),

-- 5c) Check that at the junction there is another dual segment
--     with the same name and the two duals diverge by >= 135°
start_dual_pair_check AS (
    SELECT DISTINCT d1.segment_id
    FROM dual_endpoints d1
    JOIN dual_endpoints d2
      ON d1.segment_id <> d2.segment_id
     AND d1.name = d2.name
    WHERE
      (
        ST_Equals(d1.start_pt, d2.start_pt)
        OR
        ST_Equals(d1.start_pt, d2.end_pt)
      )
      AND (
        LEAST(
          abs(
            ST_Azimuth(d1.start_pt, ST_PointN(d1.geom, 2)) -
            CASE
              WHEN ST_Equals(d2.start_pt, d1.start_pt)
              THEN ST_Azimuth(d2.start_pt, ST_PointN(d2.geom, 2))
              ELSE ST_Azimuth(ST_PointN(d2.geom, d2.npts - 1), d2.end_pt)
            END
          ),
          2*pi() - abs(
            ST_Azimuth(d1.start_pt, ST_PointN(d1.geom, 2)) -
            CASE
              WHEN ST_Equals(d2.start_pt, d1.start_pt)
              THEN ST_Azimuth(d2.start_pt, ST_PointN(d2.geom, 2))
              ELSE ST_Azimuth(ST_PointN(d2.geom, d2.npts - 1), d2.end_pt)
            END
          )
        ) >= (pi() * 135.0 / 180.0)
      )
),

-- 5d) Fallback best (there is exactly one single candidate and the dual-pair condition holds)
start_best_fallback AS (
    SELECT
        u.segment_id,
        u.start_pt,
        u.left_offset,
        u.az_single
    FROM start_candidates_any_unique u
    JOIN start_dual_pair_check p
      ON u.segment_id = p.segment_id
),

-- 5e) compute shifted start point for fallback
start_shifted_fallback AS (
    SELECT
        segment_id,
        ST_Translate(
            start_pt,
            sin(az_single + pi()/2) * -metres(left_offset),
            cos(az_single + pi()/2) * -metres(left_offset)
        ) AS new_start_pt
    FROM start_best_fallback
),

-- 6) same logic for end point
end_candidates AS (
    SELECT
        d.segment_id,
        d.osm_id,
        d.geom,
        d.end_pt,
        d.spread_left_end AS left_offset,
        s.geom AS single_geom,

        ST_Azimuth(
            ST_PointN(d.geom, d.npts - 1),
            d.end_pt
        ) AS az_dual,

        CASE
            WHEN ST_Equals(ST_StartPoint(s.geom), d.end_pt) THEN
                ST_Azimuth(
                    ST_StartPoint(s.geom),
                    ST_PointN(s.geom, 2)
                )
            ELSE
                ST_Azimuth(
                    ST_EndPoint(s.geom),
                    ST_PointN(s.geom, ST_NPoints(s.geom) - 1)
                )
        END AS az_single

    FROM dual_endpoints d
    JOIN highway s
      ON s.name = d.name
     AND s.highway = d.highway
     AND (s.dual_carriageway IS DISTINCT FROM 'yes')
     AND (
         ST_Equals(ST_StartPoint(s.geom), d.end_pt)
         OR
         ST_Equals(ST_EndPoint(s.geom), d.end_pt)
     )
),

end_best AS (
    SELECT DISTINCT ON (segment_id)
        *,
        LEAST(
            abs(az_dual - az_single),
            2*pi() - abs(az_dual - az_single)
        ) AS angle_diff
    FROM end_candidates
    ORDER BY segment_id, angle_diff
),

end_shifted AS (
    SELECT
        segment_id,
        ST_Translate(
            end_pt,
            sin(az_single + pi()/2) * metres(left_offset),
            cos(az_single + pi()/2) * metres(left_offset)
        ) AS new_end_pt
    FROM end_best
),

-- 6b) Fallback for end point: candidates ignoring name (same highway), unique only
end_candidates_any AS (
    SELECT
        d.segment_id,
        d.osm_id,
        d.geom,
        d.end_pt,
        d.spread_left_end AS left_offset,
        s.geom AS single_geom,
        -- dual direction into end
        ST_Azimuth(
            ST_PointN(d.geom, d.npts - 1),
            d.end_pt
        ) AS az_dual,
        -- single direction away from the junction point
        CASE
            WHEN ST_Equals(ST_StartPoint(s.geom), d.end_pt) THEN
                ST_Azimuth(
                    ST_StartPoint(s.geom),
                    ST_PointN(s.geom, 2)
                )
            ELSE
                ST_Azimuth(
                    ST_EndPoint(s.geom),
                    ST_PointN(s.geom, ST_NPoints(s.geom) - 1)
                )
        END AS az_single
    FROM dual_endpoints d
    JOIN highway s
      ON s.highway = d.highway
     AND (s.dual_carriageway IS DISTINCT FROM 'yes')
     AND s.name IS DISTINCT FROM d.name
     AND (
         ST_Equals(ST_StartPoint(s.geom), d.end_pt)
         OR
         ST_Equals(ST_EndPoint(s.geom), d.end_pt)
     )
),

end_candidates_any_unique AS (
    SELECT *
    FROM (
        SELECT
            eca.*,
            COUNT(*) OVER (PARTITION BY eca.segment_id) AS candidate_count
        FROM end_candidates_any eca
    ) x
    WHERE candidate_count = 1
),

-- 6c) Dual pair angle check at end point (>= 135°)
end_dual_pair_check AS (
    SELECT DISTINCT d1.segment_id
    FROM dual_endpoints d1
    JOIN dual_endpoints d2
      ON d1.segment_id <> d2.segment_id
     AND d1.name = d2.name
    WHERE
      (
        ST_Equals(d1.end_pt, d2.start_pt)
        OR
        ST_Equals(d1.end_pt, d2.end_pt)
      )
      AND (
        LEAST(
          abs(
            ST_Azimuth(ST_PointN(d1.geom, d1.npts - 1), d1.end_pt) -
            CASE
              WHEN ST_Equals(d2.start_pt, d1.end_pt)
              THEN ST_Azimuth(d2.start_pt, ST_PointN(d2.geom, 2))
              ELSE ST_Azimuth(ST_PointN(d2.geom, d2.npts - 1), d2.end_pt)
            END
          ),
          2*pi() - abs(
            ST_Azimuth(ST_PointN(d1.geom, d1.npts - 1), d1.end_pt) -
            CASE
              WHEN ST_Equals(d2.start_pt, d1.end_pt)
              THEN ST_Azimuth(d2.start_pt, ST_PointN(d2.geom, 2))
              ELSE ST_Azimuth(ST_PointN(d2.geom, d2.npts - 1), d2.end_pt)
            END
          )
        ) >= (pi() * 135.0 / 180.0)
      )
),

end_best_fallback AS (
    SELECT
        u.segment_id,
        u.end_pt,
        u.left_offset,
        u.az_single
    FROM end_candidates_any_unique u
    JOIN end_dual_pair_check p
      ON u.segment_id = p.segment_id
),

end_shifted_fallback AS (
    SELECT
        segment_id,
        ST_Translate(
            end_pt,
            sin(az_single + pi()/2) * metres(left_offset),
            cos(az_single + pi()/2) * metres(left_offset)
        ) AS new_end_pt
    FROM end_best_fallback
),

-- 7) update geometries (start point first)
updated_dual AS (
    SELECT
        d.*,
        CASE
            WHEN s.new_start_pt IS NOT NULL THEN
                ST_SetPoint(d.geom, 0, s.new_start_pt)
            WHEN sf.new_start_pt IS NOT NULL THEN
                ST_SetPoint(d.geom, 0, sf.new_start_pt)
            ELSE
                d.geom
        END AS geom_updated
    FROM dual d
    LEFT JOIN start_shifted s
      ON d.segment_id = s.segment_id
    LEFT JOIN start_shifted_fallback sf
      ON d.segment_id = sf.segment_id
),

-- 8) update end point (final geometry)
updated_dual_final AS (
    SELECT
        u.segment_id,
        u.osm_part,
        u.road_segment_id,
        u.osm_type,
        u.osm_id,
        u.highway,
        u.type,
        u.class,
        u.name,
        u.oneway,
        u."oneway:bicycle",
        u.dual_carriageway,
        u.surface,
        u."sett:length",
        u.width,
        u.placement_offset,
        u.left_offset,
        u.transition,
        u."lane_markings:temporary",
        u.bridge,
        u.tunnel,
        u.construction,
        u.is_sidepath,
        u.tactile_paving,
        u.informal,
        u.hierarchy,
        u.layer,

        CASE
            WHEN e.new_end_pt IS NOT NULL THEN
                ST_SetPoint(u.geom_updated, ST_NPoints(u.geom_updated) - 1, e.new_end_pt)
            WHEN ef.new_end_pt IS NOT NULL THEN
                ST_SetPoint(u.geom_updated, ST_NPoints(u.geom_updated) - 1, ef.new_end_pt)
            ELSE
                u.geom_updated
        END AS geom

    FROM updated_dual u
    LEFT JOIN end_shifted e
      ON u.segment_id = e.segment_id
    LEFT JOIN end_shifted_fallback ef
      ON u.segment_id = ef.segment_id
),

-- 9) keep non-dual segments unchanged
non_dual AS (
    SELECT *
    FROM highway
    WHERE dual_carriageway IS DISTINCT FROM 'yes'
)

-- 10) final result
SELECT
    segment_id,
    osm_part,
    road_segment_id,
    osm_type,
    osm_id,
    highway,
    type,
    class,
    name,
    oneway,
    "oneway:bicycle",
    dual_carriageway,
    surface,
    "sett:length",
    width,
    placement_offset,
    left_offset,
    transition,
    "lane_markings:temporary",
    bridge,
    tunnel,
    construction,
    is_sidepath,
    tactile_paving,
    informal,
    hierarchy,
    layer,
    geom
FROM updated_dual_final

UNION ALL

SELECT
    segment_id,
    osm_part,
    road_segment_id,
    osm_type,
    osm_id,
    highway,
    type,
    class,
    name,
    oneway,
    "oneway:bicycle",
    dual_carriageway,
    surface,
    "sett:length",
    width,
    placement_offset,
    left_offset,
    transition,
    "lane_markings:temporary",
    bridge,
    tunnel,
    construction,
    is_sidepath,
    tactile_paving,
    informal,
    hierarchy,
    layer,
    geom
FROM non_dual;


-- create spatial index
DROP INDEX IF EXISTS highway_transformed_geom_idx;
CREATE INDEX highway_transformed_geom_idx
ON highway_transformed
USING GIST (geom);

CREATE INDEX highway_transformed_segment_id_idx
ON highway_transformed (segment_id);