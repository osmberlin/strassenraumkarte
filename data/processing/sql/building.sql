-- Create geometries for all building parts with information on height and floating building parts as well as lines to represent the edges of buildings

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'

SET work_mem = '256MB';

SELECT Find_SRID('public', 'building', 'geom') AS building_srid \gset


-- 1) Preparation: Distinguish building parts by height and floating building areas

-- Step A: For buildings: derive height from building:levels or use default building heights
UPDATE building
SET height = 
    CASE 
        -- derive height from building:levels...
        WHEN "building:levels" IS NOT NULL THEN "building:levels" * 3
        -- ...or use default building heights: 3m for roofs and service buildings, 5m otherwise
        WHEN building IN ('roof', 'service') THEN 3
        ELSE 5
    END
WHERE
    height IS NULL
    AND "building:part" IS NULL
    AND building IS NOT NULL;
    
-- Step B: For building:parts: adopt heigth from their building outlines, if not explicitly specified.
-- Deterministic when multiple outlines contain a part: largest outline area, then lowest osm_id.
UPDATE building AS part
SET height = picked.height_value
FROM (
    SELECT DISTINCT ON (part.osm_id)
        part.osm_id AS part_id,
        CASE
            WHEN part."building:levels" IS NOT NULL THEN
                CASE
                    WHEN part."building:levels" = outline."building:levels" AND outline.height IS NOT NULL THEN outline.height
                    ELSE part."building:levels" * 3
                END
            ELSE outline.height
        END AS height_value
    FROM building AS part
    JOIN building AS outline
      ON outline."building" IS NOT NULL
     AND ST_Contains(outline.geom, part.geom)
    WHERE part.height IS NULL
      AND part."building:part" IS NOT NULL
    ORDER BY part.osm_id, ST_Area(outline.geom) DESC, outline.osm_id
) AS picked
WHERE part.osm_id = picked.part_id;

-- Step C: Workaround for flawed building:parts that aren't fully contained in building outlines and therefore still have no height (indicator for mapping errors)
WITH overlap_areas AS (
    SELECT
        part.osm_id AS part_id,
        outline.osm_id AS outline_id,
        outline.building AS outline_building,
        outline."building:levels" AS outline_building_levels,
        outline.height AS outline_height,
        ST_Area(ST_Intersection(part.geom, outline.geom)) AS intersection_area
    FROM 
        building AS part
    JOIN 
        building AS outline
    ON 
        ST_Intersects(part.geom, outline.geom)
    WHERE 
        part.height IS NULL 
        AND part."building:part" IS NOT NULL
        AND outline."building" IS NOT NULL
),
best_matches AS (
    SELECT
        part_id,
        outline_id,
        outline_building,
        outline_building_levels,
        outline_height,
        ROW_NUMBER() OVER (
            PARTITION BY part_id
            ORDER BY intersection_area DESC, outline_id
        ) AS rank
    FROM 
        overlap_areas
)
UPDATE building AS part
SET height = 
    CASE
        WHEN best_matches.outline_height IS NOT NULL THEN best_matches.outline_height
        WHEN best_matches.outline_building_levels IS NOT NULL THEN best_matches.outline_building_levels * 3
        WHEN best_matches.outline_building IN ('roof', 'service') THEN 3
        ELSE 5
    END
FROM best_matches
WHERE part.osm_id = best_matches.part_id AND best_matches.rank = 1;

-- Step D: There can still be some parts without height attribute, namely building:parts that don't intersect building outlines at all (also an indicator for mapping errors)
UPDATE building
SET height =
    CASE
        WHEN "building:levels" IS NOT NULL THEN "building:levels" * 3
        WHEN building IN ('roof', 'service') OR "building:part" IN ('roof', 'service') THEN 3
        ELSE 5
    END
WHERE
    height IS NULL;

-- Step E: Merge "building:min_level" > 0 and "min_height" > 0 and roofs to a simple "floating" true/false attribute
ALTER TABLE building ADD COLUMN IF NOT EXISTS floating BOOLEAN;

UPDATE building
SET floating = 
    CASE 
        WHEN "building:min_level" > 0 OR "min_height" > 0 OR "building" = 'roof' OR "building:part" = 'roof' THEN TRUE
        ELSE FALSE
    END;

ANALYZE building;


-- 2) Create a table that contains exactly one area for each location within building areas, according to the different height and floating attributes of all parts

BEGIN; -- Using BEGIN-END-transaction for autodeleting temporary tables at the end

