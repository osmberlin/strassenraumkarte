-- Create labeling lines for highways
-- Basic idea: Dissolve highway lines by name and highway class. Split road labeling lines at main roads.
-- For dual carriageways, pick a representation according to zoom level to prevent duplicate labels
-- (one of both sides for high zoom; for low zoom / main class only: skeleton centerline via
-- CG_ApproximateMedialAxis, buffering all segments of a name+class that has any dual piece).
-- Short *_link segments and short junction connectors without a collinear same-name continuation
-- are dropped so ST_LineMerge can form longer label lines.
-- At junctions with >2 same-name/same-class segments, only a collinear through-pair (+/-25 deg,
-- undirected) shares a merge_id; branches get separate merge_ids so through-lines still dissolve.
-- Before merging, shift segment vertices toward the carriageway center (placement_offset), pinning
-- endpoints that meet same-name/same-class segments so topology for LineMerge is preserved.
-- After dissolve, split long lines into roughly equal pieces (low zoom: max 1500 m,
-- high zoom: max 750 m; prefer cuts at main/minor junctions within 200 m along-line;
-- else ideal interpolate). Then ST_Simplify(1.5) only for lines that include offset≠0
-- source segments (removes offset-pin sawtooth e.g. Okerstraße; leaves pure offset=0
-- chains untouched). Finally, trim 12 m from ends near >=2 main/minor highway geometries
-- (nodes or T-junctions); true dead ends stay full length. Low-zoom lines are main-class
-- only (primary/secondary/tertiary), split at primary/secondary intersections; high-zoom
-- lines cover all classes and split at all main-class intersections. Output is one table
-- label_highway with zoom in ('low','high').

\i processing/sql/helper/line_offset.sql

BEGIN; -- Using BEGIN-END-transaction for autodeleting temporary tables at the end

-- 0) Extract roads. Tunnel sections (tunnel set and not no/none, including
-- building_passage) are omitted so dissolved label lines do not run through them.
CREATE TEMP TABLE highway_selection_raw AS
    SELECT
        row_number() OVER () AS id,
        name,
        highway,
        CASE
            WHEN highway IN ('primary', 'secondary', 'tertiary') THEN 'main'
            WHEN highway IN ('primary_link', 'secondary_link', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road') THEN 'minor'
            WHEN highway IN ('path', 'footway', 'cycleway', 'bridleway', 'steps', 'corridor', 'via_ferrata') THEN 'path'
            WHEN highway IN ('construction') THEN 'construction'
            ELSE 'path'
        END AS class,
        dual_carriageway,
        COALESCE(placement_offset, 0)::double precision AS placement_offset,
        COALESCE(transition, 0)::double precision AS transition,
        geom,
        ST_Length(geom) AS len,
        degrees(ST_Azimuth(ST_StartPoint(geom), ST_EndPoint(geom))) AS az,
        ST_StartPoint(geom) AS a,
        ST_EndPoint(geom) AS b
    FROM
        highway
    WHERE
        name IS NOT NULL
        AND name <> ''
        AND highway IN (
            'primary', 'primary_link', 'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'unclassified', 'residential', 'living_street', 'pedestrian', 'road',
            'service', 'track', 'busway', 'bus_guideway', 'escape', 'raceway',
            'path', 'footway', 'cycleway', 'bridleway', 'steps', 'corridor', 'via_ferrata',
            'construction'
        )
        -- omit tunnel sections so labels are not placed along them
        AND (
            highway.tunnel IS NULL
            OR highway.tunnel IN ('no', 'none')
        );

CREATE INDEX highway_selection_raw_a_idx ON highway_selection_raw USING GIST (a);
CREATE INDEX highway_selection_raw_b_idx ON highway_selection_raw USING GIST (b);

-- 0b) Drop short links and short junction connectors that are not a same-name continuation.
-- A connector is dropped when length <= 25 m, both ends meet >1 other named highway segment,
-- and neither end has another same-name/same-class segment with undirected azimuth within +/-25 deg.
-- Endpoint matching uses a snapped node table (equality join) instead of ST_DWithin OR-joins.
CREATE TEMP TABLE highway_ends AS
    SELECT id, name, class, az, ST_SnapToGrid(a, metres(0.5)) AS pt FROM highway_selection_raw
    UNION ALL
    SELECT id, name, class, az, ST_SnapToGrid(b, metres(0.5)) AS pt FROM highway_selection_raw;

CREATE INDEX highway_ends_pt_idx ON highway_ends (pt);

