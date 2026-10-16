-- Roof shapes for the design-research styles (ink, landscape architecture).
--
-- Builds three tables from building outlines (run after building.sql):
--   roof_mass        one roof mass per connected group of similar buildings (courtyards kept as holes)
--   roof_facet       polygon facets of a mass with aspect_deg (downslope bearing, 0 = north, clockwise)
--   roof_shape_line  ridge, hip and parapet lines
--
-- Named roof_shape_line (not roof_line): building.sql reads and drops the osm2pgsql table roof_line.
--
-- Sanitising (documented in docs/design-research/ROOF-SHAPES.md):
--   1. Only outlines (building IS NOT NULL) are roof sources; building:part volumes overlap their outline.
--   2. building=roof (canopies) is skipped; slivers under 8 m² are dropped.
--   3. roof:shape → kind: flat|skillion → flat (skillion needs roof:direction, not imported);
--      gabled|saltbox|double_saltbox|quadruple_saltbox|gambrel → gabled;
--      hipped|pyramidal|mansard|round|onion|cone|dome → hipped;
--      anything else (unknown, multi-valued such as 'hipped;flat' or 'many') → default rule.
--   4. Default rule for untagged outlines: sheds/garages and <25 m² → flat; attached 3–6 storeys → hipped
--      (Gründerzeit rows and blocks; 5 storeys is the Schillerkiez norm); attached 1–2 or 7+ storeys → flat;
--      detached and large (≥350 m² or ≥5 storeys) → flat; elongated (≥1.25) → gabled; else hipped.
--   5. Touching outlines of the same kind form one mass (closed by 1.2 m to absorb wall jogs, simplified 0.4 m).
--      Masses above 9000 m² or 60 buildings fall back to one mass per building.
--
-- Distances and areas below are ground metres; metres() converts them to EPSG:3857 map units.

DROP TABLE IF EXISTS roof_shape_line;
DROP TABLE IF EXISTS roof_facet;
DROP TABLE IF EXISTS roof_mass;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Long and short side of the oriented envelope, plus the unit vector of the long side.
CREATE OR REPLACE FUNCTION roof_long_axis(g geometry)
RETURNS TABLE(long_m double precision, short_m double precision, ux double precision, uy double precision)
LANGUAGE sql IMMUTABLE AS $$
    WITH r AS (
        SELECT ST_ExteriorRing(ST_OrientedEnvelope(g)) AS ring
    ), p AS (
        SELECT ST_PointN(ring, 1) AS p0, ST_PointN(ring, 2) AS p1, ST_PointN(ring, 3) AS p2 FROM r
    ), d AS (
        SELECT ST_Distance(p0, p1) AS a, ST_Distance(p1, p2) AS b, p0, p1, p2 FROM p
    )
    SELECT
        GREATEST(a, b),
        LEAST(a, b),
        CASE WHEN a >= b THEN (ST_X(p1) - ST_X(p0)) / NULLIF(a, 0) ELSE (ST_X(p2) - ST_X(p1)) / NULLIF(b, 0) END,
        CASE WHEN a >= b THEN (ST_Y(p1) - ST_Y(p0)) / NULLIF(a, 0) ELSE (ST_Y(p2) - ST_Y(p1)) / NULLIF(b, 0) END
    FROM d
$$;

-- Compass bearing of a vector (0 = north, clockwise), in [0, 360).
CREATE OR REPLACE FUNCTION roof_bearing(vx double precision, vy double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
    SELECT ((degrees(atan2(vx, vy)) + 360.0)::numeric % 360)::double precision
$$;

-- Eight-point compass label for an aspect.
CREATE OR REPLACE FUNCTION roof_dir(aspect double precision)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['N','NE','E','SE','S','SW','W','NW'])[(floor((aspect + 22.5) / 45.0)::int % 8) + 1]
$$;