-- Step A: Extract all building and building part boundaries ("blade")
CREATE TEMP TABLE temp_edges AS
SELECT ST_Union(ST_Boundary(geom)) AS geom
FROM building;

-- Step B: Use these "blade" to split the total building area to create exactly one polygon ("face") for each part of the building
-- The faces form a noded polygonal coverage, which allows ST_CoverageUnion for all dissolve steps below
CREATE TEMP TABLE temp_parts_raw AS
SELECT
    ROW_NUMBER() OVER () AS face_id,
    geom,
    ST_PointOnSurface(geom) AS pt
FROM (
    SELECT (ST_Dump(ST_Polygonize(geom))).geom AS geom
    FROM temp_edges
) faces;

ANALYZE temp_parts_raw;

-- Step C: Fetch height and floating attributes from building parts or building outlines (if there are no parts)
-- Faces never cross a building boundary, so a face lies within a building exactly if an interior point of the face does
-- (faces outside all buildings, e.g. enclosed courtyards, find no building and are dropped)
CREATE TEMP TABLE temp_parts_single AS
WITH building_overlap AS (
    SELECT
        face.face_id,
        building.height,
        building.floating,
        (building.building IS NULL) AS is_part
    FROM temp_parts_raw face
    JOIN building ON ST_Intersects(building.geom, face.pt)
),
face_attributes AS (
    SELECT
        face_id,
        -- from all parts at this location, pick the maximum height value (from building parts, or from builing outlines, if there are no parts)
        COALESCE(
            MAX(height) FILTER (WHERE is_part),
            MAX(height)
        ) AS height,
        -- from all parts at this location, pick a fitting floating value...
        CASE
            WHEN BOOL_OR(floating = false) FILTER (WHERE is_part) THEN FALSE -- floating=false, if there is a non-floating building part at this location,
            WHEN COUNT(*) FILTER (WHERE is_part) > 0 THEN TRUE  -- or floating=true otherwise (if there are building parts existing)
            WHEN BOOL_OR(floating = false) THEN FALSE  -- or floating=false, if there are no building parts, but a non-floating building outline
            ELSE TRUE  -- or floating=true, if the whole building is floating (e.g. roofs)
        END AS floating
    FROM building_overlap
    GROUP BY face_id
)
SELECT
    face.geom,
    face_attributes.height,
    face_attributes.floating,
    -- id of the group of touching faces: dissolving per cluster keeps every union small
    ST_ClusterDBSCAN(face.geom, 0, 1) OVER () AS cluster_id
FROM face_attributes
JOIN temp_parts_raw face USING (face_id);

ANALYZE temp_parts_single;

-- Step D: Create a persistent table with polygons for rendering different building/height levels (merge building parts by height and floating)
-- ST_CoverageUnion drops the SRID and can return self-touching rings, so SRID and validity have to be restored
DROP TABLE IF EXISTS building_parts;

CREATE TABLE building_parts AS
SELECT height, floating, (ST_Dump(ST_SetSRID(ST_CollectionExtract(ST_MakeValid(ST_CoverageUnion(geom)), 3), :building_srid))).geom AS geom
FROM temp_parts_single
GROUP BY cluster_id, height, floating;

-- Step E: Merge building parts by height only (dissolved into individual polygons, not multipolygons)
DROP TABLE IF EXISTS building_parts_dissolved_height;

CREATE TABLE building_parts_dissolved_height AS
SELECT height, (ST_Dump(ST_SetSRID(ST_CollectionExtract(ST_MakeValid(ST_CoverageUnion(geom)), 3), :building_srid))).geom AS geom
FROM temp_parts_single
GROUP BY cluster_id, height;

-- Step F: Extrude building areas into shade polygons (NE direction; length asymptotic in height)
-- The 2D footprint of the extrusion is the sweep of the polygon along the shade vector:
-- polygon + translated polygon + the swept strips of all edges facing the shade direction
-- (with CCW exterior / CW interior rings, the outward normal of edge p1->p2 is (y2 - y1, x1 - x2)).
-- A chain of consecutive facing edges is monotone across the shade direction, so its swept strip is a simple polygon.
-- Shortcuts: no sweep for zero shade length; the sweep of a convex polygon is the convex hull of both copies.
DROP TABLE IF EXISTS building_shade;