CREATE TEMP TABLE highway_selection_filtered AS
    WITH short_ends AS (
        SELECT c.id AS cand_id, e.which, c.name, c.class, c.az, ST_SnapToGrid(e.pt, metres(0.5)) AS pt
        FROM highway_selection_raw c
        CROSS JOIN LATERAL (VALUES ('a', c.a), ('b', c.b)) AS e(which, pt)
        WHERE c.len <= metres(25)
    ),
    endpoint_others AS (
        SELECT
            s.cand_id,
            s.which,
            o.id AS other_id,
            o.name AS other_name,
            o.class AS other_class,
            o.az AS other_az
        FROM short_ends s
        JOIN highway_ends o
            ON o.pt = s.pt
            AND o.id <> s.cand_id
    ),
    endpoint_stats AS (
        SELECT
            eo.cand_id,
            eo.which,
            count(DISTINCT eo.other_id) AS n_other_streets,
            bool_or(
                eo.other_name = c.name
                AND eo.other_class = c.class
                AND LEAST(
                    abs(mod(c.az::numeric, 180) - mod(eo.other_az::numeric, 180)),
                    180 - abs(mod(c.az::numeric, 180) - mod(eo.other_az::numeric, 180))
                ) <= 25
            ) AS has_collinear_same
        FROM endpoint_others eo
        JOIN highway_selection_raw c ON c.id = eo.cand_id
        GROUP BY eo.cand_id, eo.which, c.name, c.class, c.az
    ),
    drop_ids AS (
        -- short *_link always
        SELECT id
        FROM highway_selection_raw
        WHERE len <= metres(25)
          AND highway LIKE '%\_link' ESCAPE '\'
        UNION
        -- short connectors without collinear same-name continuation at either end
        SELECT c.id
        FROM highway_selection_raw c
        JOIN endpoint_stats sa ON sa.cand_id = c.id AND sa.which = 'a'
        JOIN endpoint_stats sb ON sb.cand_id = c.id AND sb.which = 'b'
        WHERE c.len <= metres(25)
          AND sa.n_other_streets > 1
          AND sb.n_other_streets > 1
          AND NOT sa.has_collinear_same
          AND NOT sb.has_collinear_same
    )
    SELECT
        id,
        name,
        highway,
        class,
        dual_carriageway,
        placement_offset,
        transition,
        geom,
        a,
        b
    FROM highway_selection_raw
    WHERE id NOT IN (SELECT id FROM drop_ids);

-- 0c) Shift vertices toward carriageway center (placement_offset). Pin endpoints that meet
-- another same-name/same-class segment so dissolve topology stays intact.
CREATE TEMP TABLE highway_selection AS
    WITH filtered_ends AS (
        SELECT id, name, class, ST_SnapToGrid(a, metres(0.5)) AS pt FROM highway_selection_filtered
        UNION ALL
        SELECT id, name, class, ST_SnapToGrid(b, metres(0.5)) FROM highway_selection_filtered
    ),
    pin_flags AS (
        SELECT
            f.id,
            EXISTS (
                SELECT 1 FROM filtered_ends e
                WHERE e.pt = ST_SnapToGrid(f.a, metres(0.5))
                  AND e.id <> f.id
                  AND e.name = f.name
                  AND e.class = f.class
            ) AS pin_start,
            EXISTS (
                SELECT 1 FROM filtered_ends e
                WHERE e.pt = ST_SnapToGrid(f.b, metres(0.5))
                  AND e.id <> f.id
                  AND e.name = f.name
                  AND e.class = f.class
            ) AS pin_end
        FROM highway_selection_filtered f
    )
    SELECT
        f.name,
        f.class,
        f.highway,
        f.dual_carriageway,
        (f.placement_offset <> 0 OR f.transition <> 0) AS has_offset,
        CASE
            WHEN f.placement_offset = 0 AND f.transition = 0 THEN f.geom
            ELSE line_offset_pin_ends(
                f.geom,
                f.placement_offset,
                f.transition,
                p.pin_start,
                p.pin_end
            )
        END AS geom
    FROM highway_selection_filtered f
    JOIN pin_flags p ON p.id = f.id;


-- 1) Extract single carriageways
CREATE TEMP TABLE single_carriageway AS
    SELECT
        name,
        class,
        has_offset,
        geom
    FROM
        highway_selection
    WHERE
        dual_carriageway IS NULL
        OR dual_carriageway = 'no';


-- 2) For dual carriageways and higher zoom levels:
-- - extract one of the dual carriageway sides (using cardinal directions)

CREATE TEMP TABLE dual_carriageway_direction AS

    -- get angle of dual carriageway line segments
    WITH dual_carriageway_azimuth AS (
        SELECT
            *,
            degrees(
                ST_Azimuth(
                    ST_StartPoint(geom),
                    ST_EndPoint(geom)
                )
            ) AS azimuth
        FROM highway_selection
        WHERE
            dual_carriageway IS NOT NULL
            AND dual_carriageway <> 'no'
    )

    -- only select roads that are directed south(-east/-west)bound, in most cases excluding the other side
    SELECT
        name,
        class,
        has_offset,
        geom
    FROM dual_carriageway_azimuth
    WHERE
        azimuth BETWEEN 90 AND 270;


