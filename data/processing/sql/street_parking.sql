-- street_parking.sql — snap street-parking lines to carriageway outer edges
-- and split snapped lines at kinks (> split_angle_deg).
--
-- Parking lines whose test points are mostly (min_coverage) within snap_max_m
-- of a carriageway outer edge are projected onto that edge. Unmatched lines
-- stay unchanged. Lines derived from separately mapped parking areas
-- (source matching *separate*area*: TILDA separate_parking_areas,
-- street_parking.py separate_area) stay at their mapped location and are
-- never snapped. Snapped lines are split where the azimuth turns more than
-- split_angle_deg. Afterwards every segment (between two vertices) whose
-- undirected azimuth deviates more than parallel_max_deg from the original
-- line at its nearest point is dropped; the remaining segments are rejoined.
-- Capacity is always re-estimated from kerb length and orientation (TILDA
-- formula, FLOOR). Import capacity is ignored. Pieces with capacity < 1
-- are dropped; diagonal/perpendicular with capacity < 2 too, except when
-- source is a separate parking geometry (*separate*).
-- Staggered parking is clipped from tubes along the parent OSM ways in
-- geom_sources (way/id;way/id). Ways with the same name that share a vertex
-- are merged; a deterministic 1 / N(3-7) pattern along that line clips
-- packets on alternating sides and maneuver gaps on both.
-- Record whether the carriageway lies to the left of the line (road_left)
-- from the parent OSM way in geom_sources (cross product). If that way is
-- missing from highway, fall back to the nearest *parallel* road centerline
-- (including highway=construction with construction in the road classes).
-- Offsets use that sign so vehicles sit toward/away from the road without
-- reversing the line. Missing road_oneway is filled from the nearest oneway
-- highway.
--
-- layer is taken from highway: MAX(layer) of ways listed in geom_sources
-- (way/id;…), else the nearest highway within layer_search_m, else NULL.
-- street_parking.py street_side lines sit at the back of the bay (not the
-- kerb); street_side_back flips the vehicle/marking offset to the left.
-- TILDA lines from separate parking areas (source separate_parking_areas)
-- are the polygon's road-facing edge; vehicles sit on the right of that
-- line. parking=lane and parking=half_on_kerb therefore use the same
-- offset/heading as street_side.
--
-- Depends on: highway_area (highway_area_merge.sql); highway;
--             street_parking_import (ogr2ogr of parking/street_parking.gpkg
--             or street_parking.py GeoJSON — schema is normalised below)
-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'
\i 'processing/sql/helper/highway_road_area.sql'

-- ---------------------------------------------------------------------------
-- 0) Import table: require fid + render attributes
--    Map street_parking.py columns onto the TILDA names used below.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.spc_import_has_col(cname text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = cname
    );
$$;

