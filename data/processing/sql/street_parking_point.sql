-- street_parking_point.sql — one vehicle point per stall on street_parking lines.
--
-- Evenly spaced points (capacity many), offset to the vehicle centre, with
-- angle = rendered vehicle heading. type comes from TILDA vehicle_restriction
-- (only bus/hgv/emergency) or taxi; some hgv become hgv_articulated (parallel
-- parking only: three stalls → one long vehicle). A baseline share of
-- motor_vehicle becomes hgv; extra hgv mix in commercial/industrial landuse.
-- Overlapping median / lane_centre boxes keep one vehicle.
-- type is the SVG stem (motor_vehicle becomes motor_vehicle01/02). colour is
-- a stable weighted palette mixed with the road fill so vehicles recede.
--
-- Depends on: street_parking (street_parking.sql); landuse (osm import)
-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

DO $$
BEGIN
    IF to_regclass('public.street_parking') IS NULL THEN
        RAISE EXCEPTION 'street_parking is missing — run street_parking.sql first';
    END IF;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS layer integer;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS street_side_back boolean;
    ALTER TABLE public.street_parking ADD COLUMN IF NOT EXISTS tilda_separate_area boolean;
END $$;

SELECT setseed(:'street_parking_point_seed'::double precision) AS _spp_seed \gset

DROP TABLE IF EXISTS _spp_const;
CREATE TEMP TABLE _spp_const AS
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
    :'street_parking_point_hgv_buffer_m'::double precision AS hgv_buffer_m,
    :'street_parking_point_hgv_angle_deg'::double precision AS hgv_angle_deg,
    :'street_parking_point_hgv_prob'::double precision AS hgv_prob,
    :'street_parking_point_landuse_buffer_m'::double precision AS landuse_buffer_m,
    :'street_parking_point_commercial_hgv'::double precision AS commercial_hgv,
    :'street_parking_point_industrial_hgv'::double precision AS industrial_hgv,
    :'street_parking_point_industrial_articulated'::double precision AS industrial_articulated,
    :'street_parking_point_box_length_m'::double precision AS box_length_m,
    :'street_parking_point_box_width_m'::double precision AS box_width_m,
    :'street_parking_parallel_az_window_m'::double precision AS az_window_m,
    :'street_parking_point_colour_taxi'::text AS colour_taxi,
    :'street_parking_point_colour_emergency'::text AS colour_emergency,
    :'street_parking_point_colour_road'::text AS colour_road,
    :'street_parking_point_colour_mix'::double precision AS colour_mix;

DROP TABLE IF EXISTS _spp_colour;
CREATE TEMP TABLE _spp_colour AS
SELECT
    t.ord,
    trim(t.hex) AS hex,
    trim(t.weight)::integer AS weight,
    SUM(trim(t.weight)::integer) OVER (ORDER BY t.ord) AS cum
FROM unnest(
    string_to_array(:'street_parking_point_colours', ','),
    string_to_array(:'street_parking_point_colour_weights', ',')
) WITH ORDINALITY AS t(hex, weight, ord);

DO $$
DECLARE
    n_rows integer;
    n_bad integer;
    total integer;
BEGIN
    SELECT count(*), count(*) FILTER (
        WHERE hex IS NULL OR hex = '' OR weight IS NULL OR weight < 0
    )
      INTO n_rows, n_bad
    FROM _spp_colour;
    SELECT COALESCE(max(cum), 0) INTO total FROM _spp_colour;
    IF n_rows < 1 OR n_bad > 0 OR total < 1 THEN
        RAISE EXCEPTION
            'street_parking_point colour params invalid (% rows, % bad, total weight %)',
            n_rows, n_bad, total;
    END IF;
END $$;

