-- road_marking_parking.sql — parking area outlines, parking_space symbols,
--   and stall markings from street_parking lines.
-- Depends on: highway_area (highway_area_merge.sql), feature_polygon (import),
--   barrier_way / barrier_polygon (import), highway_transformed, lanes;
--   street_parking optional (street_parking.sql).
--
-- 1) Outline segments from parking highway_area + selected feature_polygon
-- 2) Drop segments covered by barrier=kerb; parking_space edges covered by
--    parent parking lot outer boundaries; dedupe shared edges
-- 3) Merge connected outline fragments → road_marking_way (parking_edge)
-- 4) parking_space symbols → road_marking_node with geometry-based direction
-- 5) Stall frames + dividers from marked on-street parking lines

\i 'processing/sql/params/params.sql'


----------------------------------------------------------------------
-- 1) Source polygons for outlines
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_sources;
CREATE TEMP TABLE _parking_outline_sources AS
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    CASE ha."area:highway"
        WHEN 'parking' THEN 'parking'
        WHEN 'parking_two_wheel' THEN 'motorcycle_parking'
        WHEN 'parking_space' THEN 'parking_space'
    END AS class,
    ha.geom
FROM highway_area ha
WHERE ha."area:highway" IN ('parking', 'parking_two_wheel')
  AND ha.markings IS NOT NULL
  AND ha.markings NOT IN ('no', 'none')
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
UNION ALL
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    'parking_space'::text AS class,
    ha.geom
FROM highway_area ha
WHERE ha."area:highway" = 'parking_space'
  AND (ha.markings IS NULL OR ha.markings NOT IN ('no', 'none'))
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
UNION ALL
SELECT
    fp.osm_type,
    fp.osm_id,
    fp.layer,
    fp.temporary,
    fp.class,
    fp.geom
FROM feature_polygon fp
WHERE fp.class IN (
        'bicycle_parking',
        'bicycle_rental',
        'small_electric_vehicle_parking'
    )
  AND fp.geom IS NOT NULL
  AND NOT ST_IsEmpty(fp.geom)
  AND (
        (
            fp.position IN ('lane', 'street_side')
            AND (fp.markings IS NULL OR fp.markings NOT IN ('no', 'none'))
        )
        OR (
            fp.markings IS NOT NULL
            AND fp.markings NOT IN ('no', 'none')
        )
    );

CREATE INDEX _parking_outline_sources_geom_idx
    ON _parking_outline_sources USING GIST (geom);


----------------------------------------------------------------------
-- 2) Boundary segments
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_raw;
CREATE TEMP TABLE _parking_outline_raw AS
WITH boundary_lines AS (
    SELECT
        s.osm_type,
        s.osm_id,
        s.layer,
        s.temporary,
        s.class,
        (bd).path[1] AS fragment_id,
        (bd).geom AS geom
    FROM _parking_outline_sources s
    CROSS JOIN LATERAL ST_Dump(ST_Boundary(s.geom)) AS bd
    WHERE NOT ST_IsEmpty((bd).geom)
),
segments AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        fragment_id,
        (ds).path[1] AS seg_idx,
        (ds).geom AS geom
    FROM boundary_lines
    CROSS JOIN LATERAL ST_DumpSegments(geom) AS ds
    WHERE ST_GeometryType((ds).geom) = 'ST_LineString'
      AND ST_Length((ds).geom) > metres(:'parking_outline_min_length'::numeric)
)
SELECT * FROM segments;

CREATE INDEX _parking_outline_raw_geom_idx
    ON _parking_outline_raw USING GIST (geom);


----------------------------------------------------------------------
-- 3) Drop segments covered by kerb; dedupe identical shared edges
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_kerbs;
CREATE TEMP TABLE _parking_kerbs AS
SELECT geom
FROM barrier_way
WHERE barrier = 'kerb'
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
UNION ALL
SELECT (bd).geom
FROM barrier_polygon bp
CROSS JOIN LATERAL ST_Dump(ST_Boundary(bp.geom)) AS bd
WHERE bp.barrier = 'kerb'
  AND bp.geom IS NOT NULL
  AND NOT ST_IsEmpty(bp.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) = 'ST_LineString';

CREATE INDEX _parking_kerbs_geom_idx
    ON _parking_kerbs USING GIST (geom);


DROP TABLE IF EXISTS _parking_outline_no_kerb;
CREATE TEMP TABLE _parking_outline_no_kerb AS
SELECT
    s.osm_type,
    s.osm_id,
    s.layer,
    s.temporary,
    s.class,
    s.fragment_id,
    s.seg_idx,
    s.geom