-- Ridge axis of a rectangular-ish mass: a line through the envelope centre along its long side.
CREATE OR REPLACE FUNCTION roof_gable_centreline(mass geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_MakeLine(
        ST_Translate(ST_Centroid(ST_OrientedEnvelope(mass)), -ax.ux * ax.long_m, -ax.uy * ax.long_m),
        ST_Translate(ST_Centroid(ST_OrientedEnvelope(mass)),  ax.ux * ax.long_m,  ax.uy * ax.long_m))
    FROM roof_long_axis(mass) AS ax
    WHERE ax.ux IS NOT NULL
$$;

-- Gable ridge: the centreline clipped to the mass.
CREATE OR REPLACE FUNCTION roof_gable_ridge(mass geometry)
RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
    SELECT ST_LineMerge(ST_CollectionExtract(ST_Intersection(mass, roof_gable_centreline(mass)), 2))
$$;

-- Hipped roof: straight skeleton. One facet per boundary edge; aspect = bearing from the facet's
-- interior point to the nearest boundary point (= the edge it drains to). Courtyard holes drain inwards.
CREATE OR REPLACE FUNCTION roof_hip_faces(mass geometry)
RETURNS TABLE(facet geometry, aspect_deg double precision)
LANGUAGE plpgsql AS $$
DECLARE
    ring geometry := ST_Boundary(mass);
    sk   geometry;
    f    geometry;
    p    geometry;
    cp   geometry;
BEGIN
    sk := CG_StraightSkeleton(ST_ForcePolygonCCW(mass));
    -- ST_Polygonize is an aggregate: it must sit in a subquery, not in the FROM list of a function call
    FOR f IN SELECT (ST_Dump(faces)).geom FROM (SELECT ST_Polygonize(ST_Union(ring, sk)) AS faces) AS s LOOP
        -- polygonize also returns the courtyard hole as a face: keep faces inside the mass only
        p := ST_PointOnSurface(f);
        IF NOT ST_Covers(mass, p) OR ST_Area(f) < metres(1) ^ 2 * 0.5 THEN
            CONTINUE;
        END IF;
        cp := ST_ClosestPoint(ring, p);
        facet := f;
        aspect_deg := roof_bearing(ST_X(cp) - ST_X(p), ST_Y(cp) - ST_Y(p));
        RETURN NEXT;
    END LOOP;
END $$;

-- Gabled roof: the mass is split by its centreline into two planes, each draining to its side.
CREATE OR REPLACE FUNCTION roof_gable_faces(mass geometry)
RETURNS TABLE(facet geometry, aspect_deg double precision)
LANGUAGE plpgsql AS $$
DECLARE
    cl   geometry := roof_gable_centreline(mass);
    ax   record;
    c    geometry;
    p    geometry;
    pt   geometry;
    s    double precision;
    vx   double precision;
    vy   double precision;
BEGIN
    IF cl IS NULL THEN
        RETURN;
    END IF;
    SELECT * INTO ax FROM roof_long_axis(mass);
    c := ST_Centroid(ST_OrientedEnvelope(mass));
    FOR p IN SELECT d.geom FROM ST_Dump(ST_Split(mass, cl)) AS d WHERE ST_GeometryType(d.geom) = 'ST_Polygon' LOOP
        pt := ST_PointOnSurface(p);
        s := (ST_X(pt) - ST_X(c)) * -ax.uy + (ST_Y(pt) - ST_Y(c)) * ax.ux;
        IF s >= 0 THEN
            vx := -ax.uy; vy := ax.ux;
        ELSE
            vx := ax.uy; vy := -ax.ux;
        END IF;
        facet := p;
        aspect_deg := roof_bearing(vx, vy);
        RETURN NEXT;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Sanitised outlines
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS roof_src;
CREATE TEMP TABLE roof_src AS
WITH base AS (
    SELECT
        b.osm_id,
        b.building,
        b."roof:shape" AS shape_raw,
        COALESCE(b."building:levels", ROUND(b.height / 3.0)::int) AS levels,
        ST_CollectionExtract(
            ST_MakeValid(ST_SimplifyPreserveTopology(b.geom, metres(0.25))), 3
        ) AS geom
    FROM building AS b
    WHERE b.building IS NOT NULL          -- outlines only: building:parts overlap them
      AND b.building <> 'roof'            -- canopies have no walls
)
SELECT
    osm_id, building, shape_raw, levels, geom,
    CASE
        WHEN shape_raw IN ('flat', 'skillion') THEN 'flat'
        WHEN shape_raw IN ('gabled', 'saltbox', 'double_saltbox', 'quadruple_saltbox', 'gambrel') THEN 'gabled'
        WHEN shape_raw IN ('hipped', 'pyramidal', 'mansard', 'round', 'onion', 'cone', 'dome') THEN 'hipped'
        ELSE NULL
    END AS tag_kind
FROM base
WHERE NOT ST_IsEmpty(geom)
  AND ST_Area(geom) >= metres(1) ^ 2 * 8;

CREATE INDEX roof_src_geom_idx ON roof_src USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 2) Attached count (touching outlines), default rule for untagged outlines
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS roof_src_kind;
CREATE TEMP TABLE roof_src_kind AS
WITH clustered AS (
    SELECT s.*, ST_ClusterDBSCAN(s.geom, 0.01, 1) OVER () AS cid_any
    FROM roof_src AS s
), c AS (
    SELECT clustered.*, COUNT(*) OVER (PARTITION BY cid_any) AS n_attached
    FROM clustered
)
SELECT
    c.osm_id, c.building, c.shape_raw, c.levels, c.geom, c.tag_kind, c.n_attached,
    COALESCE(c.tag_kind, CASE
        WHEN c.building IN ('garage', 'garages', 'shed', 'carport', 'service', 'greenhouse', 'storage_tank', 'hut', 'kiosk')
            THEN 'flat'
        WHEN ST_Area(c.geom) < metres(1) ^ 2 * 25 THEN 'flat'
        -- Gründerzeit rows and perimeter blocks (3–6 storeys, attached): hipped, ridge along the street
        WHEN c.n_attached > 1 AND COALESCE(c.levels, 3) BETWEEN 3 AND 6 THEN 'hipped'
        WHEN c.n_attached > 1 THEN 'flat'  -- single-storey extensions, 7+ storeys
        WHEN ST_Area(c.geom) >= metres(1) ^ 2 * 350 OR COALESCE(c.levels, 3) >= 5 THEN 'flat'
        WHEN ax.long_m / NULLIF(ax.short_m, 0) >= 1.25 THEN 'gabled'
        ELSE 'hipped'
    END) AS kind