ALTER TABLE _spp_const ADD COLUMN colour_weight_total integer;
UPDATE _spp_const SET colour_weight_total = (SELECT max(cum) FROM _spp_colour);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- +1 = left of line direction (toward the road when road_left); -1 = right.
-- street_parking.py street_side lines sit at the bay back → left (+1).
-- TILDA separate-area lines are the road-facing polygon edge; lane and
-- half_on_kerb use the same sign as street_side (vehicles on the right).
CREATE OR REPLACE FUNCTION pg_temp.parking_kerb_sign(
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

CREATE OR REPLACE FUNCTION pg_temp.parking_vehicle_type(
    cat text,
    primary_cat text
)
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

CREATE OR REPLACE FUNCTION pg_temp.parking_car_len_m(orientation text)
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
    FROM _spp_const c;
$$;

-- Even spacing along a kerb; first/last stall centre at least half a car from the ends.
CREATE OR REPLACE FUNCTION pg_temp.parking_stall_layout(
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

CREATE OR REPLACE FUNCTION pg_temp.heading_diff_deg(a double precision, b double precision)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN a IS NULL OR b IS NULL THEN NULL
        ELSE LEAST(
            mod(abs(a - b)::numeric, 360)::double precision,
            360.0 - mod(abs(a - b)::numeric, 360)::double precision
        )
    END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_heading_deg(
    line_az double precision,
    orientation text,
    road_oneway text,
    side text
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT mod(
        (
            CASE orientation
                WHEN 'diagonal' THEN
                    line_az + CASE
                        WHEN road_oneway = 'yes' AND side = 'left' THEN 126.0
                        ELSE 54.0
                    END
                WHEN 'perpendicular' THEN
                    line_az - 90.0
                ELSE
                    line_az + CASE
                        WHEN road_oneway = 'yes' AND side = 'left' THEN 180.0
                        ELSE 0.0
                    END
            END
            + 3600.0
        )::numeric,
        360
    )::double precision;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_style_key(source_id text, geom geometry)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT concat(
        COALESCE(source_id, ''),
        '|',
        round(ST_X(geom)::numeric, 1)::text,
        '|',
        round(ST_Y(geom)::numeric, 1)::text
    );
$$;

CREATE OR REPLACE FUNCTION pg_temp.mix_hex(a text, b text, t double precision)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    ha text;
    hb text;
    mix double precision;
    da bytea;
    db bytea;
    r int;
    g int;
    bl int;
BEGIN
    mix := GREATEST(0.0, LEAST(1.0, COALESCE(t, 0.5)));
    ha := substr(replace(upper(COALESCE(a, '#808080')), '#', ''), 1, 6);
    hb := substr(replace(upper(COALESCE(b, '#A8A8A7')), '#', ''), 1, 6);
    IF ha !~ '^[0-9A-F]{6}$' OR hb !~ '^[0-9A-F]{6}$' THEN
        RETURN COALESCE(a, b);
    END IF;
    da := decode(ha, 'hex');
    db := decode(hb, 'hex');
    r := GREATEST(0, LEAST(255, round((get_byte(da, 0) * (1.0 - mix) + get_byte(db, 0) * mix)::numeric)::int));
    g := GREATEST(0, LEAST(255, round((get_byte(da, 1) * (1.0 - mix) + get_byte(db, 1) * mix)::numeric)::int));
    bl := GREATEST(0, LEAST(255, round((get_byte(da, 2) * (1.0 - mix) + get_byte(db, 2) * mix)::numeric)::int));
    RETURN upper(
        '#'
        || lpad(to_hex(r), 2, '0')
        || lpad(to_hex(g), 2, '0')
        || lpad(to_hex(bl), 2, '0')
    );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_vehicle_box(
    pt geometry,
    angle_deg double precision,
    length_m double precision,
    width_m double precision
)
RETURNS geometry
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT ST_Rotate(
        ST_MakeEnvelope(
            ST_X(pt) - metres(width_m) / 2.0,
            ST_Y(pt) - metres(length_m) / 2.0,
            ST_X(pt) + metres(width_m) / 2.0,
            ST_Y(pt) + metres(length_m) / 2.0,
            ST_SRID(pt)
        ),
        -radians(COALESCE(angle_deg, 0.0)),
        ST_X(pt),
        ST_Y(pt)
    );
$$;

-- ---------------------------------------------------------------------------
-- 1) Source lines
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _spp_line;
CREATE TEMP TABLE _spp_line AS
SELECT
    row_number() OVER () AS line_rid,
    s.source_id,
    s.parking,
    s.orientation,
    s.capacity,
    s.condition_category_primary,
    s.condition_category,
    s.surface,
    s.markings,
    s.location,
    s.direction,
    s.road_oneway,
    s.side,
    s.staggered,
    COALESCE(s.road_left, true) AS road_left,
    s.layer,
    COALESCE(s.street_side_back, false) AS street_side_back,
    COALESCE(s.tilda_separate_area, false) AS tilda_separate_area,
    s.geom,
    ST_Length(s.geom) / metres(1) AS len_m,
    pg_temp.parking_vehicle_type(s.condition_category, s.condition_category_primary) AS vtype
FROM street_parking s
WHERE s.geom IS NOT NULL
  AND NOT ST_IsEmpty(s.geom)
  AND ST_GeometryType(s.geom) = 'ST_LineString'
  AND ST_NPoints(s.geom) >= 2
  AND s.capacity IS NOT NULL
  AND s.capacity >= 1
  AND ST_Length(s.geom) > 0;

CREATE INDEX _spp_line_rid_idx ON _spp_line (line_rid);

-- ---------------------------------------------------------------------------
-- 2) Evenly spaced points on the line, local azimuth, offset, heading
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _spp_pt;
CREATE TEMP TABLE _spp_pt AS
WITH spaced AS (
    SELECT
        l.*,
        gs.i AS seq,
        lay.spacing_m,
        lay.start_m
    FROM _spp_line l
    CROSS JOIN _spp_const c
    CROSS JOIN LATERAL pg_temp.parking_stall_layout(
        l.len_m,
        l.capacity,
        pg_temp.parking_car_len_m(l.orientation),
        l.vtype,
        c.bus_m,
        c.bus_end_m
    ) AS lay
    CROSS JOIN LATERAL generate_series(0, l.capacity - 1) AS gs(i)
),
placed AS (
    SELECT
        s.*,
        GREATEST(
            0.0,
            LEAST(
                1.0,
                CASE
                    WHEN s.len_m <= 0 THEN 0.5
                    ELSE (s.start_m + s.seq * s.spacing_m) / s.len_m
                END
            )
        ) AS f
    FROM spaced s
),
az AS (
    SELECT
        p.*,
        ST_LineInterpolatePoint(p.geom, p.f) AS pt_on_line,
        degrees(ST_Azimuth(
            ST_LineInterpolatePoint(
                p.geom,
                GREATEST(
                    0.0,
                    p.f - metres(:'street_parking_parallel_az_window_m'::double precision) / p.len_m
                )
            ),
            ST_LineInterpolatePoint(
                p.geom,
                LEAST(
                    1.0,
                    p.f + metres(:'street_parking_parallel_az_window_m'::double precision) / p.len_m
                )
            )
        )) AS line_az
    FROM placed p
)
SELECT
    row_number() OVER () AS pt_id,
    a.line_rid,
    a.source_id,
    a.seq,
    a.parking,
    a.orientation,
    a.capacity,
    a.condition_category_primary,
    a.condition_category,
    a.surface,
    a.markings,
    a.location,
    a.direction,
    a.road_oneway,
    a.side,
    a.staggered,
    a.road_left,
    a.vtype AS type,
    random() AS r,
    pg_temp.parking_heading_deg(a.line_az, a.orientation, a.road_oneway, a.side) AS angle,
    ST_Translate(
        a.pt_on_line,
        metres(
            -cos(radians(a.line_az))
            * CASE a.orientation
                WHEN 'diagonal' THEN :'street_parking_point_offset_diagonal_m'::double precision
                WHEN 'perpendicular' THEN :'street_parking_point_offset_perpendicular_m'::double precision
                ELSE :'street_parking_point_offset_parallel_m'::double precision
              END
            * pg_temp.parking_kerb_sign(a.parking, a.street_side_back, a.tilda_separate_area)
            * CASE WHEN a.road_left THEN 1.0 ELSE -1.0 END
            + sin(radians(a.line_az))
            * CASE WHEN a.orientation = 'diagonal'
                THEN :'street_parking_point_diagonal_along_m'::double precision
                ELSE 0.0
              END
            * CASE WHEN a.road_oneway = 'yes' AND a.side = 'left' THEN 1.0 ELSE -1.0 END
            * pg_temp.parking_kerb_sign(a.parking, a.street_side_back, a.tilda_separate_area)
            * CASE WHEN a.road_left THEN 1.0 ELSE -1.0 END
        ),
        metres(
            sin(radians(a.line_az))
            * CASE a.orientation
                WHEN 'diagonal' THEN :'street_parking_point_offset_diagonal_m'::double precision
                WHEN 'perpendicular' THEN :'street_parking_point_offset_perpendicular_m'::double precision
                ELSE :'street_parking_point_offset_parallel_m'::double precision
              END
            * pg_temp.parking_kerb_sign(a.parking, a.street_side_back, a.tilda_separate_area)
            * CASE WHEN a.road_left THEN 1.0 ELSE -1.0 END
            + cos(radians(a.line_az))
            * CASE WHEN a.orientation = 'diagonal'
                THEN :'street_parking_point_diagonal_along_m'::double precision
                ELSE 0.0
              END
            * CASE WHEN a.road_oneway = 'yes' AND a.side = 'left' THEN 1.0 ELSE -1.0 END
            * pg_temp.parking_kerb_sign(a.parking, a.street_side_back, a.tilda_separate_area)
            * CASE WHEN a.road_left THEN 1.0 ELSE -1.0 END
        )
    ) AS geom,
    false AS deleted
FROM az a
WHERE a.pt_on_line IS NOT NULL
  AND a.line_az IS NOT NULL;

CREATE INDEX _spp_pt_line_idx ON _spp_pt (line_rid, seq);
CREATE INDEX _spp_pt_id_idx ON _spp_pt (pt_id);
CREATE INDEX _spp_pt_geom_idx ON _spp_pt USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 3) Restriction-HGV: occasional articulated truck (drop two neighbours)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    rec record;
    prev_id bigint;
    next_id bigint;
    prev_geom geometry;
    next_geom geometry;
    prev_ang double precision;
    next_ang double precision;
    buf double precision;
    max_ang double precision;
    prob double precision;