FROM _parking_outline_raw s
WHERE NOT EXISTS (
    SELECT 1
    FROM _parking_kerbs k
    WHERE k.geom && s.geom
      AND ST_Intersects(k.geom, s.geom)
      AND ST_Covers(k.geom, s.geom)
);

CREATE INDEX _parking_outline_no_kerb_geom_idx
    ON _parking_outline_no_kerb USING GIST (geom);


-- Outer boundaries of parking lots: remaining street parking in highway_area
-- plus off-street amenity parking / motorcycle_parking in landuse.
-- parking_space outlines that coincide with these edges are dropped below.
DROP TABLE IF EXISTS _parking_lot_boundaries;
CREATE TEMP TABLE _parking_lot_boundaries AS
SELECT
    ha.geom AS poly_geom,
    (bd).geom AS geom
FROM highway_area ha
CROSS JOIN LATERAL ST_Dump(ST_Boundary(ha.geom)) AS bd
WHERE ha."area:highway" IN ('parking', 'parking_two_wheel')
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) IN ('ST_LineString', 'ST_LinearRing')
UNION ALL
SELECT
    lu.geom AS poly_geom,
    (bd).geom AS geom
FROM landuse lu
CROSS JOIN LATERAL ST_Dump(ST_Boundary(lu.geom)) AS bd
WHERE lu.class IN ('parking', 'motorcycle_parking')
  AND lu.geom IS NOT NULL
  AND NOT ST_IsEmpty(lu.geom)
  AND NOT ST_IsEmpty((bd).geom)
  AND ST_GeometryType((bd).geom) IN ('ST_LineString', 'ST_LinearRing');

CREATE INDEX _parking_lot_boundaries_geom_idx
    ON _parking_lot_boundaries USING GIST (geom);
CREATE INDEX _parking_lot_boundaries_poly_geom_idx
    ON _parking_lot_boundaries USING GIST (poly_geom);


DROP TABLE IF EXISTS _parking_outline_no_lot_edge;
CREATE TEMP TABLE _parking_outline_no_lot_edge AS
SELECT
    s.osm_type,
    s.osm_id,
    s.layer,
    s.temporary,
    s.class,
    s.fragment_id,
    s.seg_idx,
    s.geom
FROM _parking_outline_no_kerb s
WHERE s.class IS DISTINCT FROM 'parking_space'
   OR NOT EXISTS (
        SELECT 1
        FROM highway_area space
        INNER JOIN _parking_lot_boundaries b
            ON b.poly_geom && space.geom
           AND ST_Covers(b.poly_geom, ST_PointOnSurface(space.geom))
        WHERE space.osm_type = s.osm_type
          AND space.osm_id = s.osm_id
          AND space."area:highway" = 'parking_space'
          AND b.geom && s.geom
          AND ST_Intersects(b.geom, s.geom)
          AND ST_Covers(b.geom, s.geom)
    );

CREATE INDEX _parking_outline_no_lot_edge_geom_idx
    ON _parking_outline_no_lot_edge USING GIST (geom);


-- Keep one copy of geometrically identical segments (shared parking edges).
-- Normalize endpoint order so reversed duplicates collapse.
DROP TABLE IF EXISTS _parking_outline_deduped;
CREATE TEMP TABLE _parking_outline_deduped AS
SELECT DISTINCT ON (edge_key)
    osm_type,
    osm_id,
    layer,
    temporary,
    class,
    fragment_id,
    seg_idx,
    geom
FROM (
    SELECT
        s.*,
        CASE
            WHEN ST_X(ST_StartPoint(s.geom)) < ST_X(ST_EndPoint(s.geom))
              OR (
                  ST_X(ST_StartPoint(s.geom)) = ST_X(ST_EndPoint(s.geom))
                  AND ST_Y(ST_StartPoint(s.geom)) <= ST_Y(ST_EndPoint(s.geom))
              )
            THEN ST_AsBinary(s.geom)
            ELSE ST_AsBinary(ST_Reverse(s.geom))
        END AS edge_key
    FROM _parking_outline_no_lot_edge s
) t
ORDER BY
    edge_key,
    osm_id,
    class,
    fragment_id,
    seg_idx;

CREATE INDEX _parking_outline_deduped_geom_idx
    ON _parking_outline_deduped USING GIST (geom);


----------------------------------------------------------------------
-- 4) Merge connected segments per feature/style → road_marking_way
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_merged;
CREATE TEMP TABLE _parking_outline_merged AS
WITH dissolved AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        ST_LineMerge(ST_UnaryUnion(ST_Collect(geom))) AS geom
    FROM _parking_outline_deduped
    GROUP BY osm_type, osm_id, layer, temporary, class
),
dumped AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        class,
        (ST_Dump(geom)).geom AS geom
    FROM dissolved
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
)
SELECT
    osm_type,
    osm_id,
    layer,
    temporary,
    class,
    geom