FROM c
CROSS JOIN LATERAL roof_long_axis(c.geom) AS ax;

CREATE INDEX roof_src_kind_geom_idx ON roof_src_kind USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 3) Masses: touching outlines of the same kind become one roof
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS roof_cl;
CREATE TEMP TABLE roof_cl AS
SELECT
    kind, osm_id, geom,
    ST_ClusterDBSCAN(geom, 0.01, 1) OVER (PARTITION BY kind) AS cid
FROM roof_src_kind;

DROP TABLE IF EXISTS roof_cl_u;
CREATE TEMP TABLE roof_cl_u AS
SELECT kind, cid, COUNT(*) AS n, ARRAY_AGG(osm_id ORDER BY osm_id) AS ids, ST_Union(geom) AS geom
FROM roof_cl
GROUP BY kind, cid;

DROP TABLE IF EXISTS roof_mass_raw;
CREATE TEMP TABLE roof_mass_raw AS
SELECT kind, n, ids, geom
FROM roof_cl_u
WHERE n = 1 OR (n <= 60 AND ST_Area(geom) <= metres(1) ^ 2 * 9000)
UNION ALL
SELECT c.kind, 1, ARRAY[c.osm_id], c.geom
FROM roof_cl AS c
JOIN roof_cl_u AS u USING (kind, cid)
WHERE NOT (u.n = 1 OR (u.n <= 60 AND ST_Area(u.geom) <= metres(1) ^ 2 * 9000));

CREATE TABLE roof_mass AS
SELECT
    ROW_NUMBER() OVER (ORDER BY kind, ids[1])::int AS mass_id,
    -- a centreline split only reads on rectangle-like masses: L shapes and U shapes become hips
    CASE WHEN kind = 'gabled' AND ST_Area(geom) / NULLIF(ST_Area(ST_OrientedEnvelope(geom)), 0) < 0.75
         THEN 'hipped' ELSE kind END AS kind,
    n AS n_buildings,
    ids AS osm_ids,
    geom