-- 3) Dual-street skeleton for low zoom (main class only):
-- For every main name+class that has at least one dual_carriageway segment, buffer ALL
-- main segments of that name+class (single and dual) so island gaps and single stretches
-- fuse before CG_ApproximateMedialAxis. Buffer polygons are lightly simplified first.

CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;

-- Buffer all main-class segments of streets that include at least one dual carriageway piece.
-- (TODO: buffer only to the left side is sufficient for right driving countries, but this would need driving direction handling)
CREATE TEMP TABLE dc_buffer AS
    SELECT
        h.name,
        h.class,
        ST_Buffer(h.geom, metres(12)) AS geom
    FROM
        highway_selection h
    WHERE
        h.class = 'main'
        AND EXISTS (
            SELECT 1
            FROM highway_selection d
            WHERE d.name = h.name
              AND d.class = h.class
              AND d.dual_carriageway IS NOT NULL
              AND d.dual_carriageway <> 'no'
        );

CREATE TEMP TABLE dc_buffer_parts AS
    SELECT
        row_number() OVER () AS id,
        name,
        class,
        (ST_Dump(union_geom)).geom AS geom
    FROM (
        SELECT
            name,
            class,
            ST_UnaryUnion(ST_Collect(geom)) AS union_geom
        FROM
            dc_buffer
        GROUP BY
            name, class
    ) dissolved;

CREATE TEMP TABLE dual_carriageway_centerline AS
    WITH dc_medial AS (
        SELECT
            name,
            class,
            CG_ApproximateMedialAxis(
                ST_MakeValid(ST_SimplifyPreserveTopology(geom, metres(1.0)))
            ) AS geom
        FROM
            dc_buffer_parts
        -- exclude small buffer areas, e.g. from traffic islands
        WHERE
            ST_Area(geom) > 3000
            AND ST_GeometryType(geom) = 'ST_Polygon'
    ),
    dc_centerlines AS (
        SELECT
            name,
            class,
            (ST_Dump(ST_LineMerge(ST_CollectionExtract(geom, 2)))).geom AS geom
        FROM
            dc_medial
        WHERE
            geom IS NOT NULL
            AND NOT ST_IsEmpty(geom)
    ),
    dc_centerlines_simplified AS (
        SELECT
            name,
            class,
            ST_Simplify(geom, metres(0.5)) AS geom
        FROM
            dc_centerlines
        WHERE
            ST_Length(geom) > metres(40)
    ),
    dc_centerlines_shortened AS (
        SELECT
            name,
            class,
            ST_LineSubstring(geom, metres(10) / ST_Length(geom), 1 - (metres(10) / ST_Length(geom))) AS geom
        FROM
            dc_centerlines_simplified
        WHERE
            ST_Length(geom) > metres(20)
    )
    SELECT
        name,
        class,
        false AS has_offset,
        geom
    FROM dc_centerlines_shortened;


-- 4) Merge labeling lines for different zoom levels via merge_id
-- Segments share a merge_id when connected at degree-2 nodes, or as the collinear through-pair
-- at higher-degree nodes (undirected azimuth within +/-25 deg). Then dissolve per merge_id.
-- Connected components use union-find (not a recursive transitive closure) for scalability.

CREATE TEMP TABLE merge_source (
    name text,
    class text,
    has_offset boolean,
    geom geometry
);

CREATE OR REPLACE FUNCTION pg_temp.undirected_az_diff(a double precision, b double precision)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT LEAST(
        abs(mod(a::numeric, 180) - mod(b::numeric, 180)),
        180 - abs(mod(a::numeric, 180) - mod(b::numeric, 180))
    );
$$;

-- Reads merge_source(name, class, has_offset, geom); returns dissolved label lines.
CREATE OR REPLACE FUNCTION pg_temp.dissolve_with_merge_id()
RETURNS TABLE(out_name text, out_class text, out_has_offset boolean, out_geom geometry)
LANGUAGE plpgsql
AS $$
DECLARE
    parent int[];
    n int;
    r record;
    x int;
    y int;
    px int;