FROM dumped
WHERE ST_GeometryType(geom) = 'ST_LineString'
  AND ST_Length(geom) > metres(:'parking_outline_min_length'::numeric);


DELETE FROM road_marking_way
WHERE road_marking = 'parking_edge'
  AND source = 'parking_outline';

INSERT INTO road_marking_way (
    osm_type,
    osm_id,
    source,
    road_marking,
    stroke,
    dasharray,
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
    m.osm_type,
    m.osm_id,
    'parking_outline'::text AS source,
    'parking_edge'::text AS road_marking,
    'solid'::text AS stroke,
    NULL::text AS dasharray,
    NULL::text AS pattern,
    NULL::text AS arrow,
    NULL::text AS symbol,
    0.12::real AS width,
    NULL::real AS length,
    CASE
        WHEN m.temporary IS NOT NULL
         AND m.temporary NOT IN ('no', 'none')
        THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    NULL::real AS direction,
    'parking'::text AS type,
    m.class,
    m.layer,
    m.geom
FROM _parking_outline_merged m;


----------------------------------------------------------------------
-- 5) parking_space symbols → road_marking_node
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_symbol_sources;
CREATE TEMP TABLE _parking_symbol_sources AS
SELECT
    ha.osm_type,
    ha.osm_id,
    ha.layer,
    ha.temporary,
    ha.symbol,
    ha.geom,
    ST_PointOnSurface(ha.geom)::geometry(Point) AS pt,
    ST_OrientedEnvelope(ha.geom) AS envelope
FROM highway_area ha
WHERE ha."area:highway" = 'parking_space'
  AND ha.symbol IS NOT NULL
  AND ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom);

CREATE INDEX _parking_symbol_sources_geom_idx
    ON _parking_symbol_sources USING GIST (geom);
CREATE INDEX _parking_symbol_sources_pt_idx
    ON _parking_symbol_sources USING GIST (pt);


DROP TABLE IF EXISTS _parking_symbol_roads;
CREATE TEMP TABLE _parking_symbol_roads AS
SELECT geom
FROM highway_transformed
WHERE type IN ('road', 'motorway', 'service')
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Length(geom) > metres(0.5);

CREATE INDEX _parking_symbol_roads_geom_idx
    ON _parking_symbol_roads USING GIST (geom);


DROP TABLE IF EXISTS _parking_symbol_lanes;
CREATE TEMP TABLE _parking_symbol_lanes AS
SELECT
    geom,
    direction
FROM lanes
WHERE type IN ('road', 'motorway', 'service')
  AND geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Length(geom) > metres(0.5);

CREATE INDEX _parking_symbol_lanes_geom_idx
    ON _parking_symbol_lanes USING GIST (geom);