FROM (
    SELECT
        kind, n, ids,
        (ST_Dump(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(
            ST_Buffer(ST_Buffer(geom, metres(1.2), 'quad_segs=2 join=mitre'),
                      -metres(1.2), 'quad_segs=2 join=mitre'),
            metres(0.4)
        )), 3))).geom AS geom
    FROM roof_mass_raw
) AS closed
WHERE ST_Area(geom) >= metres(1) ^ 2 * 8;

ALTER TABLE roof_mass ADD PRIMARY KEY (mass_id);
CREATE INDEX roof_mass_geom_idx ON roof_mass USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 4) Facets and lines per mass
-- ---------------------------------------------------------------------------

CREATE TABLE roof_facet (
    facet_id   bigserial PRIMARY KEY,
    mass_id    integer NOT NULL,
    kind       text NOT NULL,
    aspect_deg double precision,
    dir        text,
    ux         double precision,   -- unit downslope vector (east, north)
    uy         double precision,
    centroid   geometry(Point, 3857),
    geom       geometry(Polygon, 3857) NOT NULL
);

CREATE TABLE roof_shape_line (
    mass_id integer NOT NULL,
    class   text NOT NULL,      -- ridge | hip | parapet
    geom    geometry(LineString, 3857) NOT NULL
);

-- Merge facets under p_min_area into the neighbour they share the longest edge with.
-- Removes the small bowtie facets where narrow courtyard wings meet; the lines are derived from
-- facet boundaries afterwards, so the stray lines disappear with them.
CREATE OR REPLACE FUNCTION roof_merge_slivers(p_mass integer, p_min_area double precision)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    s   record;
    cur record;
    nb  record;
    n_merged integer := 0;
BEGIN
    FOR s IN SELECT facet_id FROM roof_facet
             WHERE mass_id = p_mass AND ST_Area(geom) < p_min_area ORDER BY ST_Area(geom) LOOP
        SELECT facet_id, geom INTO cur FROM roof_facet WHERE facet_id = s.facet_id;
        IF NOT FOUND OR ST_Area(cur.geom) >= p_min_area THEN
            CONTINUE;
        END IF;
        SELECT f.facet_id, f.geom INTO nb
        FROM roof_facet AS f
        WHERE f.mass_id = p_mass AND f.facet_id <> cur.facet_id AND ST_Intersects(f.geom, cur.geom)
        ORDER BY ST_Length(ST_Intersection(f.geom, cur.geom)) DESC
        LIMIT 1;
        IF NOT FOUND THEN
            CONTINUE;  -- isolated sliver: keep it
        END IF;
        UPDATE roof_facet
        SET geom = (SELECT d.geom FROM ST_Dump(ST_Union(nb.geom, cur.geom)) AS d ORDER BY ST_Area(d.geom) DESC LIMIT 1)
        WHERE facet_id = nb.facet_id;
        DELETE FROM roof_facet WHERE facet_id = cur.facet_id;
        n_merged := n_merged + 1;
    END LOOP;
    RETURN n_merged;
END $$;

-- Edge class for a straight-skeleton edge between two facets of one mass:
--   ridge  when the facets face opposite ways (>= 150° apart),
--   valley when both facets drain towards the edge (concave crease),
--   hip    otherwise (convex edge, or an edge without exactly two facets).
CREATE OR REPLACE FUNCTION roof_edge_class(p_mass integer, e geometry)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    m  geometry := ST_LineInterpolatePoint(e, 0.5);
    n  integer;
    a  roof_facet%ROWTYPE;
    b  roof_facet%ROWTYPE;
    d  double precision;
BEGIN
    SELECT count(*) INTO n FROM roof_facet WHERE mass_id = p_mass AND ST_DWithin(geom, m, 0.02);
    IF n <> 2 THEN
        RETURN 'hip';
    END IF;
    SELECT * INTO a FROM roof_facet WHERE mass_id = p_mass AND ST_DWithin(geom, m, 0.02) ORDER BY facet_id LIMIT 1;
    SELECT * INTO b FROM roof_facet WHERE mass_id = p_mass AND ST_DWithin(geom, m, 0.02) ORDER BY facet_id DESC LIMIT 1;
    d := abs(a.aspect_deg - b.aspect_deg);
    IF LEAST(d, 360 - d) >= 150 THEN
        RETURN 'ridge';
    END IF;
    IF a.ux * (ST_X(b.centroid) - ST_X(a.centroid)) + a.uy * (ST_Y(b.centroid) - ST_Y(a.centroid)) > 0
       AND b.ux * (ST_X(a.centroid) - ST_X(b.centroid)) + b.uy * (ST_Y(a.centroid) - ST_Y(b.centroid)) > 0 THEN
        RETURN 'valley';
    END IF;
    RETURN 'hip';