BEGIN
    DROP TABLE IF EXISTS _label_segs;
    DROP TABLE IF EXISTS _label_pairs;
    DROP TABLE IF EXISTS _label_merge_ids;

    CREATE TEMP TABLE _label_segs AS
    SELECT
        row_number() OVER ()::int AS sid,
        ms.name,
        ms.class,
        COALESCE(ms.has_offset, false) AS has_offset,
        ms.geom,
        degrees(ST_Azimuth(ST_StartPoint(ms.geom), ST_EndPoint(ms.geom))) AS az,
        ST_SnapToGrid(ST_StartPoint(ms.geom), metres(0.1)) AS a,
        ST_SnapToGrid(ST_EndPoint(ms.geom), metres(0.1)) AS b
    FROM merge_source ms;

    CREATE TEMP TABLE _label_pairs AS
    WITH ends AS (
        SELECT sid, name, class, a AS pt FROM _label_segs
        UNION ALL
        SELECT sid, name, class, b AS pt FROM _label_segs
    ),
    node_deg AS (
        SELECT
            name,
            class,
            pt,
            count(DISTINCT sid) AS deg,
            array_agg(DISTINCT sid ORDER BY sid) AS sids
        FROM ends
        GROUP BY name, class, pt
    ),
    pairs_deg2 AS (
        SELECT sids[1] AS sid1, sids[2] AS sid2
        FROM node_deg
        WHERE deg = 2
    ),
    best_partner AS (
        SELECT DISTINCT ON (n.name, n.class, n.pt, e1.sid)
            e1.sid AS sid1,
            e2.sid AS sid2
        FROM node_deg n
        JOIN ends e1 ON e1.pt = n.pt AND e1.name = n.name AND e1.class = n.class
        JOIN ends e2 ON e2.pt = n.pt AND e2.name = n.name AND e2.class = n.class AND e2.sid <> e1.sid
        JOIN _label_segs s1 ON s1.sid = e1.sid
        JOIN _label_segs s2 ON s2.sid = e2.sid
        WHERE n.deg > 2
          AND pg_temp.undirected_az_diff(s1.az, s2.az) <= 25
        ORDER BY
            n.name, n.class, n.pt, e1.sid,
            pg_temp.undirected_az_diff(s1.az, s2.az),
            e2.sid
    ),
    pairs_through AS (
        SELECT DISTINCT
            LEAST(a.sid1, a.sid2) AS sid1,
            GREATEST(a.sid1, a.sid2) AS sid2
        FROM best_partner a
        JOIN best_partner b
            ON a.sid1 = b.sid2 AND a.sid2 = b.sid1
    )
    SELECT sid1, sid2 FROM pairs_deg2
    UNION
    SELECT sid1, sid2 FROM pairs_through;

    SELECT coalesce(max(sid), 0) INTO n FROM _label_segs;
    parent := array_fill(0, ARRAY[n]);

    FOR r IN SELECT sid FROM _label_segs LOOP
        parent[r.sid] := r.sid;
    END LOOP;

    FOR r IN SELECT sid1, sid2 FROM _label_pairs LOOP
        x := r.sid1;
        WHILE parent[x] <> x LOOP
            x := parent[x];
        END LOOP;
        y := r.sid2;
        WHILE parent[y] <> y LOOP
            y := parent[y];
        END LOOP;
        IF x <> y THEN
            IF x < y THEN
                parent[y] := x;
            ELSE
                parent[x] := y;
            END IF;
        END IF;
    END LOOP;

    CREATE TEMP TABLE _label_merge_ids (sid int PRIMARY KEY, merge_id int);

    FOR r IN SELECT sid FROM _label_segs LOOP
        x := r.sid;
        WHILE parent[x] <> x LOOP
            x := parent[x];
        END LOOP;
        y := r.sid;
        WHILE y <> x LOOP
            px := parent[y];
            parent[y] := x;
            y := px;
        END LOOP;
        INSERT INTO _label_merge_ids VALUES (r.sid, x);
    END LOOP;

    RETURN QUERY
    WITH dissolved AS (
        SELECT
            s.name,
            s.class,
            m.merge_id,
            sum(ST_Length(s.geom)) FILTER (WHERE s.has_offset) AS offset_len,
            sum(ST_Length(s.geom)) AS total_len,
            ST_LineMerge(ST_Union(s.geom)) AS geom
        FROM _label_segs s
        JOIN _label_merge_ids m ON m.sid = s.sid
        GROUP BY s.name, s.class, m.merge_id
    )
    SELECT
        d.name,
        d.class,
        -- true when offsetted source geometry is a meaningful share (not a tiny stub)
        COALESCE(d.offset_len, 0) >= 50
            OR COALESCE(d.offset_len / NULLIF(d.total_len, 0), 0) >= 0.4
            AS has_offset,
        (ST_Dump(d.geom)).geom
    FROM dissolved d;
END;
$$;

-- Junction candidates for long-label segmentation (centered main/minor network)
CREATE TEMP TABLE label_split_roads AS
    SELECT geom
    FROM highway_selection
    WHERE class IN ('main', 'minor');
CREATE INDEX label_split_roads_gix ON label_split_roads USING GIST (geom);