DROP TABLE IF EXISTS _parking_symbol_direction;
CREATE TEMP TABLE _parking_symbol_direction AS
WITH envelope_sides AS (
    SELECT
        s.osm_type,
        s.osm_id,
        s.layer,
        s.temporary,
        s.symbol,
        s.pt,
        s.geom,
        ST_PointN(ST_ExteriorRing(s.envelope), 1) AS p1,
        ST_PointN(ST_ExteriorRing(s.envelope), 2) AS p2,
        ST_PointN(ST_ExteriorRing(s.envelope), 3) AS p3,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(s.envelope), 1),
            ST_PointN(ST_ExteriorRing(s.envelope), 2)
        ) AS side1_len,
        ST_Distance(
            ST_PointN(ST_ExteriorRing(s.envelope), 2),
            ST_PointN(ST_ExteriorRing(s.envelope), 3)
        ) AS side2_len
    FROM _parking_symbol_sources s
    WHERE s.envelope IS NOT NULL
      AND NOT ST_IsEmpty(s.envelope)
),
long_edge AS (
    SELECT
        osm_type,
        osm_id,
        layer,
        temporary,
        symbol,
        pt,
        geom,
        CASE
            WHEN side1_len >= side2_len THEN ST_Azimuth(p1, p2)
            ELSE ST_Azimuth(p2, p3)
        END AS long_azimuth_rad
    FROM envelope_sides
),
nearest_road AS (
    SELECT DISTINCT ON (le.osm_type, le.osm_id)
        le.osm_type,
        le.osm_id,
        le.layer,
        le.temporary,
        le.symbol,
        le.pt,
        le.geom,
        le.long_azimuth_rad,
        ST_Distance(le.pt, r.geom) AS road_dist,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                r.geom,
                GREATEST(0::double precision, ST_LineLocatePoint(r.geom, sl.cp) - 1e-8)
            ),
            ST_LineInterpolatePoint(
                r.geom,
                LEAST(1::double precision, ST_LineLocatePoint(r.geom, sl.cp) + 1e-8)
            )
        ) AS road_azimuth_rad,
        ST_Azimuth(le.pt, sl.cp) AS to_road_azimuth_rad
    FROM long_edge le
    LEFT JOIN LATERAL (
        SELECT r.geom
        FROM _parking_symbol_roads r
        WHERE r.geom && ST_Expand(le.pt, metres(:'parking_symbol_road_search_m'::double precision))
          AND ST_DWithin(
                le.pt,
                r.geom,
                metres(:'parking_symbol_road_search_m'::double precision)
            )
        ORDER BY le.pt <-> r.geom
        LIMIT 1
    ) r ON true
    LEFT JOIN LATERAL (
        SELECT ST_ClosestPoint(r.geom, le.pt) AS cp
        WHERE r.geom IS NOT NULL
    ) sl ON true
),
angle_info AS (
    SELECT
        nr.*,
        DEGREES(nr.long_azimuth_rad) AS long_deg,
        MOD((DEGREES(nr.long_azimuth_rad) + 180.0)::numeric, 360.0)::double precision AS long_opp_deg,
        CASE
            WHEN nr.road_azimuth_rad IS NULL THEN NULL
            ELSE LEAST(
                LEAST(
                    ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad)),
                    360.0 - ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad))
                ),
                180.0 - LEAST(
                    ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad)),
                    360.0 - ABS(DEGREES(nr.long_azimuth_rad) - DEGREES(nr.road_azimuth_rad))
                )
            )
        END AS undirected_vs_road_deg
    FROM nearest_road nr
),
nearest_lane AS (
    SELECT DISTINCT ON (a.osm_type, a.osm_id)
        a.osm_type,
        a.osm_id,
        ST_Azimuth(
            ST_LineInterpolatePoint(
                lane_geom.geom,
                GREATEST(0::double precision, ST_LineLocatePoint(lane_geom.geom, a.pt) - 1e-8)
            ),
            ST_LineInterpolatePoint(
                lane_geom.geom,
                LEAST(1::double precision, ST_LineLocatePoint(lane_geom.geom, a.pt) + 1e-8)
            )
        ) AS lane_azimuth_rad
    FROM angle_info a
    INNER JOIN LATERAL (
        SELECT
            CASE
                WHEN l.direction = 'backward' THEN ST_Reverse(l.geom)
                ELSE l.geom
            END AS geom
        FROM _parking_symbol_lanes l
        WHERE a.road_dist IS NOT NULL
          AND a.undirected_vs_road_deg IS NOT NULL
          AND a.undirected_vs_road_deg <= :'parking_symbol_parallel_angle_deg'::double precision
          AND l.geom && ST_Expand(a.pt, a.road_dist + metres(0.01))
          AND ST_DWithin(a.pt, l.geom, a.road_dist + metres(0.01))
        ORDER BY a.pt <-> l.geom
        LIMIT 1
    ) lane_geom ON true
),
chosen AS (
    SELECT
        a.osm_type,
        a.osm_id,
        a.layer,
        a.temporary,
        a.symbol,
        a.pt,
        CASE
            -- no nearby road: use long-edge azimuth
            WHEN a.road_azimuth_rad IS NULL THEN a.long_deg
            -- perpendicular / angled parking: point toward the road
            WHEN a.undirected_vs_road_deg > :'parking_symbol_parallel_angle_deg'::double precision THEN
                CASE
                    WHEN LEAST(
                        ABS(a.long_deg - DEGREES(a.to_road_azimuth_rad)),
                        360.0 - ABS(a.long_deg - DEGREES(a.to_road_azimuth_rad))
                    ) <= LEAST(
                        ABS(a.long_opp_deg - DEGREES(a.to_road_azimuth_rad)),
                        360.0 - ABS(a.long_opp_deg - DEGREES(a.to_road_azimuth_rad))
                    )
                    THEN a.long_deg
                    ELSE a.long_opp_deg
                END
            -- parallel parking: align with lane, then flip 180° (against traffic)
            ELSE
                MOD(
                    (
                        CASE
                            WHEN nl.lane_azimuth_rad IS NULL THEN a.long_deg
                            WHEN LEAST(
                                ABS(a.long_deg - DEGREES(nl.lane_azimuth_rad)),
                                360.0 - ABS(a.long_deg - DEGREES(nl.lane_azimuth_rad))
                            ) <= LEAST(
                                ABS(a.long_opp_deg - DEGREES(nl.lane_azimuth_rad)),
                                360.0 - ABS(a.long_opp_deg - DEGREES(nl.lane_azimuth_rad))
                            )
                            THEN a.long_deg
                            ELSE a.long_opp_deg
                        END + 180.0
                    )::numeric,
                    360.0
                )::double precision
        END AS direction
    FROM angle_info a
    LEFT JOIN nearest_lane nl
        ON nl.osm_type = a.osm_type
       AND nl.osm_id = a.osm_id
)
SELECT
    osm_type,
    osm_id,
    layer,
    temporary,
    symbol,
    pt AS geom,
    ROUND(direction::numeric, 1)::real AS direction