BEGIN
    SELECT metres(c.hgv_buffer_m), c.hgv_angle_deg, c.hgv_prob
      INTO buf, max_ang, prob
    FROM _spp_const c;
    FOR rec IN
        SELECT pt_id, line_rid, seq, geom, angle
        FROM _spp_pt
        WHERE type = 'hgv'
          AND NOT deleted
          -- articulated occupies three stalls along the kerb → parallel only
          AND COALESCE(NULLIF(orientation, ''), 'parallel') = 'parallel'
        ORDER BY line_rid, seq
    LOOP
        IF (SELECT deleted FROM _spp_pt WHERE pt_id = rec.pt_id) THEN
            CONTINUE;
        END IF;
        prev_id := NULL;
        next_id := NULL;
        SELECT p.pt_id, p.geom, p.angle
          INTO prev_id, prev_geom, prev_ang
        FROM _spp_pt p
        WHERE p.line_rid = rec.line_rid AND p.seq = rec.seq - 1;
        SELECT n.pt_id, n.geom, n.angle
          INTO next_id, next_geom, next_ang
        FROM _spp_pt n
        WHERE n.line_rid = rec.line_rid AND n.seq = rec.seq + 1;
        IF prev_id IS NULL OR next_id IS NULL THEN
            CONTINUE;
        END IF;
        IF (SELECT deleted FROM _spp_pt WHERE pt_id = prev_id)
           OR (SELECT deleted FROM _spp_pt WHERE pt_id = next_id)
        THEN
            CONTINUE;
        END IF;
        IF ST_Distance(rec.geom, prev_geom) >= buf
           OR ST_Distance(rec.geom, next_geom) >= buf
        THEN
            CONTINUE;
        END IF;
        IF pg_temp.heading_diff_deg(rec.angle, prev_ang) >= max_ang
           OR pg_temp.heading_diff_deg(rec.angle, next_ang) >= max_ang
        THEN
            CONTINUE;
        END IF;
        IF random() < prob THEN
            UPDATE _spp_pt SET type = 'hgv_articulated' WHERE pt_id = rec.pt_id;
            UPDATE _spp_pt SET deleted = true WHERE pt_id IN (prev_id, next_id);
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4) Landuse mix: more hgv in commercial / industrial
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _spp_lu_zone;
CREATE TEMP TABLE _spp_lu_zone AS
SELECT
    u.class,
    dumped.geom