-- Low zoom: main-class only — single carriageways + dual-street skeleton centerline.
-- Single-carriageway segments of name+class already covered by the centerline are omitted.
INSERT INTO merge_source
    SELECT s.name, s.class, s.has_offset, s.geom
    FROM single_carriageway s
    WHERE s.class = 'main'
      AND NOT EXISTS (
        SELECT 1
        FROM dual_carriageway_centerline c
        WHERE c.name = s.name
          AND c.class = s.class
    )
    UNION ALL
    SELECT name, class, has_offset, geom FROM dual_carriageway_centerline;

CREATE TEMP TABLE dissolved_z1_merged AS
    SELECT
        out_name AS name,
        out_class AS class,
        out_has_offset AS has_offset,
        out_geom AS geom
    FROM pg_temp.dissolve_with_merge_id()
    WHERE out_geom IS NOT NULL
      AND GeometryType(out_geom) = 'LINESTRING'
      AND ST_Length(out_geom) > metres(5);

-- Split lines >1500 m into ~equal pieces; snap cuts to junctions within 200 m along-line.
CREATE TEMP TABLE dissolved_z1 AS
    WITH long_lines AS (
        SELECT
            row_number() OVER () AS lid,
            name,
            class,
            has_offset,
            geom,
            ST_Length(geom) AS len,
            ceil(ST_Length(geom) / metres(1500))::integer AS n
        FROM dissolved_z1_merged
        WHERE ST_Length(geom) > metres(1500)
    ),
    short_keep AS (
        SELECT name, class, has_offset, geom
        FROM dissolved_z1_merged
        WHERE ST_Length(geom) <= metres(1500)
    ),
    ideal_cuts AS (
        SELECT
            l.lid,
            l.name,
            l.class,
            l.has_offset,
            l.geom,
            l.len,
            l.n,
            gs.i AS cut_i,
            (gs.i::double precision / l.n) AS ideal_frac
        FROM long_lines l
        CROSS JOIN LATERAL generate_series(1, l.n - 1) AS gs(i)
    ),
    junction_fracs AS (
        SELECT
            l.lid,
            ST_LineLocatePoint(l.geom, pt.geom) AS frac
        FROM long_lines l
        JOIN label_split_roads r
            ON ST_DWithin(l.geom, r.geom, metres(1))
        CROSS JOIN LATERAL (
            SELECT (ST_Dump(
                ST_CollectionExtract(ST_MakeValid(ST_Intersection(l.geom, r.geom)), 1)
            )).geom
        ) AS pt
        WHERE NOT ST_IsEmpty(pt.geom)
          AND GeometryType(pt.geom) = 'POINT'
    ),
    junction_fracs_ok AS (
        SELECT DISTINCT jf.lid, jf.frac
        FROM junction_fracs jf
        JOIN long_lines l ON l.lid = jf.lid
        WHERE jf.frac * l.len > 1.0
          AND (1.0 - jf.frac) * l.len > 1.0
    ),
    snapped_cuts AS (
        SELECT
            ic.lid,
            ic.name,
            ic.class,
            ic.has_offset,
            ic.geom,
            ic.len,
            ic.cut_i,
            COALESCE(
                (
                    SELECT jf.frac
                    FROM junction_fracs_ok jf
                    WHERE jf.lid = ic.lid
                      AND abs(jf.frac - ic.ideal_frac) * ic.len <= metres(200)
                    ORDER BY abs(jf.frac - ic.ideal_frac)
                    LIMIT 1
                ),
                ic.ideal_frac
            ) AS cut_frac
        FROM ideal_cuts ic
    ),
    cut_fracs AS (
        SELECT DISTINCT ON (lid, round((cut_frac * len)::numeric, 0))
            lid, name, class, has_offset, geom, len, cut_frac
        FROM snapped_cuts
        ORDER BY lid, round((cut_frac * len)::numeric, 0), cut_i
    ),
    cut_bounds AS (
        SELECT lid, name, class, has_offset, geom, frac_from, frac_to
        FROM (
            SELECT
                lid, name, class, has_offset, geom,
                frac AS frac_from,
                lead(frac) OVER (PARTITION BY lid ORDER BY frac) AS frac_to
            FROM (
                SELECT lid, name, class, has_offset, geom, 0.0 AS frac FROM long_lines
                UNION ALL
                SELECT lid, name, class, has_offset, geom, cut_frac FROM cut_fracs
                UNION ALL
                SELECT lid, name, class, has_offset, geom, 1.0 AS frac FROM long_lines
            ) u
        ) b
        WHERE frac_to IS NOT NULL
          AND frac_to > frac_from + 1e-9
    ),
    pieces AS (
        SELECT
            name,
            class,
            has_offset,
            ST_LineSubstring(geom, frac_from, frac_to) AS geom
        FROM cut_bounds
    ),
    -- If junction snaps collapsed, force equal ideal cuts so no piece exceeds 1500 m
    pieces_sized AS (
        SELECT
            name,
            class,
            has_offset,
            geom,
            ST_Length(geom) AS len,
            ceil(ST_Length(geom) / metres(1500))::integer AS n
        FROM pieces
        WHERE geom IS NOT NULL
          AND GeometryType(geom) = 'LINESTRING'
    ),
    pieces_final AS (
        SELECT name, class, has_offset, geom
        FROM pieces_sized
        WHERE len <= metres(1500)
        UNION ALL
        SELECT
            p.name,
            p.class,
            p.has_offset,
            ST_LineSubstring(
                p.geom,
                (gs.i - 1)::double precision / p.n,
                gs.i::double precision / p.n
            ) AS geom
        FROM pieces_sized p
        CROSS JOIN LATERAL generate_series(1, p.n) AS gs(i)
        WHERE p.len > metres(1500)
    ),
    combined AS (
        SELECT name, class, has_offset, geom FROM short_keep
        UNION ALL
        SELECT name, class, has_offset, geom FROM pieces_final
    )
    SELECT
        name,
        class,
        -- DP 1.5 m only where at least one source segment had placement_offset/transition;
        -- pure offset=0 chains stay unsimplified to keep natural curvature (e.g. Kienitzer)
        CASE
            WHEN has_offset THEN ST_Simplify(geom, metres(1.5))
            ELSE geom
        END AS geom
    FROM combined
    WHERE geom IS NOT NULL
      AND GeometryType(geom) = 'LINESTRING'
      AND ST_Length(geom) > metres(5);

