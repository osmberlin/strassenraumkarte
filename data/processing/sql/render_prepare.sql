-- Final render-table pass, idempotent.
-- * GIST index on the geometry column when none exists
-- * stable tid bigint identity, as primary key when the table has none,
--   otherwise as a unique column (QGIS datasource key='tid')
-- * VACUUM ANALYZE so the planner sees the real row counts

CREATE TEMP TABLE render_prepare_tables (table_name text PRIMARY KEY);
INSERT INTO render_prepare_tables (table_name) VALUES
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
    ('highway_oneway'),
    ('street_parking'),
    ('street_parking_point'),
    ('playground_node'),
    ('playground_way'),
    ('railway_node'),
    ('road_marking_node'),
    ('road_marking_polygon'),
    ('road_marking_way'),
    ('separation'),
    ('tactile_paving'),
    ('tunnel_entrance'),
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

DO $$
DECLARE
    r record;
    geomcol text;
    idxname text;
    rel regclass;
    has_gist boolean;
    has_tid boolean;
    tid_unique boolean;
    has_pk boolean;
BEGIN
    FOR r IN
        SELECT t.table_name
        FROM render_prepare_tables t
        JOIN pg_class c ON c.relname = t.table_name
        JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
        WHERE c.relkind = 'r'
        ORDER BY t.table_name
    LOOP
        rel := format('public.%I', r.table_name)::regclass;

        BEGIN
            SELECT a.attname INTO geomcol
            FROM pg_attribute a
            JOIN pg_type ty ON ty.oid = a.atttypid
            WHERE a.attrelid = rel
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND ty.typname = 'geometry'
            ORDER BY (a.attname = 'geom') DESC, a.attnum
            LIMIT 1;

            IF geomcol IS NOT NULL THEN
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_index i
                    JOIN pg_class ic ON ic.oid = i.indexrelid
                    JOIN pg_am am ON am.oid = ic.relam AND am.amname = 'gist'
                    JOIN pg_attribute a
                      ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                    WHERE i.indrelid = rel
                      AND a.attname = geomcol
                ) INTO has_gist;

                IF NOT has_gist THEN
                    idxname := r.table_name || '_' || geomcol || '_idx';
                    RAISE NOTICE 'CREATE INDEX % ON % (%)', idxname, r.table_name, geomcol;
                    EXECUTE format(
                        'CREATE INDEX %I ON public.%I USING GIST (%I)',
                        idxname, r.table_name, geomcol
                    );
                END IF;
            ELSE
                RAISE NOTICE 'skip GIST for % (no geometry column)', r.table_name;
            END IF;

            SELECT EXISTS (
                SELECT 1
                FROM pg_attribute a
                WHERE a.attrelid = rel
                  AND a.attname = 'tid'
                  AND a.attnum > 0
                  AND NOT a.attisdropped
            ) INTO has_tid;

            SELECT EXISTS (
                SELECT 1 FROM pg_index i WHERE i.indrelid = rel AND i.indisprimary
            ) INTO has_pk;

            IF NOT has_tid THEN
                IF NOT has_pk THEN
                    RAISE NOTICE 'ADD PRIMARY KEY tid ON %', r.table_name;
                    EXECUTE format(
                        'ALTER TABLE public.%I ADD COLUMN tid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY',
                        r.table_name
                    );
                ELSE
                    RAISE NOTICE 'ADD UNIQUE tid ON % (table already has a primary key)', r.table_name;
                    EXECUTE format(
                        'ALTER TABLE public.%I ADD COLUMN tid bigint GENERATED ALWAYS AS IDENTITY',
                        r.table_name
                    );
                    EXECUTE format(
                        'CREATE UNIQUE INDEX %I ON public.%I (tid)',
                        r.table_name || '_tid_key', r.table_name
                    );
                END IF;
            ELSE
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_index i
                    JOIN pg_attribute a
                      ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                    WHERE i.indrelid = rel
                      AND i.indisunique
                      AND a.attname = 'tid'
                      AND i.indnkeyatts = 1
                ) INTO tid_unique;
                IF NOT tid_unique THEN
                    RAISE NOTICE 'CREATE UNIQUE INDEX on existing tid of %', r.table_name;
                    EXECUTE format(
                        'CREATE UNIQUE INDEX %I ON public.%I (tid)',
                        r.table_name || '_tid_key', r.table_name
                    );
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'render_prepare failed for %: %', r.table_name, SQLERRM;
        END;
    END LOOP;
END $$;

-- VACUUM cannot run inside the DO block.
SELECT format('VACUUM ANALYZE public.%I;', c.relname)
FROM render_prepare_tables t
JOIN pg_class c ON c.relname = t.table_name
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
WHERE c.relkind = 'r'
ORDER BY c.relname
\gexec
