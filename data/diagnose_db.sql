-- Diagnose why a metatile's render cost grows with the whole database.
--
-- For every rendered table: row count, size, GIST index, dead tuples,
-- last ANALYZE, and the max / 99th percentile of ST_NPoints(geom).
-- Then EXPLAIN (ANALYZE, BUFFERS) of the provider-style bbox query
-- (geom && envelope [AND "layer" = 0]) for one z18 metatile.
--
-- Usage (defaults are the z18 4×4 metatile at the centre of the small
-- reference bbox 13.439498,52.472155,13.449776,52.475932, gutter included):
--
--   psql -h localhost -p 5433 -U postgres -d strassenraumkarte \
--        -v ON_ERROR_STOP=1 -f data/diagnose_db.sql
--
-- Override the envelope (EPSG:3857), as printed by render/profile_metatile.py:
--
--   psql ... -v minx=1496178.392 -v miny=6885906.130 \
--            -v maxx=1497095.636 -v maxy=6886823.374 \
--            -f data/diagnose_db.sql
--
-- During a profile run, log slow statements from new sessions:
--   ALTER DATABASE strassenraumkarte SET log_min_duration_statement = '200ms';
--   -- restore afterwards:
--   ALTER DATABASE strassenraumkarte RESET log_min_duration_statement;
-- render/profile_metatile.py --log-slow-sql 200 does this and restores it.

\if :{?minx}
\else
\set minx 1496178.392
\set miny 6885906.130
\set maxx 1497095.636
\set maxy 6886823.374
\endif

\echo '--- envelope (EPSG:3857) ---'
SELECT :minx::float8 AS minx, :miny::float8 AS miny,
       :maxx::float8 AS maxx, :maxy::float8 AS maxy;

CREATE TEMP TABLE diagnose_envelope AS
SELECT :minx::float8 AS minx, :miny::float8 AS miny,
       :maxx::float8 AS maxx, :maxy::float8 AS maxy;

CREATE TEMP TABLE diagnose_render_tables (table_name text PRIMARY KEY);
INSERT INTO diagnose_render_tables (table_name) VALUES
    ('highway_area'),
    ('feature_polygon'),
    ('feature_way'),
    ('highway'),
    ('railway_way'),
    ('feature_node'),
    ('landuse'),
    ('playground_polygon'),
    ('barrier_node'),
    ('barrier_polygon'),
    ('barrier_way'),
    ('bridge'),
    ('bridge_shade'),
    ('highway_service'),
    ('playground_node'),
    ('playground_way'),
    ('railway_node'),
    ('road_marking_node'),
    ('road_marking_polygon'),
    ('road_marking_way'),
    ('separation'),
    ('tactile_paving'),
    ('tree'),
    ('water_body_dissolved'),
    ('pitch'),
    ('water_body'),
    ('building_lines'),
    ('building_parts_dissolved_height'),
    ('building_shade'),
    ('housenumber'),
    ('label_highway'),
    ('label_waterway'),
    ('landscape_node'),
    ('landscape_way'),
    ('pitch_markings'),
    ('place_node'),
    ('place_polygon'),
    ('building'),
    ('waterway_clipped');

CREATE TEMP TABLE diagnose_geom_stats (
    table_name text,
    row_count bigint,
    total_bytes bigint,
    has_gist boolean,
    n_dead_tup bigint,
    last_analyze timestamptz,
    max_points bigint,
    p99_points double precision
);

DO $$
DECLARE
    r record;
    geomcol text;
    has_gist boolean;