FROM (
    SELECT
        lu.class,
        ST_Buffer(
            ST_UnaryUnion(ST_Collect(ST_Buffer(lu.geom, metres(:'street_parking_point_landuse_buffer_m'::double precision)))),
            metres(-1.0 * :'street_parking_point_landuse_buffer_m'::double precision)
        ) AS geom
    FROM landuse lu
    WHERE lu.class IN ('commercial', 'industrial')
      AND lu.geom IS NOT NULL
      AND NOT ST_IsEmpty(lu.geom)
    GROUP BY lu.class
) u
CROSS JOIN LATERAL ST_Dump(u.geom) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_Dimension(dumped.geom) = 2;

CREATE INDEX _spp_lu_zone_geom_idx ON _spp_lu_zone USING GIST (geom);

ALTER TABLE _spp_pt ADD COLUMN lu_class text;

UPDATE _spp_pt p
SET lu_class = 'industrial'
FROM _spp_lu_zone z
WHERE z.class = 'industrial'
  AND NOT p.deleted
  AND p.geom && z.geom
  AND ST_Intersects(p.geom, z.geom);

UPDATE _spp_pt p
SET lu_class = 'commercial'
FROM _spp_lu_zone z
WHERE p.lu_class IS NULL
  AND z.class = 'commercial'
  AND NOT p.deleted
  AND p.geom && z.geom
  AND ST_Intersects(p.geom, z.geom);