CREATE TABLE building_shade AS
WITH src AS (
    SELECT
        ROW_NUMBER() OVER () AS id,
        height,
        ST_ForcePolygonCCW(ST_MakeValid(geom)) AS geom,
        :'building_shade_base_m'::double precision
            + (:'building_shade_max_m'::double precision
               - :'building_shade_base_m'::double precision)
              * (1.0 - exp(
                    -GREATEST(
                        COALESCE(height, 0) - :'building_shade_height_offset_m'::double precision,
                        0
                    )
                      / :'building_shade_height_scale_m'::double precision
                ))
            AS shade_len_m
    FROM building_parts_dissolved_height
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
),
shade_vector AS (
    SELECT
        id,
        height,
        geom,
        shade_len_m,
        ST_NumInteriorRings(geom) = 0
            AND ST_Area(ST_ConvexHull(geom)) - ST_Area(geom) < 1e-6 * ST_Area(geom) AS is_convex,
        metres(shade_len_m) * cos(radians(:'building_shade_angle_deg'::double precision)) AS dx,
        metres(shade_len_m) * sin(radians(:'building_shade_angle_deg'::double precision)) AS dy
    FROM src
),
sweep_src AS (
    SELECT * FROM shade_vector
    WHERE shade_len_m > 0 AND NOT is_convex
),
edges AS (
    SELECT
        id,
        dx,
        dy,
        ring,
        idx,
        p1,
        p2,
        (ST_Y(p2) - ST_Y(p1)) * dx + (ST_X(p1) - ST_X(p2)) * dy > 0 AS facing
    FROM (
        SELECT
            v.id,
            v.dx,
            v.dy,
            s.path[1] AS ring,
            s.path[2] AS idx,
            ST_StartPoint(s.geom) AS p1,
            ST_EndPoint(s.geom) AS p2
        FROM sweep_src v
        CROSS JOIN LATERAL ST_DumpSegments(v.geom) s
    ) segments
),
edge_chains AS (
    -- number the runs of consecutive facing edges per ring
    SELECT
        *,
        SUM(CASE WHEN facing AND NOT COALESCE(prev_facing, false) THEN 1 ELSE 0 END)
            OVER (PARTITION BY id, ring ORDER BY idx) AS chain
    FROM (
        SELECT *, LAG(facing) OVER (PARTITION BY id, ring ORDER BY idx) AS prev_facing
        FROM edges
    ) e
),
chain_lines AS (
    SELECT
        id,
        dx,
        dy,
        ST_MakeLine(array_agg(p1 ORDER BY idx) || (array_agg(p2 ORDER BY idx DESC))[1]) AS geom
    FROM edge_chains
    WHERE facing
    GROUP BY id, dx, dy, ring, chain
),
pieces AS (
    SELECT id, geom FROM sweep_src
    UNION ALL
    SELECT id, ST_Translate(geom, dx, dy) FROM sweep_src
    UNION ALL
    SELECT
        id,
        ST_MakePolygon(ST_AddPoint(ST_MakeLine(geom, ST_Reverse(ST_Translate(geom, dx, dy))), ST_StartPoint(geom)))
    FROM chain_lines
)
SELECT height, geom
FROM shade_vector
WHERE shade_len_m <= 0
UNION ALL
SELECT height, ST_ConvexHull(ST_Collect(geom, ST_Translate(geom, dx, dy)))
FROM shade_vector
WHERE shade_len_m > 0 AND is_convex
UNION ALL
SELECT
    sweep_src.height,
    ST_MakeValid(ST_UnaryUnion(ST_Collect(pieces.geom))) AS geom
FROM pieces
JOIN sweep_src USING (id)
GROUP BY sweep_src.id, sweep_src.height;

CREATE INDEX building_shade_geom_idx ON building_shade USING GIST (geom);


-- 3) Create building footprint outlines (the outlines of building areas that are connected to the ground) and derive whether they are covered by floating building parts or not

-- Step A: Create building footprints
CREATE TEMP TABLE temp_building_footprints AS
SELECT (ST_Dump(ST_SetSRID(ST_CollectionExtract(ST_MakeValid(ST_CoverageUnion(geom)), 3), :building_srid))).geom AS geom
FROM temp_parts_single
WHERE floating IS false
GROUP BY cluster_id;

CREATE INDEX temp_building_footprints_geom_idx ON temp_building_footprints USING GIST (geom);
ANALYZE temp_building_footprints;

-- Step B: Prepare building "footlines" (outlines of the footprints)
CREATE TEMP TABLE temp_building_footlines AS
SELECT ROW_NUMBER() OVER () AS id, geom
FROM (
    SELECT (ST_DumpSegments(geom)).geom AS geom
    FROM temp_building_footprints
) segments;

ALTER TABLE temp_building_footlines ADD COLUMN covered BOOLEAN DEFAULT false;

CREATE INDEX temp_building_footlines_geom_idx ON temp_building_footlines USING GIST (geom);
ANALYZE temp_building_footlines;