FROM chosen;


DELETE FROM road_marking_node
WHERE source = 'parking_space';

INSERT INTO road_marking_node (
    osm_type,
    osm_id,
    source,
    road_marking,
    stroke,
    dasharray,
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
    d.osm_type,
    d.osm_id,
    'parking_space'::text AS source,
    'symbol'::text AS road_marking,
    NULL::text AS stroke,
    NULL::text AS dasharray,
    NULL::text AS pattern,
    NULL::text AS arrow,
    d.symbol,
    0.7::real AS width,
    1.0::real AS length,
    CASE
        WHEN d.temporary IS NOT NULL
         AND d.temporary NOT IN ('no', 'none')
        THEN :'road_marking_temporary_colour'::text
        ELSE :'road_marking_default_colour'::text
    END AS colour,
    d.direction,
    'parking'::text AS type,
    d.symbol AS class,
    d.layer,
    d.geom
FROM _parking_symbol_direction d;


----------------------------------------------------------------------
-- 6) Stall markings from street_parking (markings=yes, source not separate)
----------------------------------------------------------------------

DROP TABLE IF EXISTS _spm_const;
CREATE TEMP TABLE _spm_const AS
SELECT
    :'street_parking_point_parallel_m'::double precision AS parallel_m,
    :'street_parking_point_diagonal_m'::double precision AS diagonal_m,
    :'street_parking_point_perpendicular_m'::double precision AS perpendicular_m,
    :'street_parking_point_bus_m'::double precision AS bus_m,
    :'street_parking_point_bus_end_m'::double precision AS bus_end_m,
    :'street_parking_point_offset_parallel_m'::double precision AS offset_parallel_m,
    :'street_parking_point_offset_diagonal_m'::double precision AS offset_diagonal_m,
    :'street_parking_point_offset_perpendicular_m'::double precision AS offset_perp_m,
    :'street_parking_point_diagonal_along_m'::double precision AS diagonal_along_m,
    :'street_parking_sample_m'::double precision AS sample_m,
    :'street_parking_parallel_az_window_m'::double precision AS az_window_m,
    :'parking_outline_min_length'::double precision AS min_length_m;