DO $$
DECLARE
    rec record;
    prev_id bigint;
    next_id bigint;
    prev_geom geometry;
    next_geom geometry;
    prev_ang double precision;
    next_ang double precision;
    buf double precision;
    max_ang double precision;
    p_art double precision;
BEGIN
    SELECT metres(c.hgv_buffer_m), c.hgv_angle_deg, c.industrial_articulated
      INTO buf, max_ang, p_art
    FROM _spp_const c;
    FOR rec IN
        SELECT pt_id, line_rid, seq, geom, angle, r
        FROM _spp_pt
        WHERE type = 'motor_vehicle'
          AND lu_class = 'industrial'
          AND NOT deleted
          AND r < p_art
          -- articulated occupies three stalls along the kerb → parallel only
          AND COALESCE(NULLIF(orientation, ''), 'parallel') = 'parallel'
        ORDER BY line_rid, seq
    LOOP
        IF (SELECT deleted FROM _spp_pt WHERE pt_id = rec.pt_id) THEN
            CONTINUE;
        END IF;
        prev_id := NULL;
        next_id := NULL;
        SELECT p.pt_id, p.geom, p.angle
          INTO prev_id, prev_geom, prev_ang
        FROM _spp_pt p
        WHERE p.line_rid = rec.line_rid AND p.seq = rec.seq - 1 AND NOT p.deleted;
        SELECT n.pt_id, n.geom, n.angle
          INTO next_id, next_geom, next_ang
        FROM _spp_pt n
        WHERE n.line_rid = rec.line_rid AND n.seq = rec.seq + 1 AND NOT n.deleted;
        IF prev_id IS NULL OR next_id IS NULL THEN
            CONTINUE;
        END IF;
        IF ST_Distance(rec.geom, prev_geom) >= buf
           OR ST_Distance(rec.geom, next_geom) >= buf
        THEN
            CONTINUE;
        END IF;
        IF pg_temp.heading_diff_deg(rec.angle, prev_ang) >= max_ang
           OR pg_temp.heading_diff_deg(rec.angle, next_ang) >= max_ang
        THEN
            CONTINUE;
        END IF;
        UPDATE _spp_pt SET type = 'hgv_articulated' WHERE pt_id = rec.pt_id;
        UPDATE _spp_pt SET deleted = true WHERE pt_id IN (prev_id, next_id);
    END LOOP;
END $$;

UPDATE _spp_pt
SET type = 'hgv'
WHERE type = 'motor_vehicle'
  AND NOT deleted
  AND lu_class = 'industrial'
  AND (
      -- normal industrial hgv band
      (
          r >= :'street_parking_point_industrial_articulated'::double precision
          AND r < (
              :'street_parking_point_industrial_articulated'::double precision
              + :'street_parking_point_industrial_hgv'::double precision
          )
      )
      -- articulated band on non-parallel: no 3-stall merge → plain hgv
      OR (
          r < :'street_parking_point_industrial_articulated'::double precision
          AND COALESCE(NULLIF(orientation, ''), 'parallel') <> 'parallel'
      )
  );

UPDATE _spp_pt
SET type = 'hgv'
WHERE type = 'motor_vehicle'
  AND NOT deleted
  AND lu_class = 'commercial'
  AND r < :'street_parking_point_commercial_hgv'::double precision;

-- Baseline: share of remaining motor_vehicle → hgv (everywhere).
-- Uses the same r as landuse; in commercial/industrial the higher rates
-- already cover this band, so only non-landuse stalls are newly converted.
UPDATE _spp_pt
SET type = 'hgv'
WHERE type = 'motor_vehicle'
  AND NOT deleted
  AND r < :'street_parking_point_base_hgv'::double precision;

