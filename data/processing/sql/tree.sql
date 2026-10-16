-- Interpolate forest trees via a hexagonal grid in forest/wood/trees areas.
-- Generated points are inserted into the shared "tree" table (source = forest_generated).
-- Grid cells that already contain an OSM tree (source = osm_feature) are skipped.

-- Parameters: processing/sql/params/params.sql

\i 'processing/sql/params/params.sql'


BEGIN;

----------------------------------------------------------------------
-- 1) Generate virtual tree points in forest areas
----------------------------------------------------------------------

-- Step A: Shrink forest areas; size_factor for crowns, dampened for grid
CREATE TEMP TABLE temp_forest_shrinked ON COMMIT DROP AS
SELECT
    leaf_type,
    area,
    size_factor,
    :'tree_forest_grid_m'::double precision
        * (1.0 + (size_factor - 1.0) * :'tree_forest_grid_size_factor'::double precision)
        AS grid_size_m,
    geom
FROM (
    SELECT
        leaf_type,
        area,
        CASE
            WHEN area >= :'tree_forest_area_large_m2'::double precision
                THEN :'tree_forest_size_factor_large'::double precision
            WHEN area >= :'tree_forest_area_medium_m2'::double precision
                THEN 1.0
            ELSE :'tree_forest_size_factor_small'::double precision
        END AS size_factor,
        geom
    FROM (
        SELECT
            leaf_type,
            ST_Area(geom) / (metres(1) * metres(1)) AS area,
            ST_Buffer(
                geom,
                metres(-1.0 * :'tree_forest_edge_shrink_m'::double precision),
                'quad_segs=2'
            ) AS geom
        FROM landuse
        WHERE "class" IN ('forest', 'wood', 'trees')
    ) s
) f
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);

CREATE INDEX temp_forest_shrinked_geom_idx ON temp_forest_shrinked USING GIST (geom);

-- Step B: OSM trees inside (shrunk) forests only — small set for the occupancy check
CREATE TEMP TABLE temp_tree_osm_forest ON COMMIT DROP AS
SELECT t.geom
FROM tree t
WHERE t.source = 'osm_feature'
  AND t."natural" = 'tree'
  AND EXISTS (
      SELECT 1
      FROM temp_forest_shrinked f
      WHERE f.geom && t.geom
        AND ST_Intersects(f.geom, t.geom)
  );

CREATE INDEX temp_tree_osm_forest_geom_idx ON temp_tree_osm_forest USING GIST (geom);

-- Step C: Hexagonal grid per forest (spacing = grid_m × (1 + (size_factor - 1) × dampen))
-- Seed from the original hexagon centroid (stable for unchanged interior cells).
CREATE TEMP TABLE temp_grid_clipped ON COMMIT DROP AS
SELECT
    row_number() OVER () AS gid,
    f.leaf_type,
    f.area,
    f.size_factor,
    f.grid_size_m,
    (
        abs(hashtext(ST_AsText(ST_Centroid(g.geom))))::bigint % 2147483646 + 1
    )::integer AS seed,
    ST_Intersection(g.geom, f.geom) AS geom
FROM temp_forest_shrinked f
CROSS JOIN LATERAL ST_HexagonGrid(metres(f.grid_size_m), f.geom) AS g
WHERE ST_Intersects(g.geom, f.geom);

CREATE INDEX temp_grid_clipped_geom_idx ON temp_grid_clipped USING GIST (geom);
CREATE INDEX temp_grid_clipped_gid_idx ON temp_grid_clipped (gid);
-- Step E: Occupied cells — join from the few forest OSM trees into the grid (GiST),
--         not the other way around (avoids probing every empty cell).
CREATE TEMP TABLE temp_occupied_gids ON COMMIT DROP AS
SELECT DISTINCT g.gid
FROM temp_tree_osm_forest t
JOIN temp_grid_clipped g
  ON t.geom && g.geom
 AND ST_Intersects(t.geom, g.geom);

CREATE INDEX temp_occupied_gids_idx ON temp_occupied_gids (gid);

-- Step F: Shrink free grid cells (keep virtual trees off cell edges)
CREATE TEMP TABLE temp_grid_free_shrinked ON COMMIT DROP AS
SELECT
    g.leaf_type,
    g.area,
    g.size_factor,
    g.seed,
    ST_Buffer(
        g.geom,
        metres(-1.0 * g.grid_size_m * :'tree_forest_cell_shrink_frac'::double precision),
        'quad_segs=1'
    ) AS geom
FROM temp_grid_clipped g
LEFT JOIN temp_occupied_gids o ON o.gid = g.gid
WHERE o.gid IS NULL
  AND g.geom IS NOT NULL
  AND NOT ST_IsEmpty(g.geom);

-- Step G: One seeded point per free cell + stable leaf_type / crown diameter
CREATE TEMP TABLE temp_tree_forest_generated ON COMMIT DROP AS
SELECT
    'tree'::text AS "natural",
    CASE
        WHEN leaf_type IN ('broadleaved', 'needleleaved') THEN leaf_type
        WHEN leaf_type = 'mixed' THEN
            CASE
                WHEN (seed % 1000) / 1000.0
                    < :'tree_forest_mixed_needleleaved_frac'::double precision
                THEN 'needleleaved'
                ELSE 'broadleaved'
            END
        ELSE
            CASE
                WHEN ((seed / 1000) % 1000) / 1000.0
                    < :'tree_forest_unknown_needleleaved_frac'::double precision
                THEN 'needleleaved'
                ELSE 'broadleaved'
            END
    END AS leaf_type,
    ROUND(
        (
            size_factor * (
                ((seed / 17) % 10000) / 10000.0 * (
                    :'tree_forest_crown_max_m'::double precision
                    - :'tree_forest_crown_min_m'::double precision
                ) + :'tree_forest_crown_min_m'::double precision
            )
        )::numeric,
        1
    ) AS diameter_crown,
    (ST_Dump(ST_GeneratePoints(geom, 1, seed))).geom AS geom
FROM temp_grid_free_shrinked
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom);


----------------------------------------------------------------------
-- 2) Insert into tree
----------------------------------------------------------------------

-- Step A: insert into shared tree table
INSERT INTO tree (
    osm_type,
    osm_id,
    "natural",
    leaf_type,
    ref,
    diameter_crown,
    height,
    circumference,
    genus,
    source,
    geom
)
SELECT
    'F',  -- synthetic; not an OSM object type (N/W/R)
    -row_number() OVER (),  -- synthetic negative id (osm2pgsql keeps osm_id NOT NULL)
    g."natural",
    g.leaf_type,
    NULL,
    g.diameter_crown,
    ROUND((g.diameter_crown / 0.6)::numeric, 1),
    ROUND((g.diameter_crown / 7.6)::numeric, 1),
    NULL,
    'forest_generated',
    g.geom
FROM temp_tree_forest_generated g
WHERE g.geom IS NOT NULL
  AND NOT ST_IsEmpty(g.geom);

COMMIT;
