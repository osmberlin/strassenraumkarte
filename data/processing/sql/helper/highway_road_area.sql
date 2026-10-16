-- highway_road_area.sql — road carriageway area:highway values (highway_road_list without pedestrian)
-- Included by road_marking_lanes_prepare.sql (§1d), road_marking_crossing.sql (§7)
-- and street_parking.sql.

DROP TABLE IF EXISTS _highway_road_area;
CREATE TEMP TABLE _highway_road_area (
    area_highway text PRIMARY KEY
);

INSERT INTO _highway_road_area (area_highway) VALUES
    ('primary'),
    ('primary_link'),
    ('secondary'),
    ('secondary_link'),
    ('tertiary'),
    ('tertiary_link'),
    ('unclassified'),
    ('residential'),
    ('living_street'),
    ('road');