BEGIN
    FOR r IN
        SELECT t.table_name
        FROM diagnose_render_tables t
        JOIN pg_class c ON c.relname = t.table_name
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE c.relkind = 'r'
        ORDER BY t.table_name
    LOOP
        SELECT a.attname INTO geomcol
        FROM pg_attribute a
        JOIN pg_type ty ON ty.oid = a.atttypid
        WHERE a.attrelid = format('public.%I', r.table_name)::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND ty.typname = 'geometry'
        ORDER BY (a.attname = 'geom') DESC, a.attnum
        LIMIT 1;

        IF geomcol IS NULL THEN
            RAISE NOTICE 'skip % (no geometry column)', r.table_name;
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_am am ON am.oid = ic.relam AND am.amname = 'gist'
            JOIN pg_attribute a
              ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
            WHERE i.indrelid = format('public.%I', r.table_name)::regclass
              AND a.attname = geomcol
        ) INTO has_gist;

        RAISE NOTICE 'scanning %', r.table_name;
        EXECUTE format(
            $q$
            INSERT INTO diagnose_geom_stats (
                table_name, row_count, total_bytes, has_gist,
                n_dead_tup, last_analyze, max_points, p99_points
            )
            SELECT
                %L,
                stats.n,
                pg_total_relation_size(%L::regclass),
                %L::boolean,
                COALESCE(s.n_dead_tup, 0),
                s.last_analyze,
                stats.max_points,
                stats.p99_points
            FROM (
                SELECT
                    count(*) AS n,
                    max(ST_NPoints(%I)) AS max_points,
                    percentile_cont(0.99) WITHIN GROUP (ORDER BY ST_NPoints(%I)) AS p99_points
                FROM public.%I
            ) stats
            LEFT JOIN pg_stat_user_tables s
              ON s.schemaname = 'public' AND s.relname = %L
            $q$,
            r.table_name,
            format('public.%I', r.table_name),
            has_gist,
            geomcol,
            geomcol,
            r.table_name,
            r.table_name
        );
    END LOOP;
END $$;

\echo '--- rendered tables (missing ones are omitted) ---'
SELECT table_name,
       row_count,
       pg_size_pretty(total_bytes) AS total_size,
       has_gist,
       n_dead_tup,
       last_analyze,
       max_points,
       round(p99_points::numeric, 0) AS p99_points
FROM diagnose_geom_stats
ORDER BY total_bytes DESC NULLS LAST, table_name;

\echo '--- EXPLAIN provider bbox query (z18 metatile envelope) ---'
\echo '--- timeout 60s per table; a cancel means the scan did not finish ---'

DO $$
DECLARE
    r record;
    geomcol text;
    has_layer boolean;
    layer_filter text;
    env record;
    line text;
    query text;
BEGIN
    SELECT * INTO env FROM diagnose_envelope;
    PERFORM set_config('statement_timeout', '60s', true);
    FOR r IN
        SELECT t.table_name
        FROM diagnose_render_tables t
        JOIN pg_class c ON c.relname = t.table_name
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE c.relkind = 'r'
        ORDER BY t.table_name
    LOOP
        SELECT a.attname INTO geomcol
        FROM pg_attribute a
        JOIN pg_type ty ON ty.oid = a.atttypid
        WHERE a.attrelid = format('public.%I', r.table_name)::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND ty.typname = 'geometry'
        ORDER BY (a.attname = 'geom') DESC, a.attnum
        LIMIT 1;
        IF geomcol IS NULL THEN
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM pg_attribute a
            WHERE a.attrelid = format('public.%I', r.table_name)::regclass
              AND a.attname = 'layer'
              AND a.attnum > 0
              AND NOT a.attisdropped
        ) INTO has_layer;
        IF has_layer THEN
            layer_filter := ' AND "layer" = 0';
        ELSE
            layer_filter := '';
        END IF;

        query := format(
            'EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM public.%I WHERE %I && ST_MakeEnvelope(%s, %s, %s, %s, 3857)%s',
            r.table_name,
            geomcol,
            env.minx, env.miny, env.maxx, env.maxy,
            layer_filter
        );
        RAISE NOTICE '--- % ---', r.table_name;
        RAISE NOTICE '%', query;
        BEGIN
            FOR line IN EXECUTE query LOOP
                RAISE NOTICE '%', line;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'EXPLAIN failed for %: %', r.table_name, SQLERRM;
        END;
    END LOOP;
END $$;