-- Step C: Spatial query to distinguish covered from uncovered lines
CREATE TEMP TABLE temp_building_dissolved AS
SELECT geom, ST_Boundary(geom) AS boundary
FROM (
    SELECT (ST_Dump(ST_SetSRID(ST_CollectionExtract(ST_MakeValid(ST_CoverageUnion(geom)), 3), :building_srid))).geom AS geom
    FROM temp_parts_single
    GROUP BY cluster_id
) dissolved;

ANALYZE temp_building_dissolved;

-- Most candidate segments lie exactly on the polygon boundary, where ST_Contains can't use its prepared fast path
-- and computes a full relate. A cheap (prepared) midpoint test with a minimum distance to the boundary leaves only
-- interior candidates for the exact test. The polygon must be the outer side of the lateral join to stay prepared;
-- OFFSET 0 keeps the planner from flattening the subquery.
-- The ids are collected in a separate (analyzed) table, as the planner underestimates the subquery result
-- and would otherwise pick a nested loop for the update.
CREATE TEMP TABLE temp_building_footlines_covered AS
SELECT footline.id
FROM temp_building_dissolved dissolved
CROSS JOIN LATERAL (
    SELECT temp_building_footlines.id, temp_building_footlines.geom
    FROM temp_building_footlines
    WHERE
        temp_building_footlines.geom && dissolved.geom
        AND ST_Contains(dissolved.geom, ST_LineInterpolatePoint(temp_building_footlines.geom, 0.5))
        AND NOT ST_DWithin(dissolved.boundary, ST_LineInterpolatePoint(temp_building_footlines.geom, 0.5), 1e-6)
    OFFSET 0
) footline
WHERE ST_Contains(dissolved.geom, footline.geom);

ANALYZE temp_building_footlines_covered;

UPDATE temp_building_footlines
SET covered = true
FROM temp_building_footlines_covered covered
WHERE temp_building_footlines.id = covered.id;

-- Step D: Add building separation lines ("walls" between buildings) to footlines
CREATE TEMP TABLE temp_building_outlines AS
SELECT (ST_DumpSegments(ST_Union(ST_Boundary(geom)))).geom AS geom
FROM building
WHERE building IS NOT NULL;

CREATE INDEX temp_building_outlines_geom_idx ON temp_building_outlines USING GIST (geom);
ANALYZE temp_building_outlines;

-- same two-stage containment test as in step C
INSERT INTO temp_building_footlines (geom)
SELECT outline.geom
FROM (
    SELECT geom, ST_Boundary(geom) AS boundary
    FROM temp_building_footprints
) footprint
CROSS JOIN LATERAL (
    SELECT temp_building_outlines.geom
    FROM temp_building_outlines
    WHERE
        temp_building_outlines.geom && footprint.geom
        AND ST_Contains(footprint.geom, ST_LineInterpolatePoint(temp_building_outlines.geom, 0.5))
        AND NOT ST_DWithin(footprint.boundary, ST_LineInterpolatePoint(temp_building_outlines.geom, 0.5), 1e-6)
    OFFSET 0
) outline
WHERE ST_Contains(footprint.geom, outline.geom);

-- Step E: Dissolve footlines by covered status, store in persistent table
DROP TABLE IF EXISTS building_lines;

CREATE TABLE building_lines AS
SELECT
    CASE
        WHEN covered = true THEN 'footline_covered'
        ELSE 'footline_uncovered'
    END AS class,
    -- the segments are already free of duplicates (footprints don't share edges, separators lie inside them), so no union is needed
    (ST_Dump(ST_LineMerge(ST_Collect(geom)))).geom AS geom
FROM temp_building_footlines
GROUP BY covered;


-- 4) Add all lines to the persistent building lines layer that are interesting for building rendering:
--    - footprints (covered and non-covered) – already included (see above)
--    - building part outlines
--    - roof ridges and edges

-- Step A: Insert building part outlines (the noded "blade" from step 2A equals the union of all face boundaries)
INSERT INTO building_lines (class, geom)
SELECT 'part_outline' AS class, (ST_Dump(geom)).geom
FROM temp_edges;

-- Step B: Insert roof lines (roof ridges and edges from separate table)
INSERT INTO building_lines (class, geom)
SELECT class, geom FROM roof_line;

END; -- delete temporary tables

CREATE INDEX building_lines_geom_idx ON building_lines USING GIST (geom);

-- original tables no longer required
DROP TABLE IF EXISTS roof_line;
-- DROP TABLE IF EXISTS building;