-- For higher zoom levels: merge single carriageways with one of the dual carriageway sides
TRUNCATE merge_source;
INSERT INTO merge_source
    SELECT name, class, has_offset, geom FROM single_carriageway
    UNION ALL
    SELECT name, class, has_offset, geom FROM dual_carriageway_direction;

CREATE TEMP TABLE dissolved_z2_merged AS
    SELECT
        out_name AS name,
        out_class AS class,
        out_has_offset AS has_offset,
        out_geom AS geom
    FROM pg_temp.dissolve_with_merge_id()
    WHERE out_geom IS NOT NULL
      AND GeometryType(out_geom) = 'LINESTRING'
      AND ST_Length(out_geom) > metres(5);

CREATE TEMP TABLE dissolved_z2 AS
    WITH long_lines AS (
        SELECT
            row_number() OVER () AS lid,
            name,
            class,
            has_offset,
            geom,
            ST_Length(geom) AS len,
            ceil(ST_Length(geom) / metres(750))::integer AS n
        FROM dissolved_z2_merged
        WHERE ST_Length(geom) > metres(750)
    ),
    short_keep AS (
        SELECT name, class, has_offset, geom
        FROM dissolved_z2_merged
        WHERE ST_Length(geom) <= metres(750)
    ),
    ideal_cuts AS (
        SELECT
            l.lid,
            l.name,
            l.class,
            l.has_offset,
            l.geom,
            l.len,
            l.n,
            gs.i AS cut_i,
            (gs.i::double precision / l.n) AS ideal_frac
        FROM long_lines l
        CROSS JOIN LATERAL generate_series(1, l.n - 1) AS gs(i)
    ),
    junction_fracs AS (
        SELECT
            l.lid,
            ST_LineLocatePoint(l.geom, pt.geom) AS frac
        FROM long_lines l
        JOIN label_split_roads r
            ON ST_DWithin(l.geom, r.geom, metres(1))
        CROSS JOIN LATERAL (
            SELECT (ST_Dump(
                ST_CollectionExtract(ST_MakeValid(ST_Intersection(l.geom, r.geom)), 1)
            )).geom
        ) AS pt
        WHERE NOT ST_IsEmpty(pt.geom)
          AND GeometryType(pt.geom) = 'POINT'
    ),
    junction_fracs_ok AS (
        SELECT DISTINCT jf.lid, jf.frac
        FROM junction_fracs jf
        JOIN long_lines l ON l.lid = jf.lid
        WHERE jf.frac * l.len > 1.0
          AND (1.0 - jf.frac) * l.len > 1.0
    ),
    snapped_cuts AS (
        SELECT
            ic.lid,
            ic.name,
            ic.class,
            ic.has_offset,
            ic.geom,
            ic.len,
            ic.cut_i,
            COALESCE(
                (
                    SELECT jf.frac
                    FROM junction_fracs_ok jf
                    WHERE jf.lid = ic.lid
                      AND abs(jf.frac - ic.ideal_frac) * ic.len <= metres(200)
                    ORDER BY abs(jf.frac - ic.ideal_frac)
                    LIMIT 1
                ),
                ic.ideal_frac
            ) AS cut_frac
        FROM ideal_cuts ic
    ),
    cut_fracs AS (
        SELECT DISTINCT ON (lid, round((cut_frac * len)::numeric, 0))
            lid, name, class, has_offset, geom, len, cut_frac
        FROM snapped_cuts
        ORDER BY lid, round((cut_frac * len)::numeric, 0), cut_i
    ),
    cut_bounds AS (
        SELECT lid, name, class, has_offset, geom, frac_from, frac_to
        FROM (
            SELECT
                lid, name, class, has_offset, geom,
                frac AS frac_from,
                lead(frac) OVER (PARTITION BY lid ORDER BY frac) AS frac_to
            FROM (
                SELECT lid, name, class, has_offset, geom, 0.0 AS frac FROM long_lines
                UNION ALL
                SELECT lid, name, class, has_offset, geom, cut_frac FROM cut_fracs
                UNION ALL
                SELECT lid, name, class, has_offset, geom, 1.0 AS frac FROM long_lines
            ) u
        ) b
        WHERE frac_to IS NOT NULL
          AND frac_to > frac_from + 1e-9
    ),
    pieces AS (
        SELECT
            name,
            class,
            has_offset,
            ST_LineSubstring(geom, frac_from, frac_to) AS geom
        FROM cut_bounds
    ),
    pieces_sized AS (
        SELECT
            name,
            class,
            has_offset,
            geom,
            ST_Length(geom) AS len,
            ceil(ST_Length(geom) / metres(750))::integer AS n
        FROM pieces
        WHERE geom IS NOT NULL
          AND GeometryType(geom) = 'LINESTRING'
    ),
    pieces_final AS (
        SELECT name, class, has_offset, geom
        FROM pieces_sized
        WHERE len <= metres(750)
        UNION ALL
        SELECT
            p.name,
            p.class,
            p.has_offset,
            ST_LineSubstring(
                p.geom,
                (gs.i - 1)::double precision / p.n,
                gs.i::double precision / p.n
            ) AS geom
        FROM pieces_sized p
        CROSS JOIN LATERAL generate_series(1, p.n) AS gs(i)
        WHERE p.len > metres(750)
    ),
    combined AS (
        SELECT name, class, has_offset, geom FROM short_keep
        UNION ALL
        SELECT name, class, has_offset, geom FROM pieces_final
    )
    SELECT
        name,
        class,
        CASE
            WHEN has_offset THEN ST_Simplify(geom, metres(1.5))
            ELSE geom
        END AS geom
    FROM combined
    WHERE geom IS NOT NULL
      AND GeometryType(geom) = 'LINESTRING'
      AND ST_Length(geom) > metres(5);