CREATE OR REPLACE FUNCTION pg_temp.spc_ensure_text_col(cname text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT pg_temp.spc_import_has_col(cname) THEN
        EXECUTE format(
            'ALTER TABLE public.street_parking_import ADD COLUMN %I text',
            cname
        );
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.spc_copy_text(src_names text[], dest_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    src text;
BEGIN
    PERFORM pg_temp.spc_ensure_text_col(dest_name);
    FOREACH src IN ARRAY src_names LOOP
        IF pg_temp.spc_import_has_col(src) THEN
            EXECUTE format(
                'UPDATE public.street_parking_import
                 SET %I = NULLIF(btrim(%I::text), '''')
                 WHERE (%I IS NULL OR btrim(%I::text) = '''')
                   AND %I IS NOT NULL
                   AND btrim(%I::text) <> ''''',
                dest_name, src, dest_name, dest_name, src, src
            );
        END IF;
    END LOOP;
END;
$$;

-- street_parking.py: "class @ (time)" → TILDA: "class (time)"
CREATE OR REPLACE FUNCTION pg_temp.parking_condition_at_to_paren(cat text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT NULLIF(btrim(regexp_replace(cat, '\s*@\s*', ' ', 'g')), '');
$$;

-- Fold vehicle_designated into condition_category for rendering.
CREATE OR REPLACE FUNCTION pg_temp.parking_merge_vehicles(cat text, designated text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    result text;
    piece text;
    tok text;
    only_vehs text[] := ARRAY[]::text[];
    extra text;
BEGIN
    result := NULLIF(btrim(COALESCE(cat, '')), '');

    IF designated IS NULL OR btrim(designated) = '' THEN
        RETURN result;
    END IF;

    FOREACH piece IN ARRAY regexp_split_to_array(designated, ';') LOOP
        tok := lower(btrim(piece));
        tok := btrim(split_part(tok, '@', 1));
        tok := COALESCE((regexp_match(tok, '^[a-z0-9_]+'))[1], '');
        CONTINUE WHEN tok = '';

        IF tok IN ('taxi', 'disabled', 'disabled_private', 'car_sharing') THEN
            IF result IS NULL
               OR result !~* ('(^|;\s*)' || tok || '(\s*\(|\s*;|$)')
            THEN
                result := CASE
                    WHEN result IS NULL THEN tok
                    ELSE result || '; ' || tok
                END;
            END IF;
        ELSIF tok IN ('emergency', 'bus', 'hgv') THEN
            IF NOT tok = ANY (only_vehs) THEN
                only_vehs := only_vehs || tok;
            END IF;
        END IF;
    END LOOP;

    IF array_length(only_vehs, 1) IS NOT NULL THEN
        IF result IS NULL
           OR result !~* 'vehicle_restriction\s*\([^)]*only'
        THEN
            extra := 'vehicle_restriction (only '
                || array_to_string(only_vehs, ', ')
                || ')';
            result := CASE
                WHEN result IS NULL THEN extra
                ELSE result || '; ' || extra
            END;
        END IF;
    END IF;

    RETURN result;
END;
$$;

-- TILDA condition_category_primary order (first match among bases wins).
CREATE OR REPLACE FUNCTION pg_temp.parking_condition_primary(cat text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    priority text[] := ARRAY[
        'disabled',
        'disabled_private',
        'taxi',
        'loading',
        'charging',
        'car_sharing',
        'no_parking',
        'no_stopping',
        'bus_lane',
        'private',
        'assumed_private',
        'vehicle_restriction',
        'access_restriction',
        'maxweight',
        'time_limited',
        'mixed',
        'residents',
        'paid',
        'unspecified',
        'free',
        'assumed_free',
        'invalid'
    ];
    bases text[] := ARRAY[]::text[];
    segment text;
    base text;
    p text;
BEGIN
    IF cat IS NULL OR btrim(cat) = '' THEN
        RETURN 'default';
    END IF;

    FOREACH segment IN ARRAY regexp_split_to_array(cat, ';') LOOP
        base := btrim(segment);
        base := btrim(regexp_replace(base, '\s*\(.*$', ''));
        IF base <> '' THEN
            bases := bases || base;
        END IF;
    END LOOP;

    FOREACH p IN ARRAY priority LOOP
        IF p = ANY (bases) THEN
            RETURN p;
        END IF;
    END LOOP;

    RETURN 'default';
END;
$$;

DO $$
BEGIN
    IF to_regclass('public.street_parking_import') IS NULL THEN
        RAISE EXCEPTION 'street_parking_import is missing — import parking GPKG or GeoJSON first';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'fid'
    ) THEN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'street_parking_import'
              AND column_name = 'ogc_fid'
        ) THEN
            ALTER TABLE public.street_parking_import RENAME COLUMN ogc_fid TO fid;
        ELSE
            RAISE EXCEPTION 'street_parking_import has no fid / ogc_fid column';
        END IF;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'id'
    ) THEN
        RAISE EXCEPTION 'street_parking_import has no id column (TILDA static id)';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'capacity_source'
    ) THEN
        ALTER TABLE public.street_parking_import ADD COLUMN capacity_source text;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'source'
    ) THEN
        ALTER TABLE public.street_parking_import ADD COLUMN source text;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'road_name'
    ) THEN
        ALTER TABLE public.street_parking_import ADD COLUMN road_name text;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'geom_sources'
    ) THEN
        ALTER TABLE public.street_parking_import ADD COLUMN geom_sources text;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'street_parking_import'
          AND column_name = 'tags'
          AND data_type = 'jsonb'
    ) THEN
        UPDATE public.street_parking_import
        SET geom_sources = tags ->> 'geom_sources'
        WHERE geom_sources IS NULL
          AND tags ? 'geom_sources';
    END IF;

    -- street_parking.py attribute aliases (GDAL often launders ':' → '_')
    PERFORM pg_temp.spc_copy_text(
        ARRAY['parking_source'],
        'source'
    );
    PERFORM pg_temp.spc_copy_text(
        ARRAY['highway:name', 'highway_name'],
        'road_name'
    );
    PERFORM pg_temp.spc_copy_text(
        ARRAY['highway:oneway', 'highway_oneway'],
        'road_oneway'
    );
    PERFORM pg_temp.spc_copy_text(
        ARRAY['source:capacity', 'source_capacity'],
        'capacity_source'
    );
    PERFORM pg_temp.spc_copy_text(
        ARRAY['osm_id'],
        'geom_sources'
    );
    UPDATE public.street_parking_import
    SET geom_sources = 'way/' || btrim(geom_sources)
    WHERE geom_sources ~ '^[0-9]+$';

    PERFORM pg_temp.spc_ensure_text_col('condition_category');
    PERFORM pg_temp.spc_ensure_text_col('condition_category_primary');
    PERFORM pg_temp.spc_ensure_text_col('vehicle_designated');
    PERFORM pg_temp.spc_ensure_text_col('direction');
    PERFORM pg_temp.spc_ensure_text_col('road_oneway');
    PERFORM pg_temp.spc_ensure_text_col('side');
    PERFORM pg_temp.spc_ensure_text_col('staggered');
    PERFORM pg_temp.spc_ensure_text_col('parking');
    PERFORM pg_temp.spc_ensure_text_col('orientation');
    PERFORM pg_temp.spc_ensure_text_col('surface');
    PERFORM pg_temp.spc_ensure_text_col('markings');
    PERFORM pg_temp.spc_ensure_text_col('location');

    IF pg_temp.spc_import_has_col('condition_class') THEN
        UPDATE public.street_parking_import
        SET condition_category = pg_temp.parking_condition_at_to_paren(condition_class::text)
        WHERE (condition_category IS NULL OR btrim(condition_category) = '')
          AND condition_class IS NOT NULL
          AND btrim(condition_class::text) <> '';
    END IF;

    UPDATE public.street_parking_import
    SET condition_category = pg_temp.parking_merge_vehicles(
        condition_category,
        vehicle_designated::text
    )
    WHERE vehicle_designated IS NOT NULL
      AND btrim(vehicle_designated::text) <> '';

    UPDATE public.street_parking_import
    SET condition_category_primary = pg_temp.parking_condition_primary(condition_category)
    WHERE condition_category_primary IS NULL
       OR btrim(condition_category_primary) = '';

    -- optional import layer (street_parking.py); highway lookup overrides below
    IF NOT pg_temp.spc_import_has_col('layer_import') THEN
        ALTER TABLE public.street_parking_import ADD COLUMN layer_import integer;
    END IF;
    IF pg_temp.spc_import_has_col('layer') THEN
        EXECUTE $u$
            UPDATE public.street_parking_import
            SET layer_import = NULLIF(btrim(layer::text), '')::integer
            WHERE layer_import IS NULL
              AND layer IS NOT NULL
              AND btrim(layer::text) ~ '^-?[0-9]+$'
        $u$;
    END IF;

    -- street_parking.py kerb lines for street_side sit at the bay back
    IF NOT pg_temp.spc_import_has_col('from_street_parking_py') THEN
        ALTER TABLE public.street_parking_import
            ADD COLUMN from_street_parking_py boolean;
    END IF;
    UPDATE public.street_parking_import
    SET from_street_parking_py = false
    WHERE from_street_parking_py IS NULL;
    IF pg_temp.spc_import_has_col('condition_class')
       OR pg_temp.spc_import_has_col('parking_source')
    THEN
        UPDATE public.street_parking_import
        SET from_street_parking_py = true;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Carriageway polygons and local outer edges (no global union).
--    Neighbour subtraction leaves ~2×edge_eps_m gaps at carriageway joints;
--    those end points are bridged (edge_bridge_m) before clustering/LineMerge.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _road_poly;
CREATE TEMP TABLE _road_poly AS
SELECT
    row_number() OVER () AS poly_id,
    dumped.geom
FROM highway_area ha
INNER JOIN _highway_road_area r
    ON r.area_highway = ha."area:highway"
CROSS JOIN LATERAL ST_Dump(ha.geom) AS dumped(path, geom)
WHERE ha.geom IS NOT NULL
  AND NOT ST_IsEmpty(ha.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_Polygon'
  AND ST_IsValid(dumped.geom);

CREATE INDEX _road_poly_geom_idx ON _road_poly USING GIST (geom);
ANALYZE _road_poly;

DROP TABLE IF EXISTS _road_edge_raw;
CREATE TEMP TABLE _road_edge_raw AS
SELECT
    row_number() OVER () AS raw_id,
    dumped.geom
FROM _road_poly p
LEFT JOIN LATERAL (
    SELECT ST_Union(ST_Buffer(n.geom, metres(:'street_parking_edge_eps_m'::double precision))) AS cover
    FROM _road_poly n
    WHERE n.poly_id <> p.poly_id
      AND n.geom && p.geom
      AND ST_Intersects(n.geom, p.geom)
) nb ON true
CROSS JOIN LATERAL ST_Dump(
    ST_CollectionExtract(
        COALESCE(
            CASE
                WHEN nb.cover IS NULL OR ST_IsEmpty(nb.cover)
                    THEN ST_Boundary(p.geom)
                ELSE ST_Difference(ST_Boundary(p.geom), nb.cover)
            END,
            ST_Boundary(p.geom)
        ),
        2
    )
) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_Length(dumped.geom) > metres(0.01);

-- Endpoints of open kerb pieces; nearest other-piece endpoint within
-- edge_bridge_m becomes a connector so LineMerge can rejoin the gaps.
DROP TABLE IF EXISTS _road_edge_ep;
CREATE TEMP TABLE _road_edge_ep AS
SELECT
    raw_id,
    ST_StartPoint(geom) AS pt
FROM _road_edge_raw
WHERE NOT ST_IsClosed(geom)
UNION ALL
SELECT
    raw_id,
    ST_EndPoint(geom) AS pt
FROM _road_edge_raw
WHERE NOT ST_IsClosed(geom);

CREATE INDEX _road_edge_ep_pt_idx ON _road_edge_ep USING GIST (pt);
ANALYZE _road_edge_ep;

DROP TABLE IF EXISTS _road_edge_bridge;
CREATE TEMP TABLE _road_edge_bridge AS
SELECT DISTINCT ON (LEAST(a.raw_id, nn.raw_id), GREATEST(a.raw_id, nn.raw_id))
    ST_MakeLine(a.pt, nn.pt) AS geom
FROM _road_edge_ep a
INNER JOIN LATERAL (
    SELECT
        b.raw_id,
        b.pt
    FROM _road_edge_ep b
    WHERE b.raw_id <> a.raw_id
      AND ST_DWithin(
          a.pt,
          b.pt,
          metres(:'street_parking_edge_bridge_m'::double precision)
      )
    ORDER BY a.pt <-> b.pt
    LIMIT 1
) nn ON true
WHERE a.raw_id < nn.raw_id
  AND NOT ST_Equals(a.pt, nn.pt)
ORDER BY LEAST(a.raw_id, nn.raw_id), GREATEST(a.raw_id, nn.raw_id);

-- Touching pieces of one kerb ring → one cluster, then LineMerge.
DROP TABLE IF EXISTS _road_edge_clustered;
CREATE TEMP TABLE _road_edge_clustered AS
SELECT
    ST_ClusterDBSCAN(geom, metres(0.01), 1) OVER () AS cluster_id,
    geom
FROM (
    SELECT geom FROM _road_edge_raw
    UNION ALL
    SELECT geom FROM _road_edge_bridge
) pieces;

DROP TABLE IF EXISTS _road_edge;
CREATE TEMP TABLE _road_edge AS
SELECT
    row_number() OVER () AS edge_id,
    dumped.geom,
    ST_IsClosed(dumped.geom) AS is_closed
FROM (
    SELECT
        ST_LineMerge(ST_Collect(geom)) AS geom
    FROM _road_edge_clustered
    GROUP BY cluster_id
) merged
CROSS JOIN LATERAL ST_Dump(merged.geom) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND ST_NPoints(dumped.geom) >= 2;

CREATE INDEX _road_edge_id_idx ON _road_edge (edge_id);
ANALYZE _road_edge;

DROP TABLE IF EXISTS _road_edge_sub;
CREATE TEMP TABLE _road_edge_sub AS
SELECT
    e.edge_id,
    dumped.geom
FROM _road_edge e
CROSS JOIN LATERAL ST_Subdivide(e.geom, 32) AS dumped(geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom);

CREATE INDEX _road_edge_sub_geom_idx ON _road_edge_sub USING GIST (geom);
ANALYZE _road_edge_sub;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.az_turn_deg(
    az_in double precision,
    az_out double precision
)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN az_in IS NULL OR az_out IS NULL THEN NULL
        ELSE degrees(
            CASE
                WHEN abs(az_out - az_in) > pi() THEN (2.0 * pi()) - abs(az_out - az_in)
                ELSE abs(az_out - az_in)
            END
        )
    END;
$$;

-- Undirected azimuth difference in degrees (0…90); inputs in degrees.
CREATE OR REPLACE FUNCTION pg_temp.undirected_az_diff(a double precision, b double precision)
RETURNS double precision
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN a IS NULL OR b IS NULL THEN NULL
        ELSE LEAST(
            mod(abs(a - b)::numeric, 180)::double precision,
            180.0 - mod(abs(a - b)::numeric, 180)::double precision
        )
    END;
$$;

-- Kerbside space per car (m). Unknown / NULL orientation → parallel.
DROP TABLE IF EXISTS _parking_orient_const;
CREATE TEMP TABLE _parking_orient_const (
    orientation text PRIMARY KEY,
    car_space_x double precision NOT NULL,
    padding double precision NOT NULL
);
INSERT INTO _parking_orient_const (orientation, car_space_x, padding) VALUES
    ('parallel', 4.4, 0.8),
    ('perpendicular', 2.0, 0.5),
    (
        'diagonal',
        (cos(radians(30.0)) * 2.0 + sin(radians(30.0)) * 4.4) * 0.66,
        cos(radians(30.0)) * 0.5
    );

-- n cars along a kerb: (length + padding) / (car_space_x + padding).
DROP FUNCTION IF EXISTS pg_temp.parking_estimate_capacity(double precision, text, text);
DROP FUNCTION IF EXISTS pg_temp.parking_estimate_capacity(double precision, text);
CREATE OR REPLACE FUNCTION pg_temp.parking_estimate_capacity(
    length_m double precision,
    orientation text
)
RETURNS double precision
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    const record;
    n_cars double precision;
    orient text;
BEGIN
    IF length_m IS NULL OR length_m <= 0 THEN
        RETURN 0;
    END IF;

    orient := COALESCE(NULLIF(orientation, ''), 'parallel');
    SELECT c.car_space_x, c.padding
      INTO const
    FROM _parking_orient_const c
    WHERE c.orientation = orient;

    IF NOT FOUND THEN
        SELECT c.car_space_x, c.padding
          INTO const
        FROM _parking_orient_const c
        WHERE c.orientation = 'parallel';
    END IF;

    n_cars := (length_m + const.padding) / (const.car_space_x + const.padding);

    RETURN GREATEST(n_cars, 0.0);
END;
$$;

DROP FUNCTION IF EXISTS pg_temp.parking_round_capacity(double precision, double precision);

-- Kerb length (m) that yields exactly n cars: n*(car_space_x+padding) - padding.
CREATE OR REPLACE FUNCTION pg_temp.parking_kerb_len_n(
    orientation text,
    n integer
)
RETURNS double precision
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    const record;
    orient text;
BEGIN
    IF n IS NULL OR n <= 0 THEN
        RETURN 0;
    END IF;

    orient := COALESCE(NULLIF(orientation, ''), 'parallel');
    SELECT c.car_space_x, c.padding
      INTO const
    FROM _parking_orient_const c
    WHERE c.orientation = orient;

    IF NOT FOUND THEN
        SELECT c.car_space_x, c.padding
          INTO const
        FROM _parking_orient_const c
        WHERE c.orientation = 'parallel';
    END IF;

    RETURN n * (const.car_space_x + const.padding) - const.padding;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_hash_mod(
    key text,
    modulo integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ((hashtext(key)::bigint % modulo) + modulo) % modulo;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_parse_way_ids(sources text)
RETURNS SETOF bigint
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT split_part(lower(btrim(x)), '/', 2)::bigint
    FROM regexp_split_to_table(COALESCE(sources, ''), ';') AS x
    WHERE lower(btrim(x)) ~ '^way/[0-9]+$';
$$;

-- [1][N1][1][N2][1]… along a highway. N is  n_min..n_max from hash(source_key/grp).
CREATE OR REPLACE FUNCTION pg_temp.parking_stagger_street_chunks(
    line geometry,
    source_key text,
    n_min integer,
    n_max integer
)
RETURNS TABLE (
    kind text,
    grp_idx integer,
    geom geometry
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    len_m double precision;
    len_1_m double precision;
    pos_m double precision := 0.0;
    grp integer := 0;
    n_cars integer;
    take_m double precision;
    span integer;
BEGIN
    IF line IS NULL OR ST_IsEmpty(line) OR ST_NPoints(line) < 2 THEN
        RETURN;
    END IF;
    IF n_min IS NULL OR n_max IS NULL OR n_min <= 0 OR n_max < n_min THEN
        RETURN;
    END IF;

    len_m := ST_Length(line) / metres(1);
    IF len_m IS NULL OR len_m <= 0 THEN
        RETURN;
    END IF;

    len_1_m := pg_temp.parking_kerb_len_n('parallel', 1);
    span := n_max - n_min + 1;

    take_m := LEAST(len_1_m, len_m - pos_m);
    IF take_m > 1e-6 THEN
        kind := 'gap';
        grp_idx := 0;
        geom := ST_LineSubstring(line, pos_m / len_m, LEAST((pos_m + take_m) / len_m, 1.0));
        IF geom IS NOT NULL
           AND NOT ST_IsEmpty(geom)
           AND ST_GeometryType(geom) = 'ST_LineString'
           AND ST_NPoints(geom) >= 2
        THEN
            RETURN NEXT;
        END IF;
    END IF;
    pos_m := pos_m + take_m;

    WHILE pos_m < len_m - 1e-9 LOOP
        n_cars := n_min + pg_temp.parking_hash_mod(
            COALESCE(source_key, '') || '/' || grp::text,
            span
        );
        take_m := LEAST(
            pg_temp.parking_kerb_len_n('parallel', n_cars),
            len_m - pos_m
        );
        IF take_m > 1e-6 THEN
            kind := 'packet';
            grp_idx := grp;
            geom := ST_LineSubstring(line, pos_m / len_m, LEAST((pos_m + take_m) / len_m, 1.0));
            IF geom IS NOT NULL
               AND NOT ST_IsEmpty(geom)
               AND ST_GeometryType(geom) = 'ST_LineString'
               AND ST_NPoints(geom) >= 2
            THEN
                RETURN NEXT;
            END IF;
        END IF;
        pos_m := pos_m + take_m;
        EXIT WHEN pos_m >= len_m - 1e-9;

        take_m := LEAST(len_1_m, len_m - pos_m);
        IF take_m > 1e-6 THEN
            kind := 'gap';
            grp_idx := grp + 1;
            geom := ST_LineSubstring(line, pos_m / len_m, LEAST((pos_m + take_m) / len_m, 1.0));
            IF geom IS NOT NULL
               AND NOT ST_IsEmpty(geom)
               AND ST_GeometryType(geom) = 'ST_LineString'
               AND ST_NPoints(geom) >= 2
            THEN
                RETURN NEXT;
            END IF;
        END IF;
        pos_m := pos_m + take_m;
        grp := grp + 1;
    END LOOP;
END;
$$;

DROP FUNCTION IF EXISTS pg_temp.parking_road_tube(geometry, boolean, double precision);
CREATE OR REPLACE FUNCTION pg_temp.parking_road_tube(
    line geometry,
    side text,
    width_m double precision
)
RETURNS geometry
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN line IS NULL OR ST_IsEmpty(line) OR width_m IS NULL OR width_m <= 0 THEN NULL
        WHEN side = 'both' THEN
            ST_MakeValid(ST_Buffer(line, metres(width_m), 'endcap=flat join=round'))
        ELSE
            ST_MakeValid(ST_Buffer(
                line,
                metres(width_m),
                CASE WHEN side = 'right'
                    THEN 'endcap=flat join=round side=right'
                    ELSE 'endcap=flat join=round side=left'
                END
            ))
    END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.parking_dump_line_parts(g geometry)
RETURNS SETOF geometry
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    d record;
    part geometry;
BEGIN
    IF g IS NULL OR ST_IsEmpty(g) THEN
        RETURN;
    END IF;
    part := ST_CollectionExtract(ST_MakeValid(g), 2);
    IF part IS NULL OR ST_IsEmpty(part) THEN
        RETURN;
    END IF;
    FOR d IN SELECT (ST_Dump(part)).geom AS geom
    LOOP
        IF d.geom IS NOT NULL
           AND NOT ST_IsEmpty(d.geom)
           AND ST_GeometryType(d.geom) = 'ST_LineString'
           AND ST_NPoints(d.geom) >= 2
           AND ST_Length(d.geom) / metres(1) > 0.5
        THEN
            RETURN NEXT d.geom;
        END IF;
    END LOOP;
END;
$$;

-- Build a snapped line from densified vertices + optional edge projections.
-- Forward along a ring (wrap if that is the shorter way); reverse hops stay
-- a straight segment between the projected points. A substring is rejected
-- when it is much longer than the chord (detour around a junction).
CREATE OR REPLACE FUNCTION pg_temp._parking_build_snapped(
    orig geometry,
    pts geometry[],
    edge_ids bigint[],
    meas double precision[],
    snap_pts geometry[],
    snap_max_m double precision
)
RETURNS geometry
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    n int;
    i int;
    k int;
    npts int;
    p1 geometry;
    p2 geometry;
    e1 bigint;
    e2 bigint;
    m1 double precision;
    m2 double precision;
    delta double precision;
    v_edge geometry;
    v_closed boolean;
    sub geometry;
    a geometry;
    b geometry;
    out_pts geometry[] := ARRAY[]::geometry[];
    used_sub boolean;
BEGIN
    n := array_length(pts, 1);
    IF n IS NULL OR n < 2 THEN
        RETURN orig;
    END IF;

    p1 := COALESCE(snap_pts[1], pts[1]);
    out_pts := array_append(out_pts, p1);

    FOR i IN 1 .. (n - 1) LOOP
        p1 := COALESCE(snap_pts[i], pts[i]);
        p2 := COALESCE(snap_pts[i + 1], pts[i + 1]);
        e1 := edge_ids[i];
        e2 := edge_ids[i + 1];
        m1 := meas[i];
        m2 := meas[i + 1];
        used_sub := false;

        IF e1 IS NOT NULL AND e2 IS NOT NULL AND e1 = e2
           AND m1 IS NOT NULL AND m2 IS NOT NULL
        THEN
            SELECT e.geom, e.is_closed
              INTO v_edge, v_closed
            FROM _road_edge e
            WHERE e.edge_id = e1;

            IF v_edge IS NOT NULL THEN
                m1 := GREATEST(0.0, LEAST(1.0, m1));
                m2 := GREATEST(0.0, LEAST(1.0, m2));
                delta := m2 - m1;
                IF v_closed THEN
                    IF delta > 0.5 THEN
                        delta := delta - 1.0;
                    ELSIF delta < -0.5 THEN
                        delta := delta + 1.0;
                    END IF;
                END IF;

                IF delta > 1e-12 THEN
                    IF m2 >= m1 THEN
                        sub := ST_LineSubstring(v_edge, m1, m2);
                    ELSE
                        a := ST_LineSubstring(v_edge, m1, 1.0);
                        b := ST_LineSubstring(v_edge, 0.0, m2);
                        IF ST_GeometryType(a) = 'ST_LineString'
                           AND ST_GeometryType(b) = 'ST_LineString'
                           AND ST_NPoints(a) >= 2
                           AND ST_NPoints(b) >= 2
                        THEN
                            sub := ST_MakeLine(a, b);
                        ELSIF ST_GeometryType(a) = 'ST_LineString' AND ST_NPoints(a) >= 2 THEN
                            sub := a;
                        ELSIF ST_GeometryType(b) = 'ST_LineString' AND ST_NPoints(b) >= 2 THEN
                            sub := b;
                        ELSE
                            sub := NULL;
                        END IF;
                    END IF;

                    IF sub IS NOT NULL AND ST_GeometryType(sub) = 'ST_MultiLineString' THEN
                        sub := ST_LineMerge(sub);
                    END IF;

                    IF sub IS NOT NULL AND ST_GeometryType(sub) = 'ST_LineString' THEN
                        npts := ST_NPoints(sub);
                        IF npts >= 2
                           AND ST_Length(sub) <= ST_Distance(p1, p2)
                               + 2.0 * metres(snap_max_m)
                               + metres(1)
                        THEN
                            FOR k IN 2 .. npts LOOP
                                out_pts := array_append(out_pts, ST_PointN(sub, k));
                            END LOOP;
                            used_sub := true;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END IF;

        IF NOT used_sub THEN
            out_pts := array_append(out_pts, p2);
        END IF;
    END LOOP;

    IF array_length(out_pts, 1) < 2 THEN
        RETURN orig;
    END IF;

    RETURN ST_RemoveRepeatedPoints(ST_MakeLine(out_pts), metres(0.01));
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp._parking_split_kinks(
    line geometry,
    angle_deg double precision
)
RETURNS TABLE (part_idx int, geom geometry)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    n int;
    i int;
    pt geometry;
    prev geometry;
    nxt geometry;
    turn double precision;
    fracs double precision[];
    f double precision;
    f_prev double precision;
    idx int := 0;
BEGIN
    IF line IS NULL OR ST_IsEmpty(line) OR ST_GeometryType(line) <> 'ST_LineString' THEN
        RETURN;
    END IF;

    n := ST_NPoints(line);
    fracs := ARRAY[0.0];

    IF n >= 3 THEN
        FOR i IN 2 .. (n - 1) LOOP
            prev := ST_PointN(line, i - 1);
            pt := ST_PointN(line, i);
            nxt := ST_PointN(line, i + 1);
            IF ST_Equals(prev, pt) OR ST_Equals(pt, nxt) THEN
                CONTINUE;
            END IF;
            turn := pg_temp.az_turn_deg(ST_Azimuth(prev, pt), ST_Azimuth(pt, nxt));
            IF turn IS NOT NULL AND turn > angle_deg THEN
                f := ST_LineLocatePoint(line, pt);
                IF f IS NOT NULL AND f > 1e-9 AND f < 1.0 - 1e-9 THEN
                    fracs := array_append(fracs, f);
                END IF;
            END IF;
        END LOOP;
    END IF;

    fracs := array_append(fracs, 1.0);

    SELECT array_agg(u.f ORDER BY u.f)
      INTO fracs
    FROM (
        SELECT DISTINCT round(x::numeric, 9)::double precision AS f
        FROM unnest(fracs) AS x
    ) u;

    f_prev := 0.0;
    FOREACH f IN ARRAY fracs LOOP
        IF f - f_prev > 1e-9 THEN
            idx := idx + 1;
            part_idx := idx;
            geom := ST_LineSubstring(line, f_prev, f);
            IF geom IS NOT NULL
               AND NOT ST_IsEmpty(geom)
               AND ST_GeometryType(geom) = 'ST_LineString'
               AND ST_NPoints(geom) >= 2
            THEN
                RETURN NEXT;
            END IF;
            f_prev := f;
        END IF;
    END LOOP;

    IF idx = 0 THEN
        part_idx := 1;
        geom := line;
        RETURN NEXT;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Source parking lines
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_src;
CREATE TEMP TABLE _parking_src AS
SELECT
    row_number() OVER () AS line_uid,
    i.id::text AS source_id,
    i.source,
    i.parking,
    i.orientation,
    i.capacity,
    i.capacity_source,
    i.condition_category_primary,
    i.condition_category,
    i.surface,
    i.markings,
    i.location,
    i.direction,
    i.road_oneway,
    i.side,
    i.staggered,
    NULLIF(btrim(i.road_name), '') AS road_name,
    NULLIF(btrim(i.geom_sources), '') AS geom_sources,
    i.layer_import AS import_layer,
    NULL::integer AS layer,
    (
        COALESCE(i.from_street_parking_py, false)
        AND i.parking = 'street_side'
    ) AS street_side_back,
    COALESCE(i.source, '') ILIKE '%separate%area%' AS from_separate_area,
    COALESCE(i.source, '') ILIKE '%separate_parking_areas%' AS tilda_separate_area,
    dumped.geom
FROM street_parking_import i
CROSS JOIN LATERAL ST_Dump(i.geom) AS dumped(path, geom)
WHERE i.geom IS NOT NULL
  AND NOT ST_IsEmpty(i.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND ST_NPoints(dumped.geom) >= 2;

CREATE INDEX _parking_src_uid_idx ON _parking_src (line_uid);
ANALYZE _parking_src;

-- layer from parent highway ways listed in geom_sources (MAX; NULL ignored)
UPDATE _parking_src s
SET layer = m.max_layer
FROM (
    SELECT
        s2.line_uid,
        MAX(hw.layer) AS max_layer
    FROM _parking_src s2
    CROSS JOIN LATERAL pg_temp.parking_parse_way_ids(s2.geom_sources) AS wid(osm_id)
    INNER JOIN highway hw ON hw.osm_id = wid.osm_id
    WHERE hw.layer IS NOT NULL
    GROUP BY s2.line_uid
) m
WHERE s.line_uid = m.line_uid;

-- ---------------------------------------------------------------------------
-- 3) Proximity test (fixed sample points, not original vertices)
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_tests;
CREATE TEMP TABLE _parking_tests AS
SELECT
    s.line_uid,
    n.n AS n_tests,
    gs.i,
    ST_LineInterpolatePoint(s.geom, gs.i::double precision / (n.n - 1)) AS pt
FROM _parking_src s
CROSS JOIN LATERAL (
    SELECT GREATEST(
        :'street_parking_test_min_points'::int,
        CEIL(ST_Length(s.geom) / metres(:'street_parking_test_spacing_m'::double precision))::int + 1
    ) AS n
) n
CROSS JOIN LATERAL generate_series(0, n.n - 1) AS gs(i)
WHERE NOT s.from_separate_area;

DROP TABLE IF EXISTS _parking_coverage;
CREATE TEMP TABLE _parking_coverage AS
SELECT
    t.line_uid,
    t.n_tests,
    COUNT(*) FILTER (
        WHERE EXISTS (
            SELECT 1
            FROM _road_edge_sub e
            WHERE ST_DWithin(
                t.pt,
                e.geom,
                metres(:'street_parking_snap_max_m'::double precision)
            )
        )
    ) AS n_near
FROM _parking_tests t
GROUP BY t.line_uid, t.n_tests;

CREATE INDEX _parking_coverage_uid_idx ON _parking_coverage (line_uid);

DROP TABLE IF EXISTS _parking_to_snap;
CREATE TEMP TABLE _parking_to_snap AS
SELECT s.*
FROM _parking_src s
INNER JOIN _parking_coverage c ON c.line_uid = s.line_uid
WHERE NOT s.from_separate_area
  AND c.n_near >= CEIL(
    :'street_parking_snap_min_coverage'::double precision * c.n_tests
);

CREATE INDEX _parking_to_snap_uid_idx ON _parking_to_snap (line_uid);

-- ---------------------------------------------------------------------------
-- 4) Snap candidates onto carriageway edges
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _snap_pts;
CREATE TEMP TABLE _snap_pts AS
SELECT
    s.line_uid,
    dp.path[1] AS ord,
    dp.geom AS pt
FROM _parking_to_snap s
CROSS JOIN LATERAL ST_DumpPoints(
    ST_Segmentize(s.geom, metres(:'street_parking_sample_m'::double precision))
) AS dp(path, geom);

CREATE INDEX _snap_pts_pt_idx ON _snap_pts USING GIST (pt);
ANALYZE _snap_pts;

DROP TABLE IF EXISTS _snap_nn;
CREATE TEMP TABLE _snap_nn AS
SELECT
    p.line_uid,
    p.ord,
    p.pt,
    nn.edge_id,
    CASE
        WHEN e.geom IS NULL THEN NULL
        ELSE ST_LineLocatePoint(e.geom, p.pt)
    END AS meas,
    CASE
        WHEN e.geom IS NULL THEN NULL
        ELSE ST_ClosestPoint(e.geom, p.pt)
    END AS snap_pt
FROM _snap_pts p
LEFT JOIN LATERAL (
    SELECT s.edge_id
    FROM _road_edge_sub s
    WHERE ST_DWithin(
        p.pt,
        s.geom,
        metres(:'street_parking_snap_max_m'::double precision)
    )
    ORDER BY p.pt <-> s.geom
    LIMIT 1
) nn ON true
LEFT JOIN _road_edge e ON e.edge_id = nn.edge_id;

CREATE INDEX _snap_nn_uid_idx ON _snap_nn (line_uid, ord);

DROP TABLE IF EXISTS _parking_snapped;
CREATE TEMP TABLE _parking_snapped AS
SELECT
    s.line_uid,
    s.source_id,
    s.parking,
    s.orientation,
    s.capacity,
    s.capacity_source,
    s.condition_category_primary,
    s.surface,
    s.markings,
    s.location,
    s.direction,
    s.road_oneway,
    s.staggered,
    COALESCE(
        ST_SimplifyPreserveTopology(
            built.geom,
            metres(:'street_parking_simplify_m'::double precision)
        ),
        built.geom,
        s.geom
    ) AS geom
FROM _parking_to_snap s
INNER JOIN LATERAL (
    SELECT pg_temp._parking_build_snapped(
        s.geom,
        array_agg(n.pt ORDER BY n.ord),
        array_agg(n.edge_id ORDER BY n.ord),
        array_agg(n.meas ORDER BY n.ord),
        array_agg(n.snap_pt ORDER BY n.ord),
        :'street_parking_snap_max_m'::double precision
    ) AS geom
    FROM _snap_nn n
    WHERE n.line_uid = s.line_uid
) built ON true;

-- Keep only usable LineStrings; otherwise fall back to the original line.
UPDATE _parking_snapped s
SET geom = src.geom
FROM _parking_to_snap src
WHERE s.line_uid = src.line_uid
  AND (
        s.geom IS NULL
     OR ST_IsEmpty(s.geom)
     OR ST_GeometryType(s.geom) <> 'ST_LineString'
     OR ST_NPoints(s.geom) < 2
  );

-- Unsnapped lines (separate areas, coverage too low, or not in _parking_to_snap).
DROP TABLE IF EXISTS _parking_kept;
CREATE TEMP TABLE _parking_kept AS
SELECT
    s.line_uid,
    s.source_id,
    s.parking,
    s.orientation,
    s.capacity,
    s.capacity_source,
    s.condition_category_primary,
    s.surface,
    s.markings,
    s.location,
    s.direction,
    s.road_oneway,
    s.staggered,
    s.geom,
    false AS snapped
FROM _parking_src s
WHERE NOT EXISTS (
    SELECT 1 FROM _parking_to_snap t WHERE t.line_uid = s.line_uid
);

DROP TABLE IF EXISTS _parking_geom;
CREATE TEMP TABLE _parking_geom AS
SELECT
    line_uid,
    source_id,
    parking,
    orientation,
    capacity,
    capacity_source,
    condition_category_primary,
    surface,
    markings,
    location,
    direction,
    road_oneway,
    staggered,
    geom,
    true AS snapped
FROM _parking_snapped
UNION ALL
SELECT
    line_uid,
    source_id,
    parking,
    orientation,
    capacity,
    capacity_source,
    condition_category_primary,
    surface,
    markings,
    location,
    direction,
    road_oneway,
    staggered,
    geom,
    snapped
FROM _parking_kept;

-- ---------------------------------------------------------------------------
-- 5) Split snapped lines at kinks; keep unsnapped lines whole
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_parts;
CREATE TEMP TABLE _parking_parts AS
SELECT
    g.line_uid,
    g.source_id,
    g.parking,
    g.orientation,
    g.capacity AS capacity_orig,
    g.capacity_source,
    g.condition_category_primary,
    g.surface,
    g.markings,
    g.location,
    g.direction,
    g.road_oneway,
    g.staggered,
    g.snapped,
    sp.part_idx,
    sp.geom,
    ST_Length(sp.geom) AS len,
    ST_Length(sp.geom) / metres(1) AS len_m
FROM _parking_geom g
CROSS JOIN LATERAL pg_temp._parking_split_kinks(
    g.geom,
    :'street_parking_split_angle_deg'::double precision
) AS sp(part_idx, geom)
WHERE g.snapped
  AND sp.geom IS NOT NULL
  AND NOT ST_IsEmpty(sp.geom)
UNION ALL
SELECT
    g.line_uid,
    g.source_id,
    g.parking,
    g.orientation,
    g.capacity,
    g.capacity_source,
    g.condition_category_primary,
    g.surface,
    g.markings,
    g.location,
    g.direction,
    g.road_oneway,
    g.staggered,
    g.snapped,
    1 AS part_idx,
    g.geom,
    ST_Length(g.geom) AS len,
    ST_Length(g.geom) / metres(1) AS len_m
FROM _parking_geom g
WHERE NOT g.snapped;

-- ---------------------------------------------------------------------------
-- 6) Parallel filter per segment
--    Each segment is compared with the original (unsnapped) line at the point
--    nearest to the segment midpoint. Undirected deviation above
--    parallel_max_deg → segment dropped.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_segs;
CREATE TEMP TABLE _parking_segs AS
WITH segs AS (
    SELECT
        p.line_uid,
        p.part_idx,
        ds.path[1] AS seg_idx,
        ds.geom AS seg
    FROM _parking_parts p
    CROSS JOIN LATERAL ST_DumpSegments(p.geom) AS ds(path, geom)
),
tested AS (
    SELECT
        s.*,
        ST_LineLocatePoint(o.geom, ST_LineInterpolatePoint(s.seg, 0.5)) AS f,
        o.geom AS orig_geom,
        ST_Length(o.geom) AS orig_len
    FROM segs s
    INNER JOIN _parking_src o ON o.line_uid = s.line_uid
),
az AS (
    SELECT
        t.line_uid,
        t.part_idx,
        t.seg_idx,
        t.seg,
        t.f,
        degrees(ST_Azimuth(ST_StartPoint(t.seg), ST_EndPoint(t.seg))) AS az_seg,
        CASE
            WHEN t.orig_len <= 0 THEN NULL
            ELSE degrees(ST_Azimuth(
                ST_LineInterpolatePoint(
                    t.orig_geom,
                    GREATEST(
                        0.0,
                        t.f - metres(:'street_parking_parallel_az_window_m'::double precision)
                              / t.orig_len
                    )
                ),
                ST_LineInterpolatePoint(
                    t.orig_geom,
                    LEAST(
                        1.0,
                        t.f + metres(:'street_parking_parallel_az_window_m'::double precision)
                              / t.orig_len
                    )
                )
            ))
        END AS az_orig
    FROM tested t
)
SELECT
    line_uid,
    part_idx,
    seg_idx,
    seg,
    CASE
        WHEN az_seg IS NULL OR az_orig IS NULL THEN true
        ELSE pg_temp.undirected_az_diff(az_seg, az_orig)
             <= :'street_parking_parallel_max_deg'::double precision
    END AS keep
FROM az;

CREATE INDEX _parking_segs_idx ON _parking_segs (line_uid, part_idx, seg_idx);

-- Rejoin consecutive kept segments (gaps-and-islands per part).
DROP TABLE IF EXISTS _parking_pieces;
CREATE TEMP TABLE _parking_pieces AS
WITH grouped AS (
    SELECT
        s.*,
        SUM(CASE WHEN s.keep THEN 0 ELSE 1 END) OVER (
            PARTITION BY s.line_uid, s.part_idx
            ORDER BY s.seg_idx
        ) AS grp
    FROM _parking_segs s
),
joined AS (
    SELECT
        line_uid,
        part_idx,
        grp,
        ST_RemoveRepeatedPoints(ST_MakeLine(array_agg(seg ORDER BY seg_idx))) AS geom
    FROM grouped
    WHERE keep
    GROUP BY line_uid, part_idx, grp
)
SELECT
    j.line_uid,
    row_number() OVER (PARTITION BY j.line_uid ORDER BY j.part_idx, j.grp) AS piece_idx,
    j.geom,
    ST_Length(j.geom) / metres(1) AS len_m
FROM joined j
WHERE j.geom IS NOT NULL
  AND NOT ST_IsEmpty(j.geom)
  AND ST_GeometryType(j.geom) = 'ST_LineString'
  AND ST_NPoints(j.geom) >= 2;

-- ---------------------------------------------------------------------------
-- 7) road_left + road_name, then staggered tubes along parent highways
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS _parking_piece_attr;
CREATE TEMP TABLE _parking_piece_attr AS
SELECT
    pc.line_uid,
    pc.piece_idx,
    pc.geom,
    pc.len_m,
    src.source_id,
    src.orientation,
    src.side,
    src.staggered,
    src.road_name,
    src.geom_sources,
    src.import_layer,
    src.layer,
    NULL::boolean AS road_left
FROM _parking_pieces pc
INNER JOIN _parking_src src ON src.line_uid = pc.line_uid;

CREATE INDEX _parking_piece_attr_geom_idx ON _parking_piece_attr USING GIST (geom);

-- Parent OSM way from geom_sources (no class / parallel filter).
UPDATE _parking_piece_attr c
SET
    road_left = ori.road_left,
    road_name = COALESCE(c.road_name, NULLIF(btrim(ori.hw_name), ''))
FROM (
    SELECT
        p.line_uid,
        p.piece_idx,
        (
            sin(p.az) * (ST_Y(h.hp) - ST_Y(p.mid))
            - cos(p.az) * (ST_X(h.hp) - ST_X(p.mid))
        ) > 0 AS road_left,
        h.hw_name
    FROM (
        SELECT
            cap.line_uid,
            cap.piece_idx,
            cap.geom,
            cap.geom_sources,
            mid.pt AS mid,
            az.az
        FROM _parking_piece_attr cap
        CROSS JOIN LATERAL (
            SELECT ST_LineInterpolatePoint(cap.geom, 0.5) AS pt
        ) mid
        CROSS JOIN LATERAL (
            SELECT ST_Azimuth(
                ST_LineInterpolatePoint(cap.geom, GREATEST(0.0, 0.5 - 0.01)),
                ST_LineInterpolatePoint(cap.geom, LEAST(1.0, 0.5 + 0.01))
            ) AS az
        ) az
        WHERE cap.geom IS NOT NULL
          AND ST_NPoints(cap.geom) >= 2
          AND az.az IS NOT NULL
          AND cap.geom_sources IS NOT NULL
    ) p
    INNER JOIN LATERAL (
        SELECT
            ST_ClosestPoint(hw.geom, p.mid) AS hp,
            hw.name AS hw_name
        FROM highway hw
        INNER JOIN LATERAL pg_temp.parking_parse_way_ids(p.geom_sources) AS wid(osm_id)
            ON hw.osm_id = wid.osm_id
        WHERE hw.geom IS NOT NULL
          AND NOT ST_IsEmpty(hw.geom)
        ORDER BY hw.geom <-> p.mid
        LIMIT 1
    ) h ON true
) ori
WHERE c.line_uid = ori.line_uid
  AND c.piece_idx = ori.piece_idx;

-- Fallback: nearest parallel road, including highway=construction with a road class.
UPDATE _parking_piece_attr c
SET
    road_left = ori.road_left,
    road_name = COALESCE(c.road_name, NULLIF(btrim(ori.hw_name), ''))
FROM (
    SELECT
        p.line_uid,
        p.piece_idx,
        (
            sin(p.az) * (ST_Y(h.hp) - ST_Y(p.mid))
            - cos(p.az) * (ST_X(h.hp) - ST_X(p.mid))
        ) > 0 AS road_left,
        h.hw_name
    FROM (
        SELECT
            cap.line_uid,
            cap.piece_idx,
            cap.geom,
            mid.pt AS mid,
            az.az
        FROM _parking_piece_attr cap
        CROSS JOIN LATERAL (
            SELECT ST_LineInterpolatePoint(cap.geom, 0.5) AS pt
        ) mid
        CROSS JOIN LATERAL (
            SELECT ST_Azimuth(
                ST_LineInterpolatePoint(cap.geom, GREATEST(0.0, 0.5 - 0.01)),
                ST_LineInterpolatePoint(cap.geom, LEAST(1.0, 0.5 + 0.01))
            ) AS az
        ) az
        WHERE cap.road_left IS NULL
          AND cap.geom IS NOT NULL
          AND ST_NPoints(cap.geom) >= 2
          AND az.az IS NOT NULL
    ) p
    INNER JOIN LATERAL (
        SELECT
            ST_ClosestPoint(hw.geom, p.mid) AS hp,
            hw.name AS hw_name
        FROM highway hw
        INNER JOIN _highway_road_area r
            ON r.area_highway = CASE
                WHEN hw.highway = 'construction' THEN hw.construction
                ELSE hw.highway
            END
        WHERE hw.geom IS NOT NULL
          AND ST_DWithin(hw.geom, p.geom, metres(:'street_parking_layer_search_m'::double precision))
          AND degrees(acos(LEAST(
              1.0,
              abs(cos(
                  p.az - ST_Azimuth(
                      ST_LineInterpolatePoint(
                          hw.geom,
                          GREATEST(
                              0.0,
                              ST_LineLocatePoint(hw.geom, p.mid) - 0.01
                          )
                      ),
                      ST_LineInterpolatePoint(
                          hw.geom,
                          LEAST(
                              1.0,
                              ST_LineLocatePoint(hw.geom, p.mid) + 0.01
                          )
                      )
                  )
              ))
          ))) < :'street_parking_parallel_max_deg'::double precision
        ORDER BY hw.geom <-> p.geom
        LIMIT 1
    ) h ON true
) ori
WHERE c.line_uid = ori.line_uid
  AND c.piece_idx = ori.piece_idx
  AND c.road_left IS NULL;

UPDATE _parking_piece_attr
SET road_left = true
WHERE road_left IS NULL;

-- layer: nearest highway in search radius when geom_sources had no match
UPDATE _parking_piece_attr c
SET layer = h.hw_layer
FROM (
    SELECT
        p.line_uid,
        p.piece_idx,
        hw.hw_layer
    FROM _parking_piece_attr p
    INNER JOIN LATERAL (
        SELECT hw.layer AS hw_layer
        FROM highway hw
        INNER JOIN _highway_road_area r
            ON r.area_highway = CASE
                WHEN hw.highway = 'construction' THEN hw.construction
                ELSE hw.highway
            END
        WHERE p.layer IS NULL
          AND hw.geom IS NOT NULL
          AND ST_DWithin(
              hw.geom,
              p.geom,
              metres(:'street_parking_layer_search_m'::double precision)
          )
        ORDER BY hw.geom <-> p.geom
        LIMIT 1
    ) hw ON true
    WHERE p.layer IS NULL
) h
WHERE c.line_uid = h.line_uid
  AND c.piece_idx = h.piece_idx;

-- last resort: layer exported by street_parking.py
UPDATE _parking_piece_attr
SET layer = import_layer
WHERE layer IS NULL
  AND import_layer IS NOT NULL;

DROP TABLE IF EXISTS _stagger_way_id;
CREATE TEMP TABLE _stagger_way_id AS
SELECT DISTINCT pg_temp.parking_parse_way_ids(a.geom_sources) AS osm_id
FROM _parking_piece_attr a
WHERE a.staggered = 'yes'
  AND a.geom_sources IS NOT NULL;

DROP TABLE IF EXISTS _stagger_hw_seg;
CREATE TEMP TABLE _stagger_hw_seg AS
SELECT
    row_number() OVER () AS seg_id,
    hw.osm_id,
    COALESCE(NULLIF(btrim(hw.name), ''), '') AS name_key,
    dumped.geom
FROM highway hw
INNER JOIN _stagger_way_id w ON w.osm_id = hw.osm_id
CROSS JOIN LATERAL ST_Dump(hw.geom) AS dumped(path, geom)
WHERE hw.geom IS NOT NULL
  AND NOT ST_IsEmpty(hw.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND ST_NPoints(dumped.geom) >= 2;

DROP TABLE IF EXISTS _stagger_cluster;
CREATE TEMP TABLE _stagger_cluster AS
SELECT
    row_number() OVER () AS cluster_id,
    c.name_key,
    CASE
        WHEN c.name_key <> '' THEN c.name_key
        ELSE (
            SELECT string_agg(h.osm_id::text, ',' ORDER BY h.osm_id)
            FROM _stagger_hw_seg h
            WHERE h.name_key = ''
              AND ST_Intersects(h.geom, c.clust)
        )
    END AS source_key,
    c.clust AS geom
FROM (
    SELECT
        s.name_key,
        unnest(ST_ClusterIntersecting(s.geom)) AS clust
    FROM _stagger_hw_seg s
    GROUP BY s.name_key
) c;

DROP TABLE IF EXISTS _stagger_hw_seg_cluster;
CREATE TEMP TABLE _stagger_hw_seg_cluster AS
SELECT
    h.seg_id,
    h.osm_id,
    cl.cluster_id
FROM _stagger_hw_seg h
INNER JOIN _stagger_cluster cl
    ON cl.name_key = h.name_key
   AND ST_Intersects(h.geom, cl.geom);

DROP TABLE IF EXISTS _stagger_street;
CREATE TEMP TABLE _stagger_street AS
SELECT
    row_number() OVER () AS street_id,
    cl.cluster_id,
    cl.source_key,
    (pg_temp.parking_hash_mod(COALESCE(cl.source_key, ''), 2)) AS phase,
    dumped.geom
FROM _stagger_cluster cl
CROSS JOIN LATERAL ST_Dump(
    ST_LineMerge(ST_CollectionExtract(ST_MakeValid(cl.geom), 2))
) AS dumped(path, geom)
WHERE dumped.geom IS NOT NULL
  AND NOT ST_IsEmpty(dumped.geom)
  AND ST_GeometryType(dumped.geom) = 'ST_LineString'
  AND ST_NPoints(dumped.geom) >= 2;

CREATE INDEX _stagger_street_geom_idx ON _stagger_street USING GIST (geom);
CREATE INDEX _stagger_street_cluster_idx ON _stagger_street (cluster_id);

DROP TABLE IF EXISTS _stagger_clip;
CREATE TEMP TABLE _stagger_clip AS
SELECT
    s.cluster_id,
    ST_UnaryUnion(ST_Collect(x.tube) FILTER (WHERE side.clip_side IN ('left', 'both'))) AS clip_left,
    ST_UnaryUnion(ST_Collect(x.tube) FILTER (WHERE side.clip_side IN ('right', 'both'))) AS clip_right
FROM _stagger_street s
CROSS JOIN LATERAL pg_temp.parking_stagger_street_chunks(
    s.geom,
    s.source_key,
    :'street_parking_staggered_group_n_min'::integer,
    :'street_parking_staggered_group_n_max'::integer
) c
CROSS JOIN LATERAL (
    SELECT
        CASE
            WHEN c.kind = 'gap' THEN 'both'
            WHEN (c.grp_idx % 2) = s.phase THEN 'left'
            ELSE 'right'
        END AS clip_side
) side
CROSS JOIN LATERAL (
    SELECT pg_temp.parking_road_tube(
        c.geom,
        side.clip_side,
        :'street_parking_staggered_tube_m'::double precision
    ) AS tube
) x
WHERE x.tube IS NOT NULL
  AND NOT ST_IsEmpty(x.tube)
GROUP BY s.cluster_id;

CREATE INDEX _stagger_clip_cluster_idx ON _stagger_clip (cluster_id);

DROP TABLE IF EXISTS _stagger_piece_cluster;
CREATE TEMP TABLE _stagger_piece_cluster AS
SELECT
    p.line_uid,
    p.piece_idx,
    (
        array_agg(p.cluster_id ORDER BY p.n DESC, p.cluster_id)
    )[1] AS cluster_id
FROM (
    SELECT
        a.line_uid,
        a.piece_idx,
        hc.cluster_id,
        count(*) AS n
    FROM _parking_piece_attr a
    CROSS JOIN LATERAL pg_temp.parking_parse_way_ids(a.geom_sources) AS wid(osm_id)
    INNER JOIN _stagger_hw_seg_cluster hc ON hc.osm_id = wid.osm_id
    WHERE a.staggered = 'yes'
    GROUP BY a.line_uid, a.piece_idx, hc.cluster_id
) p
GROUP BY p.line_uid, p.piece_idx;

DROP TABLE IF EXISTS _parking_final;
CREATE TEMP TABLE _parking_final AS
WITH parts AS (
    SELECT
        a.line_uid,
        a.geom,
        a.road_left,
        a.road_name,
        a.layer
    FROM _parking_piece_attr a
    WHERE a.staggered IS DISTINCT FROM 'yes'

    UNION ALL

    SELECT
        a.line_uid,
        d.geom,
        a.road_left,
        a.road_name,
        a.layer
    FROM _parking_piece_attr a
    LEFT JOIN _stagger_piece_cluster pc
        ON pc.line_uid = a.line_uid
       AND pc.piece_idx = a.piece_idx
    LEFT JOIN _stagger_clip cl
        ON cl.cluster_id = pc.cluster_id
    LEFT JOIN LATERAL (
        SELECT
            (
                sin(az.az) * (ST_Y(mid.pt) - ST_Y(hp.pt))
                - cos(az.az) * (ST_X(mid.pt) - ST_X(hp.pt))
            ) > 0 AS on_left
        FROM _stagger_street st
        CROSS JOIN LATERAL (
            SELECT ST_LineInterpolatePoint(a.geom, 0.5) AS pt
        ) mid
        CROSS JOIN LATERAL (
            SELECT ST_ClosestPoint(st.geom, mid.pt) AS pt
        ) hp
        CROSS JOIN LATERAL (
            SELECT ST_Azimuth(
                ST_LineInterpolatePoint(
                    st.geom,
                    GREATEST(0.0, ST_LineLocatePoint(st.geom, mid.pt) - 0.01)
                ),
                ST_LineInterpolatePoint(
                    st.geom,
                    LEAST(1.0, ST_LineLocatePoint(st.geom, mid.pt) + 0.01)
                )
            ) AS az
        ) az
        WHERE st.cluster_id = pc.cluster_id
        ORDER BY st.geom <-> a.geom
        LIMIT 1
    ) side ON true
    CROSS JOIN LATERAL pg_temp.parking_dump_line_parts(
        CASE
            WHEN cl.cluster_id IS NULL THEN a.geom
            WHEN side.on_left AND cl.clip_left IS NOT NULL
                THEN ST_Difference(a.geom, cl.clip_left)
            WHEN (NOT side.on_left) AND cl.clip_right IS NOT NULL
                THEN ST_Difference(a.geom, cl.clip_right)
            ELSE a.geom
        END
    ) AS d(geom)
    WHERE a.staggered = 'yes'
)
SELECT
    line_uid,
    row_number() OVER (
        PARTITION BY line_uid
        ORDER BY ST_X(ST_Centroid(geom)), ST_Y(ST_Centroid(geom))
    ) AS piece_idx,
    geom,
    ST_Length(geom) / metres(1) AS len_m,
    road_left,
    road_name,
    layer
FROM parts
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
  AND ST_NPoints(geom) >= 2;

DROP TABLE IF EXISTS _parking_cap;
CREATE TEMP TABLE _parking_cap AS
SELECT
    pc.line_uid,
    src.source_id,
    src.source,
    src.parking,
    src.orientation,
    FLOOR(pg_temp.parking_estimate_capacity(pc.len_m, src.orientation))::integer AS capacity,
    src.condition_category_primary,
    src.condition_category,
    src.surface,
    src.markings,
    src.location,
    src.direction,
    src.road_oneway,
    src.side,
    src.staggered,
    pc.piece_idx,
    pc.geom,
    COALESCE(pc.road_left, true) AS road_left,
    pc.layer,
    src.street_side_back,
    src.tilda_separate_area
FROM _parking_final pc
INNER JOIN _parking_src src ON src.line_uid = pc.line_uid;

DROP TABLE IF EXISTS _parking_cap_stats;
CREATE TEMP TABLE _parking_cap_stats AS
SELECT
    count(*) AS n_pieces,
    count(*) FILTER (
        WHERE capacity < 1
           OR (
                COALESCE(orientation, '') IN ('diagonal', 'perpendicular')
                AND capacity < 2
                AND COALESCE(source, '') NOT ILIKE '%separate%'
           )
    ) AS n_dropped_capacity
FROM _parking_cap;

DELETE FROM _parking_cap
WHERE capacity < 1
   OR (
        COALESCE(orientation, '') IN ('diagonal', 'perpendicular')
        AND capacity < 2
        AND COALESCE(source, '') NOT ILIKE '%separate%'
     );

-- ---------------------------------------------------------------------------
-- 8) Output table
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS street_parking;
CREATE TABLE street_parking (
    source_id text,
    source text,
    parking text,
    orientation text,
    capacity integer,
    condition_category_primary text,
    condition_category text,
    surface text,
    markings text,
    location text,
    direction text,
    road_oneway text,
    side text,
    staggered text,
    road_left boolean,
    layer integer,
    street_side_back boolean,
    tilda_separate_area boolean,
    geom geometry
);

INSERT INTO street_parking (
    source_id,
    source,
    parking,
    orientation,
    capacity,
    condition_category_primary,
    condition_category,
    surface,
    markings,
    location,
    direction,
    road_oneway,
    side,
    staggered,
    road_left,
    layer,
    street_side_back,
    tilda_separate_area,
    geom
)
SELECT
    source_id,
    source,
    parking,
    orientation,
    capacity,
    condition_category_primary,
    condition_category,
    surface,
    markings,
    location,
    direction,
    road_oneway,
    side,
    staggered,
    road_left,
    layer,
    street_side_back,
    tilda_separate_area,
    geom
FROM _parking_cap
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_GeometryType(geom) = 'ST_LineString'
  AND ST_NPoints(geom) >= 2;

CREATE INDEX street_parking_geom_idx ON street_parking USING GIST (geom);

-- TILDA road_oneway is often empty; diagonal heading uses oneway + side=left → 126°.
WITH nearest AS (
    SELECT
        sp.ctid AS sp_ctid,
        h.oneway
    FROM street_parking sp
    CROSS JOIN LATERAL (
        SELECT hw.oneway
        FROM highway hw
        WHERE hw.geom IS NOT NULL
          AND ST_DWithin(hw.geom, sp.geom, metres(:'street_parking_layer_search_m'::double precision))
        ORDER BY hw.geom <-> sp.geom
        LIMIT 1
    ) h
    WHERE sp.road_oneway IS NULL
       OR btrim(sp.road_oneway) = ''
)
UPDATE street_parking sp
SET road_oneway = 'yes'
FROM nearest n
WHERE sp.ctid = n.sp_ctid
  AND n.oneway IN ('yes', '1', 'true', '-1');

-- ---------------------------------------------------------------------------
-- 9) Log statistics (not stored on the render table)
-- ---------------------------------------------------------------------------

\echo
\echo '=== street_parking ==='
SELECT
    (SELECT count(*) FROM _parking_src) AS source_lines,
    (SELECT count(*) FROM _parking_src WHERE from_separate_area) AS separate_area_lines,
    (SELECT count(*) FROM _parking_to_snap) AS snap_candidates,
    (SELECT count(*) FROM _parking_geom WHERE snapped) AS snapped_lines,
    (SELECT count(*) FROM _parking_geom WHERE NOT snapped) AS unchanged_lines,
    (SELECT count(*) FROM street_parking) AS output_lines,
    (
        SELECT count(*)
        FROM _parking_geom g
        WHERE g.snapped
          AND (
              SELECT count(*) FROM _parking_parts p WHERE p.line_uid = g.line_uid
          ) > 1
    ) AS lines_split;
\echo
\echo 'parallel filter / capacity / staggered:'
SELECT
    (SELECT count(*) FROM _parking_segs WHERE NOT keep) AS dropped_segments,
    (SELECT n_dropped_capacity FROM _parking_cap_stats) AS dropped_capacity,
    (SELECT count(*) FROM _stagger_street) AS staggered_street_lines,
    (SELECT count(*) FROM _stagger_piece_cluster) AS staggered_clipped_pieces;
\echo