CREATE OR REPLACE FUNCTION pg_temp.spm_vtype(cat text, primary_cat text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN primary_cat IN ('emergency', 'bus', 'hgv') THEN primary_cat
        WHEN cat ~* '(^|;\s*)emergency(\s*\(|\s*;|$)' THEN 'emergency'
        WHEN cat ~* '(^|;\s*)bus(\s*\(|\s*;|$)' THEN 'bus'
        WHEN cat ~* '(^|;\s*)hgv(\s*\(|\s*;|$)' THEN 'hgv'
        WHEN cat ~* 'vehicle_restriction\s*\([^)]*only[^)]*\yemergency\y' THEN 'emergency'
        WHEN cat ~* 'vehicle_restriction\s*\([^)]*only[^)]*\ybus\y' THEN 'bus'
        WHEN cat ~* 'vehicle_restriction\s*\([^)]*only[^)]*\yhgv\y' THEN 'hgv'
        WHEN primary_cat = 'taxi' THEN 'taxi'
        ELSE 'motor_vehicle'
    END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.spm_car_len_m(orientation text)
RETURNS double precision
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT CASE orientation
        WHEN 'diagonal' THEN c.diagonal_m
        WHEN 'perpendicular' THEN c.perpendicular_m
        ELSE c.parallel_m
    END
    FROM _spm_const c;
$$;

CREATE OR REPLACE FUNCTION pg_temp.spm_stall_layout(
    len_m double precision,
    capacity integer,
    car_len double precision,
    vtype text,
    bus_m double precision,
    bus_end_m double precision,
    OUT start_m double precision,
    OUT spacing_m double precision
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    half_m double precision;
    nom_start double precision;
    nom_spacing double precision;
    n integer;
BEGIN
    n := COALESCE(capacity, 0);
    IF vtype = 'bus' THEN
        spacing_m := bus_m;
        start_m := bus_end_m + (len_m - bus_m * n) / 2.0;
        RETURN;
    END IF;
    IF n <= 1 THEN
        spacing_m := 0.0;
        start_m := len_m / 2.0;
        RETURN;
    END IF;

    half_m := car_len / 2.0;
    nom_spacing := car_len;
    nom_start := (len_m - car_len * (n - 1)) / 2.0;
    IF nom_start >= half_m
       AND nom_start + (n - 1) * nom_spacing <= len_m - half_m
    THEN
        start_m := nom_start;
        spacing_m := nom_spacing;
    ELSIF len_m > car_len THEN
        start_m := half_m;
        spacing_m := (len_m - car_len) / (n - 1);
    ELSE
        start_m := nom_start;
        spacing_m := nom_spacing;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.spm_az(
    line geometry,
    f double precision,
    len_m double precision
)
RETURNS double precision
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT degrees(ST_Azimuth(
        ST_LineInterpolatePoint(
            line,
            GREATEST(
                0.0,
                f - metres(c.az_window_m) / NULLIF(len_m, 0.0)
            )
        ),
        ST_LineInterpolatePoint(
            line,
            LEAST(
                1.0,
                f + metres(c.az_window_m) / NULLIF(len_m, 0.0)
            )
        )
    ))
    FROM _spm_const c;
$$;

-- Same kerb-side sign as street_parking_point.parking_kerb_sign.
-- TILDA separate-area lane/half_on_kerb: vehicles/stalls on the right.
CREATE OR REPLACE FUNCTION pg_temp.spm_kerb_sign(
    parking text,
    street_side_back boolean,
    tilda_separate_area boolean DEFAULT false
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN COALESCE(tilda_separate_area, false)
             AND parking IN ('lane', 'half_on_kerb')
        THEN CASE WHEN COALESCE(street_side_back, false) THEN 1.0 ELSE -1.0 END
        WHEN parking IN ('on_kerb', 'shoulder') THEN -1.0
        WHEN parking = 'street_side' THEN
            CASE WHEN COALESCE(street_side_back, false) THEN 1.0 ELSE -1.0 END
        WHEN parking = 'half_on_kerb' THEN 0.0
        ELSE 1.0
    END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.spm_translate(
    pt geometry,
    line_az double precision,
    orientation text,
    side_sign double precision,
    scale double precision,
    road_oneway text,
    side text,
    road_left boolean
)
RETURNS geometry
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT ST_Translate(
        pt,
        metres(
            -cos(radians(line_az))
            * CASE orientation
                WHEN 'diagonal' THEN c.offset_diagonal_m
                WHEN 'perpendicular' THEN c.offset_perp_m
                ELSE c.offset_parallel_m
              END
            * scale
            * side_sign
            * CASE WHEN COALESCE(road_left, true) THEN 1.0 ELSE -1.0 END
            + sin(radians(line_az))
            * CASE WHEN orientation = 'diagonal' THEN c.diagonal_along_m ELSE 0.0 END
            * scale
            * CASE WHEN road_oneway = 'yes' AND side = 'left' THEN 1.0 ELSE -1.0 END
            * side_sign
            * CASE WHEN COALESCE(road_left, true) THEN 1.0 ELSE -1.0 END
        ),
        metres(
            sin(radians(line_az))
            * CASE orientation
                WHEN 'diagonal' THEN c.offset_diagonal_m
                WHEN 'perpendicular' THEN c.offset_perp_m
                ELSE c.offset_parallel_m
              END
            * scale
            * side_sign
            * CASE WHEN COALESCE(road_left, true) THEN 1.0 ELSE -1.0 END
            + cos(radians(line_az))
            * CASE WHEN orientation = 'diagonal' THEN c.diagonal_along_m ELSE 0.0 END
            * scale
            * CASE WHEN road_oneway = 'yes' AND side = 'left' THEN 1.0 ELSE -1.0 END
            * side_sign
            * CASE WHEN COALESCE(road_left, true) THEN 1.0 ELSE -1.0 END
        )
    )
    FROM _spm_const c;
$$;

DROP TABLE IF EXISTS _spm_src;
CREATE TEMP TABLE _spm_src (
    line_rid bigint,
    source_id text,
    parking text,
    orientation text,
    capacity integer,
    condition_category text,
    condition_category_primary text,
    road_oneway text,
    side text,
    road_left boolean,
    vtype text,
    geom geometry,
    len_m double precision,
    layer integer,
    street_side_back boolean,
    tilda_separate_area boolean
);

DO $spm$
BEGIN
    IF to_regclass('public.street_parking') IS NULL THEN
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking'
          AND column_name = 'source'
    ) THEN
        RAISE NOTICE 'street_parking.source missing — skip stall markings';
        RETURN;
    END IF;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS layer integer;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS street_side_back boolean;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS tilda_separate_area boolean;

    INSERT INTO _spm_src
    SELECT
        row_number() OVER () AS line_rid,
        s.source_id,
        s.parking,
        s.orientation,
        s.capacity,
        s.condition_category,
        s.condition_category_primary,
        s.road_oneway,
        s.side,
        COALESCE(s.road_left, true) AS road_left,
        pg_temp.spm_vtype(s.condition_category, s.condition_category_primary) AS vtype,
        s.geom,
        ST_Length(s.geom) / metres(1) AS len_m,
        s.layer,
        COALESCE(s.street_side_back, false) AS street_side_back,
        COALESCE(s.tilda_separate_area, false) AS tilda_separate_area
    FROM street_parking s
    WHERE s.geom IS NOT NULL
      AND NOT ST_IsEmpty(s.geom)
      AND ST_GeometryType(s.geom) = 'ST_LineString'
      AND ST_NPoints(s.geom) >= 2
      AND s.capacity IS NOT NULL
      AND s.capacity >= 1
      AND s.markings = 'yes'
      AND COALESCE(s.source, '') NOT ILIKE '%separate%'
      AND ST_Length(s.geom) > 0;
END;
$spm$;

CREATE INDEX _spm_src_rid_idx ON _spm_src (line_rid);

DROP TABLE IF EXISTS _spm_side;
CREATE TEMP TABLE _spm_side AS
SELECT
    s.*,
    CASE
        WHEN s.parking = 'half_on_kerb'
             AND NOT COALESCE(s.tilda_separate_area, false)
        THEN 1.0
        ELSE 2.0
    END AS scale,
    gs.side_sign
FROM _spm_src s
CROSS JOIN LATERAL (
    SELECT unnest(
        CASE
            WHEN s.parking = 'half_on_kerb'
                 AND NOT COALESCE(s.tilda_separate_area, false)
            THEN ARRAY[-1.0, 1.0]
            ELSE ARRAY[
                pg_temp.spm_kerb_sign(
                    s.parking, s.street_side_back, s.tilda_separate_area
                )
            ]
        END
    ) AS side_sign
) gs;

DROP TABLE IF EXISTS _spm_frame;
CREATE TEMP TABLE _spm_frame AS
SELECT
    x.source_id,
    'outer'::text AS class,
    ST_MakeLine(x.pts) AS geom,
    x.layer
FROM (
    SELECT
        sd.line_rid,
        sd.source_id,
        sd.side_sign,
        sd.layer,
        array_agg(
            pg_temp.spm_translate(
                d.pt,
                pg_temp.spm_az(sd.geom, d.f, sd.len_m),
                sd.orientation,
                sd.side_sign,
                sd.scale,
                sd.road_oneway,
                sd.side,
                sd.road_left
            )
            ORDER BY d.ord
        ) AS pts
    FROM _spm_side sd
    CROSS JOIN LATERAL (
        SELECT
            (dp).path[1] AS ord,
            (dp).geom AS pt,
            ST_LineLocatePoint(sd.geom, (dp).geom) AS f
        FROM ST_DumpPoints(
            ST_Segmentize(sd.geom, metres((SELECT sample_m FROM _spm_const)))
        ) AS dp
    ) d
    GROUP BY sd.line_rid, sd.source_id, sd.side_sign, sd.layer
) x
WHERE x.pts IS NOT NULL
  AND array_length(x.pts, 1) >= 2;

DROP TABLE IF EXISTS _spm_div;
CREATE TEMP TABLE _spm_div AS
WITH spaced AS (
    SELECT
        s.*,
        lay.spacing_m,
        lay.start_m
    FROM _spm_src s
    CROSS JOIN _spm_const c
    CROSS JOIN LATERAL pg_temp.spm_stall_layout(
        s.len_m,
        s.capacity,
        pg_temp.spm_car_len_m(s.orientation),
        s.vtype,
        c.bus_m,
        c.bus_end_m
    ) AS lay
),
fracs AS (
    SELECT
        sp.*,
        0.0::double precision AS f,
        'outer'::text AS class
    FROM spaced sp
    UNION ALL
    SELECT
        sp.*,
        1.0::double precision AS f,
        'outer'::text AS class
    FROM spaced sp
    UNION ALL
    SELECT
        sp.*,
        GREATEST(
            0.0,
            LEAST(
                1.0,
                (sp.start_m + (gs.i + 0.5) * sp.spacing_m) / NULLIF(sp.len_m, 0.0)
            )
        ) AS f,
        'inner'::text AS class
    FROM spaced sp
    CROSS JOIN LATERAL generate_series(0, sp.capacity - 2) AS gs(i)
    WHERE sp.capacity >= 2
      AND sp.len_m > 0
)
SELECT
    f.source_id,
    f.class,
    f.layer,
    CASE
        WHEN f.parking = 'half_on_kerb'
             AND NOT COALESCE(f.tilda_separate_area, false) THEN
            ST_MakeLine(
                pg_temp.spm_translate(
                    pt.geom, az.az, f.orientation, -1.0, 1.0, f.road_oneway, f.side, f.road_left
                ),
                pg_temp.spm_translate(
                    pt.geom, az.az, f.orientation, 1.0, 1.0, f.road_oneway, f.side, f.road_left
                )
            )
        ELSE
            ST_MakeLine(
                pt.geom,
                pg_temp.spm_translate(
                    pt.geom,
                    az.az,
                    f.orientation,
                    pg_temp.spm_kerb_sign(
                        f.parking, f.street_side_back, f.tilda_separate_area
                    ),
                    2.0,
                    f.road_oneway,
                    f.side,
                    f.road_left
                )
            )
    END AS geom
FROM fracs f
CROSS JOIN LATERAL (SELECT ST_LineInterpolatePoint(f.geom, f.f) AS geom) pt
CROSS JOIN LATERAL (SELECT pg_temp.spm_az(f.geom, f.f, f.len_m) AS az) az
WHERE pt.geom IS NOT NULL
  AND az.az IS NOT NULL;

DELETE FROM road_marking_way
WHERE source = 'street_parking';

INSERT INTO road_marking_way (
    osm_type,
    osm_id,
    source,
    road_marking,
    stroke,
    dasharray,
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
    'W'::text AS osm_type,
    hashtext(m.source_id)::bigint AS osm_id,
    'street_parking'::text AS source,
    'parking_edge'::text AS road_marking,
    'solid'::text AS stroke,
    NULL::text AS dasharray,
    NULL::text AS pattern,
    NULL::text AS arrow,
    NULL::text AS symbol,
    0.12::real AS width,
    NULL::real AS length,
    'white'::text AS colour,
    NULL::real AS direction,
    'parking'::text AS type,
    m.class,
    m.layer,
    m.geom
FROM (
    SELECT source_id, class, layer, geom FROM _spm_frame
    UNION ALL
    SELECT source_id, class, layer, geom FROM _spm_div
) m
WHERE m.geom IS NOT NULL
  AND NOT ST_IsEmpty(m.geom)
  AND ST_GeometryType(m.geom) = 'ST_LineString'
  AND ST_Length(m.geom) > metres(:'parking_outline_min_length'::numeric);

\echo
\echo '=== street_parking stall markings ==='
SELECT
    (SELECT count(*) FROM _spm_src) AS source_lines,
    (SELECT count(*) FROM _spm_frame) AS frame_lines,
    (SELECT count(*) FROM road_marking_way WHERE source = 'street_parking' AND class = 'outer') AS outer_rows,
    (SELECT count(*) FROM road_marking_way WHERE source = 'street_parking' AND class = 'inner') AS inner_rows;

SELECT parking, orientation, count(*) AS n
FROM _spm_src
GROUP BY parking, orientation
ORDER BY n DESC;


----------------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_outline_sources;
DROP TABLE IF EXISTS _parking_outline_raw;
DROP TABLE IF EXISTS _parking_kerbs;
DROP TABLE IF EXISTS _parking_outline_no_kerb;
DROP TABLE IF EXISTS _parking_lot_boundaries;
DROP TABLE IF EXISTS _parking_outline_no_lot_edge;
DROP TABLE IF EXISTS _parking_outline_deduped;
DROP TABLE IF EXISTS _parking_outline_merged;
DROP TABLE IF EXISTS _parking_symbol_sources;
DROP TABLE IF EXISTS _parking_symbol_roads;
DROP TABLE IF EXISTS _parking_symbol_lanes;
DROP TABLE IF EXISTS _parking_symbol_direction;
DROP TABLE IF EXISTS _spm_const;
DROP TABLE IF EXISTS _spm_src;
DROP TABLE IF EXISTS _spm_side;
DROP TABLE IF EXISTS _spm_frame;
DROP TABLE IF EXISTS _spm_div;