-- 5) Split dissolved lines at main road intersections
-- low zoom: only primary/secondary act as blades (not tertiary).
-- high zoom: all class=main (primary/secondary/tertiary).
CREATE TEMP TABLE label_highway_low_raw AS

    WITH dissolved_id AS (
        SELECT
            row_number() OVER () AS s_id,
            name,
            class,
            geom
        FROM dissolved_z1
    ),
    main_roads AS (
        SELECT d.s_id, d.geom
        FROM dissolved_id d
        WHERE d.class = 'main'
          AND EXISTS (
            SELECT 1
            FROM highway_selection h
            WHERE h.highway IN ('primary', 'secondary')
              AND h.name = d.name
              AND h.class = d.class
              AND ST_DWithin(d.geom, h.geom, metres(2))
          )
    ),
    -- extract intersection nodes with main roads and create small buffers from them
    blade_points AS (
        SELECT DISTINCT
            d.s_id,
            ST_Buffer(ST_Intersection(d.geom, m.geom), metres(1)) AS geom
        FROM dissolved_id d
        JOIN main_roads m
            ON d.s_id <> m.s_id
            AND d.geom && m.geom
            AND ST_Intersects(d.geom, m.geom)
    ),
    -- split segments at main road intersections
    split AS (
        SELECT
            s.s_id, s.name, s.class,
            (ST_Dump(ST_Split(s.geom, ST_UnaryUnion(ST_Collect(b.geom))))).geom AS geom
        FROM dissolved_id s
        JOIN blade_points b
            ON b.s_id = s.s_id
        GROUP BY
            s.s_id, s.name, s.class, s.geom
    ),
    untouched AS (
        SELECT d.*
        FROM dissolved_id d
        WHERE NOT EXISTS (SELECT 1 FROM split s WHERE s.s_id = d.s_id)
    )

    SELECT name, class, geom FROM split WHERE ST_Length(geom) > metres(5)
    UNION ALL
    SELECT name, class, geom FROM untouched WHERE ST_Length(geom) > metres(5);

