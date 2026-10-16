-- Creates separate lines for each lane by offsetting the original geometry (centerline) for each lane.
-- Performs a line transition for lanes with placement transition (placement:start/end, see https://wiki.openstreetmap.org/wiki/Tag:placement%3Dtransition)
-- "offset" and "transition" values from lanes.lua

-- Helper: offset logic takes place in vertex-based offset function:
\i 'processing/sql/helper/line_offset.sql'

DROP TABLE IF EXISTS lanes_transformed;

CREATE TABLE lanes_transformed AS
WITH

-- 0) use transformed geometry when the centerline was spread
-- (dual_carriageway or oneway Y-junctions), except placement/transition
-- segments whose offset is determined by placement tags
lanes_input AS (
    SELECT
        l.*,
        CASE
            WHEN ht.geom IS NOT NULL
             AND COALESCE(ht.transition, 0) = 0
             AND hw.geom IS NOT NULL
             AND NOT ST_Equals(ht.geom, hw.geom)
            THEN ht.geom
            ELSE l.geom
        END AS geom_overridden
    FROM lanes l
    LEFT JOIN highway hw
      ON hw.segment_id = l.segment_id
    LEFT JOIN highway_transformed ht
      ON ht.segment_id = l.segment_id
),

-- 1) prepare lines (dump multilinestrings)
base_lines AS (
    SELECT
        segment_id,
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        hierarchy,
        layer,
        "lane_markings:junction",
        "offset",
        transition,
        (ST_Dump(ST_RemoveRepeatedPoints(geom_overridden, 0))).geom
            ::geometry(LineString) AS line_geom
    FROM lanes_input
),

-- 2) Apply offset to each lane line
final_lines AS (
    SELECT
        segment_id,
        osm_id,
        highway,
        name,
        lane_index,
        type,
        class,
        direction,
        width,
        surface,
        turn,
        colour,
        marking_left,
        marking_right,
        separation_left,
        separation_right,
        buffer_left,
        buffer_right,
        traffic_mode_left,
        traffic_mode_right,
        hierarchy,
        layer,
        "lane_markings:junction",
        "offset",
        transition,
        line_offset(line_geom, "offset", transition) AS geom
    FROM base_lines
)

SELECT * FROM final_lines;

-- replace original table

-- DROP TABLE IF EXISTS lanes;
DROP TABLE IF EXISTS lanes_original;
ALTER TABLE lanes RENAME TO lanes_original;
ALTER TABLE lanes_transformed RENAME TO lanes;


-- create spatial index
DROP INDEX IF EXISTS lanes_geom_idx;
DROP INDEX IF EXISTS lanes_segment_id_idx;
CREATE INDEX lanes_geom_idx ON lanes USING GIST (geom);
CREATE INDEX lanes_segment_id_idx ON lanes (segment_id);