-- ---------------------------------------------------------------------------
-- 5) Median / lane_centre collision boxes
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _spp_box;
CREATE TEMP TABLE _spp_box AS
SELECT
    p.pt_id,
    pg_temp.parking_vehicle_box(
        p.geom,
        p.angle,
        :'street_parking_point_box_length_m'::double precision,
        :'street_parking_point_box_width_m'::double precision
    ) AS box
FROM _spp_pt p
WHERE NOT p.deleted
  AND p.location IN ('median', 'lane_centre');

CREATE INDEX _spp_box_idx ON _spp_box USING GIST (box);

ALTER TABLE _spp_pt ADD COLUMN drop_collision boolean NOT NULL DEFAULT false;

DROP TABLE IF EXISTS _spp_keep_box;
CREATE TEMP TABLE _spp_keep_box (
    pt_id bigint PRIMARY KEY,
    box geometry
);
CREATE INDEX _spp_keep_box_g ON _spp_keep_box USING GIST (box);

UPDATE _spp_pt SET drop_collision = false WHERE location IN ('median', 'lane_centre');

DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT b.pt_id, b.box
        FROM _spp_box b
        INNER JOIN _spp_pt p ON p.pt_id = b.pt_id
        WHERE NOT p.deleted
        ORDER BY p.source_id, p.seq, p.pt_id
    LOOP
        IF EXISTS (
            SELECT 1 FROM _spp_keep_box k
            WHERE k.box && rec.box AND ST_Intersects(k.box, rec.box)
        ) THEN
            UPDATE _spp_pt SET drop_collision = true WHERE pt_id = rec.pt_id;
        ELSE
            INSERT INTO _spp_keep_box (pt_id, box) VALUES (rec.pt_id, rec.box);
        END IF;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 6) Output
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS street_parking_point;
CREATE TABLE street_parking_point (
    source_id text,
    type text,
    colour text,
    angle integer,
    layer integer,
    geom geometry
);

INSERT INTO street_parking_point (
    source_id,
    type,
    colour,
    angle,
    layer,
    geom
)
SELECT
    p.source_id,
    CASE
        WHEN p.type = 'motor_vehicle' THEN
            CASE
                WHEN abs(hashtext(pg_temp.parking_style_key(p.source_id, p.geom) || '|model')::bigint) % 2 = 0
                THEN 'motor_vehicle01'
                ELSE 'motor_vehicle02'
            END
        ELSE p.type
    END,
    pg_temp.mix_hex(
        CASE p.type
            WHEN 'taxi' THEN c.colour_taxi
            WHEN 'emergency' THEN c.colour_emergency
            ELSE COALESCE(pal.hex, (SELECT hex FROM _spp_colour ORDER BY ord LIMIT 1))
        END,
        c.colour_road,
        c.colour_mix
    ),
    mod((round(p.angle)::integer + 360), 360) AS angle,
    l.layer,
    p.geom
FROM _spp_pt p
INNER JOIN _spp_line l ON l.line_rid = p.line_rid
CROSS JOIN _spp_const c
LEFT JOIN LATERAL (
    SELECT col.hex
    FROM _spp_colour col
    WHERE col.cum > (
        abs(hashtext(pg_temp.parking_style_key(p.source_id, p.geom))::bigint)
        % c.colour_weight_total
    )
    ORDER BY col.ord
    LIMIT 1
) pal ON true
WHERE NOT p.deleted
  AND NOT p.drop_collision
  AND p.geom IS NOT NULL
  AND NOT ST_IsEmpty(p.geom)
  AND ST_GeometryType(p.geom) = 'ST_Point';

CREATE INDEX street_parking_point_geom_idx ON street_parking_point USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 7) Stats
-- ---------------------------------------------------------------------------

\echo
\echo '=== street_parking_point ==='
SELECT
    (SELECT count(*) FROM _spp_line) AS source_lines,
    (SELECT count(*) FROM _spp_pt) AS generated_points,
    (SELECT count(*) FROM _spp_pt WHERE deleted) AS dropped_hgv_neighbours,
    (SELECT count(*) FROM _spp_pt WHERE drop_collision) AS dropped_median_collisions,
    (SELECT count(*) FROM street_parking_point) AS output_points;
\echo
\echo 'points by type:'
SELECT type, count(*) FROM street_parking_point GROUP BY type ORDER BY count(*) DESC;
\echo