END $$;

DO $$
DECLARE
    m record;
    n_fail integer := 0;
BEGIN
    FOR m IN SELECT mass_id, kind, geom FROM roof_mass WHERE kind IN ('hipped', 'gabled', 'flat') LOOP
        BEGIN
            IF m.kind = 'hipped' THEN
                INSERT INTO roof_facet (mass_id, kind, aspect_deg, dir, geom)
                SELECT m.mass_id, 'hipped', h.aspect_deg, roof_dir(h.aspect_deg), h.facet
                FROM roof_hip_faces(m.geom) AS h;
                PERFORM roof_merge_slivers(m.mass_id, metres(1) ^ 2 * 3);
            ELSIF m.kind = 'gabled' THEN
                INSERT INTO roof_facet (mass_id, kind, aspect_deg, dir, geom)
                SELECT m.mass_id, 'gabled', g.aspect_deg, roof_dir(g.aspect_deg), g.facet
                FROM roof_gable_faces(m.geom) AS g;

                INSERT INTO roof_shape_line (mass_id, class, geom)
                SELECT m.mass_id, 'ridge', (ST_Dump(r)).geom
                FROM (SELECT roof_gable_ridge(m.geom) AS r) AS x
                WHERE r IS NOT NULL AND NOT ST_IsEmpty(r);
            ELSIF m.kind = 'flat' AND ST_Area(m.geom) >= metres(1) ^ 2 * 150 THEN
                -- larger flat roofs: a parapet line just inside the edge
                INSERT INTO roof_shape_line (mass_id, class, geom)
                SELECT m.mass_id, 'parapet', (ST_Dump(ST_CollectionExtract(
                    ST_Boundary(ST_Buffer(m.geom, -metres(0.5), 'quad_segs=2 join=mitre')), 2))).geom;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            n_fail := n_fail + 1;
            RAISE WARNING 'roof mass % (%) skipped: %', m.mass_id, m.kind, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'roof masses skipped: %', n_fail;
END $$;

UPDATE roof_facet
SET ux = sin(radians(aspect_deg)),
    uy = cos(radians(aspect_deg)),
    centroid = ST_Centroid(geom);

-- Ridge / hip / valley on straight-skeleton edges (see roof_edge_class).
INSERT INTO roof_shape_line (mass_id, class, geom)
SELECT pc.mass_id, roof_edge_class(pc.mass_id, pc.geom), pc.geom
FROM (
    SELECT n.mass_id, (ST_Dump(n.lines)).geom AS geom
    FROM (
        SELECT
            f.mass_id,
            ST_CollectionExtract(
                ST_LineMerge(ST_Difference(ST_Union(ST_Boundary(f.geom)), ST_Boundary(m.geom))),
            2) AS lines
        FROM roof_facet AS f
        JOIN roof_mass AS m USING (mass_id)
        WHERE f.kind = 'hipped'
        GROUP BY f.mass_id, m.geom
    ) AS n
) AS pc;

CREATE INDEX roof_facet_geom_idx ON roof_facet USING GIST (geom);
CREATE INDEX roof_facet_mass_idx ON roof_facet (mass_id);
CREATE INDEX roof_shape_line_geom_idx ON roof_shape_line USING GIST (geom);

-- Temporary intermediates are dropped with the session; keep the pipeline's DB tidy:
DROP TABLE IF EXISTS roof_src;
DROP TABLE IF EXISTS roof_src_kind;
DROP TABLE IF EXISTS roof_cl;
DROP TABLE IF EXISTS roof_cl_u;
DROP TABLE IF EXISTS roof_mass_raw;