-- High zoom:
CREATE TEMP TABLE label_highway_high_raw AS

    WITH dissolved_id AS (
        SELECT
            row_number() OVER () AS s_id,
            name,
            class,
            geom
        FROM dissolved_z2
    ),
    main_roads AS (
        SELECT s_id, geom FROM dissolved_id WHERE class = 'main'
    ),
    blade_points AS (
        SELECT DISTINCT
            d.s_id,
            ST_Buffer(ST_Intersection(d.geom, m.geom), metres(1)) AS geom
        FROM dissolved_id d
        JOIN main_roads m
            ON d.s_id <> m.s_id
            AND d.geom && m.geom
            AND ST_Intersects(d.geom, m.geom)
    ),
    split AS (
        SELECT
            s.s_id, s.name, s.class,
            (ST_Dump(ST_Split(s.geom, ST_UnaryUnion(ST_Collect(b.geom))))).geom AS geom
        FROM dissolved_id s
        JOIN blade_points b
            ON b.s_id = s.s_id
        GROUP BY
            s.s_id, s.name, s.class, s.geom
    ),
    untouched AS (
        SELECT d.*
        FROM dissolved_id d
        WHERE NOT EXISTS (SELECT 1 FROM split s WHERE s.s_id = d.s_id)
    )

    SELECT name, class, geom FROM split WHERE ST_Length(geom) > metres(5)
    UNION ALL
    SELECT name, class, geom FROM untouched WHERE ST_Length(geom) > metres(5);


-- 6) Trim 12 m from ends that connect to another main/minor road in the original network.
-- An end is trimmed when >= 2 main/minor highway_selection geometries lie within 3 m
-- (covers shared nodes and T-junctions onto a road mid-edge; radius allows for
-- center-offset endpoints that moved away from the connecting street). Dead ends
-- (only the own segment nearby) stay unchanged.
CREATE TEMP TABLE road_lines AS
    SELECT geom
    FROM highway_selection
    WHERE class IN ('main', 'minor');

CREATE INDEX road_lines_geom_idx ON road_lines USING GIST (geom);

CREATE OR REPLACE FUNCTION pg_temp.trim_label_ends(src_name text)
RETURNS TABLE(out_name text, out_class text, out_geom geometry)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE format($sql$
        WITH labeled AS (
            SELECT
                r.name,
                r.class,
                r.geom,
                ST_Length(r.geom) AS len,
                (
                    SELECT count(*) >= 2
                    FROM road_lines h
                    WHERE ST_DWithin(h.geom, ST_StartPoint(r.geom), metres(3.0))
                ) AS trim_a,
                (
                    SELECT count(*) >= 2
                    FROM road_lines h
                    WHERE ST_DWithin(h.geom, ST_EndPoint(r.geom), metres(3.0))
                ) AS trim_b
            FROM %I r
        ),
        trimmed AS (
            SELECT
                l.name,
                l.class,
                CASE
                    WHEN l.len > (CASE WHEN l.trim_a THEN metres(12) ELSE 0 END
                                  + CASE WHEN l.trim_b THEN metres(12) ELSE 0 END)
                    THEN ST_LineSubstring(
                        l.geom,
                        CASE WHEN l.trim_a THEN metres(12.0) / l.len ELSE 0 END,
                        CASE WHEN l.trim_b THEN 1.0 - metres(12.0) / l.len ELSE 1 END
                    )
                    ELSE l.geom
                END AS geom
            FROM labeled l
        )
        SELECT t.name, t.class, t.geom
        FROM trimmed t
        WHERE ST_Length(t.geom) > metres(5)
    $sql$, src_name);
END;
$$;

DROP TABLE IF EXISTS label_highway;
CREATE TABLE label_highway AS
    SELECT out_name AS name, out_class AS class, 'low'::text AS zoom, out_geom AS geom
    FROM pg_temp.trim_label_ends('label_highway_low_raw')
    UNION ALL
    SELECT out_name AS name, out_class AS class, 'high'::text AS zoom, out_geom AS geom
    FROM pg_temp.trim_label_ends('label_highway_high_raw');

DROP TABLE IF EXISTS label_highway_z1;
DROP TABLE IF EXISTS label_highway_z2;


END; -- delete temporary tables

DROP INDEX IF EXISTS label_highway_geom_idx;
DROP INDEX IF EXISTS label_highway_zoom_idx;
DROP INDEX IF EXISTS label_highway_z1_geom_idx;
DROP INDEX IF EXISTS label_highway_z2_geom_idx;
CREATE INDEX label_highway_geom_idx ON label_highway USING GIST (geom);
CREATE INDEX label_highway_zoom_idx ON label_highway (zoom);