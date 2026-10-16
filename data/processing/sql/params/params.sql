-- params.sql — Central psql variables for the data preparation pipeline.
-- Include at the start of each script:
--   \i 'processing/sql/params/params.sql'
-- Paths are relative to the data/ working directory (see data_preparation.sh).
--
-- Distance / width values below are ground metres (true distance on Earth).
-- Under EPSG:3857, geometric operations must convert them via metres()
-- (see processing/sql/helper/metres.sql and crs_scale.sql). Attribute
-- comparisons stay in ground metres; line_offset applies metres() internally.
--
-- Structure (matches data_preparation.sh where applicable):
--   1) Lanes
--   2) Road markings
--   3) Highway areas
--   4) One-way lines
--   5) Trees / forests
--   6) Buildings


-- =============================================================================
-- 1) LANES
-- =============================================================================

-- Lane geometry (width, offset, count, markings) is computed at osm2pgsql
-- import in lanes.lua, not in SQL.
--
-- Default widths (m):
--   lane_width_default                     3    -- motorized vehicle lanes; also highway=service with service=* except alley
--   lane_width_default_motorway            3.5  -- motorway / motorway_link (incl. construction=*)
--   lane_width_default_bothways            5    -- unmarked two-way road, single shared lane (incl. highway=service without service=* or service=alley)
--   cycleway_width_default                 1.5
--   cycleway_width_default_two_way         2
--   path_width_default                     2
--   crossing_width_default_footway         5    -- same numeric as SQL crossing_default_width
--   crossing_width_default_footway_zebra   4    -- same as SQL crossing_default_width_zebra
--   crossing_width_default_cycleway        1.5
--   parking_width_parallel_default         2
--   parking_width_diagonal_default         4.5
--   parking_width_perpendicular_default    5
--   width:effective redistribution floor   2    -- min m per default vehicle/bus lane
--
-- Default lane counts when lanes=* is untagged:
--   primary/secondary + oneway     2 forward
--   primary/secondary + two-way    2 forward + 2 backward
--   other oneway                   1
--   unmarked two-way               1 both_ways (shared)
--   marked two-way                 1 forward + 1 backward

-- lanes_spread_y_junctions.sql
-- max heading difference (deg) trunk→branch; both branches must pass (0/360 wrap via cos)
\set lanes_spread_y_max_angle_deg 60

-- lanes_connectivity.sql

\set lanes_connectivity_max_dist 5.0
-- max distance (m) for endpoint proximity when lane counts differ
\set lanes_connectivity_close_threshold 1.5
-- max width difference (m) between connected lane candidates
\set lanes_connectivity_max_width_diff 0.5
-- dual_carriageway ↔ shared carriageway of the same street: lane widths
-- often jump at the split (one wide dual lane vs. two narrower two-way
-- lanes), so width/distance filters are relaxed
\set lanes_connectivity_max_dist_dual_single 12.0


-- =============================================================================
-- 2) ROAD MARKINGS
-- =============================================================================

-- OSM-imported road_marking=* (osm_import.lua process_road_marking), if untagged:
--   stroke    dashed  (lane_divider, crossing_edge) / solid (other line markings)
--   width     0.5 stop_line; 0.15 motorway/motorway_link Schmalstrich;
--             0.12 other lane_divider / edge_line / crossing_edge
--   colour    yellow if temporary, else white (not for traffic_sign / crossing)

-- (de) Schmalstrich — default for motorized vehicle lanes
\set narrow_stroke_width 0.12
-- (de) Breitstrich — bus; bicycle toward traffic; center_running/crossing both sides
\set wide_stroke_width 0.25
-- Autobahn (motorway / motorway_link, incl. construction=*)
\set narrow_stroke_width_motorway 0.15
\set wide_stroke_width_motorway 0.3

\set road_marking_default_colour   'white'
\set road_marking_temporary_colour 'yellow'

\set road_markings_dissolve_snap_tolerance 0.5

\set dasharray_bicycle           '1;1'
\set dasharray_bicycle_crossing  '0.5;0.25'
\set dasharray_bus              '5;1'
\set dasharray_parking          '1;1'
\set dasharray_stop_line        '0.5;0.25'
\set dasharray_edge_line        '1;1'
\set dasharray_crossing_edge    '0.5;0.25'
\set dasharray_motorway         '6;6'
\set dasharray_default          '3;3'


-- road_marking_stop_lines.sql

\set stop_line_colour           'white'
\set stop_line_colour_temporary 'yellow'
\set stop_line_stroke           'solid'
\set stop_line_width            0.5


-- road_marking_lanes_prepare.sql

\set crossing_road_trim_ref_tolerance 0.5
\set crossing_road_trim_min_length 0.5


-- road_marking_lane_divider.sql

-- DISABLED: dashed→solid at stop lines (does not match real-world practice)
-- \set lane_divider_stop_solid_max_length 10
\set junction_bicycle_dashed_whole_line_frac 0.67
\set junction_bicycle_dashed_min_fragment_length 0.3
\set junction_bicycle_motorized_lane_distance 1
\set buffer_lane_divider_min_m 0.3
\set buffer_lane_divider_min_road_overlap_frac 0.5


-- road_marking_barred_area.sql

\set barred_area_osm_feature_max_size_ratio 2
\set barred_area_osm_feature_overlap_min_frac 0.25
\set barred_area_crossing_min_fragment_length 0.3


-- road_marking_separation.sql

\set separation_buffer_k 0.25
\set separation_bollard_proximity_m 3.0
\set separation_bollard_node_spacing_m 2.0
\set separation_bollard_coverage_frac 0.3333333333


-- road_marking_crossing_edge.sql

\set cycleway_boundary_min_length 0.05


-- road_marking_arrows.sql

\set stop_line_candidate_max_dist 7.5
\set stop_line_max_end_dist 15

\set turn_arrow_spacing              12.0
\set turn_arrow_spacing_motorway     24.0
\set turn_arrow_start_offset          7.5
\set turn_arrow_min_dist_from_end     5.0
\set turn_arrow_min_dist_from_start   2.5
\set turn_arrow_length                5.0
\set turn_arrow_length_motorway       7.0
\set turn_arrow_length_bicycle        1.2


-- road_marking_nodes.sql

\set traffic_sign_default_width       2
\set traffic_sign_distortion_factor   2
\set road_marking_node_lane_search_m 10


-- road_marking_colour.sql

\set lane_colour_edge_inset 0.125


-- road_marking_restriction.sql

\set zigzag_side_clip_buffer_m 0.15
\set zigzag_snap_min_m 0.15
\set zigzag_snap_max_m 0.8


-- road_marking_crossing.sql

\set crossing_default_width 5
\set crossing_default_width_zebra 4
\set crossing_extend 5
\set crossing_min_length 1.25
\set crossing_merge_angle_tolerance 45
\set crossing_edge_osm_skip_extra 1
\set crossing_clip_side_extra 0.25
\set crossing_anchor_window 1.5

\set crossing_stripe_spacing 1.0
\set crossing_stripe_width 0.5
\set crossing_stripe_length_extra 1.0


-- road_marking_buffer_marking.sql

\set buffer_marking_back_edge_length 6.5
\set buffer_marking_front_edge_length 5.5
\set buffer_marking_depth 2.5
\set buffer_marking_osm_feature_overlap_max_m2 4.0
-- max angle (degrees) between an existing path/footway segment and the target side
-- direction for it to be used as the crossing ray on that side (else generic fallback)
\set buffer_marking_side_match_angle_max 45
-- max undirected angle (degrees) between a lane and road_azimuth for the lane to be
-- considered "parallel" (i.e. a bicycle lane running alongside the road, not crossing it)
\set buffer_marking_bicycle_azimuth_tolerance 25
-- length (m) of the search line projected from the reference point toward the road,
-- used to locate the bicycle lane edge when relocating the reference point
\set buffer_marking_bicycle_search_length 5.0
-- fallback total width (m) of the pedestrian "tunnel" cut out of a buffer marking where
-- a crossing line passes through it, used when the crossing way has no mapped width.
-- Like a mapped width, only half of this value is used as the ST_Buffer radius.
\set buffer_marking_footway_cutout_default_width 1.5
-- rendered size (m) of the footway symbol point placed in the cutout tunnel
\set buffer_marking_footway_symbol_length 1.05
\set buffer_marking_footway_symbol_width 0.65


-- =============================================================================
-- 3) HIGHWAY AREAS
-- =============================================================================

-- osm_import.lua highway.type grouping (not the OSM highway=* value):
--   motorway  ← motorway, motorway_link, trunk, trunk_link
--   road      ← primary…pedestrian, road
--   service   ← service, track, bus_guideway, busway, escape, raceway
--   path      ← path, footway, cycleway, bridleway, steps, corridor, via_ferrata
-- use_area_highway = true  -- mapped area:highway polygons are imported

-- highway_area_direction.sql

\set area_direction_road_search_m 20


-- highway_area_parking_class.sql

\set parking_class_highway_search_m 30


-- tunnel_entrance.sql — trapezoid depth is independent of portal width,
-- but depends on type (road/motorway, service, path, railway)

-- wing length (m) from the portal line outward, away from the tunnel
\set tunnel_entrance_depth_road 4
\set tunnel_entrance_depth_service 2
\set tunnel_entrance_depth_path 2
\set tunnel_entrance_depth_railway 4
-- generic railway portal width (m); no area:railway
\set tunnel_entrance_railway_width 5
-- flare of each wing away from the portal-line normal (degrees);
-- 0 = legs exactly 90° to the tunnel line in map space
\set tunnel_entrance_flare_deg 0
-- extra half-width (m) so the 5-point ring reaches the kerb without clipping
\set tunnel_entrance_kerb_overlap_m 0.1
-- minimum shared area:highway edge length (m) to use as the portal line
\set tunnel_entrance_shared_min_length 1.0
-- highway_area end-cap vs generic width: keep if within these factors
\set tunnel_entrance_area_width_min_factor 0.5
\set tunnel_entrance_area_width_max_factor 1.5
-- max angle (deg) between an area:highway boundary segment and the road
-- perpendicular; larger → longitudinal kerb edges are ignored
\set tunnel_entrance_area_edge_max_az_diff_deg 45


-- road_marking_parking.sql

\set parking_outline_min_length 0.05
\set parking_symbol_parallel_angle_deg 25
\set parking_symbol_road_search_m 30


-- street_parking.sql — snap street-parking lines to carriageway outer edges
-- (lines from separately mapped parking areas are excluded)

-- max distance (m) from a test/vertex point to a carriageway edge
\set street_parking_snap_max_m 5
-- min share of near test points required before snapping
\set street_parking_snap_min_coverage 0.8
-- max spacing (m) of proximity-test points along a parking line
\set street_parking_test_spacing_m 4
-- minimum number of proximity-test points (including both endpoints)
\set street_parking_test_min_points 5
-- buffer (m) when subtracting neighbour polygons from a boundary
\set street_parking_edge_eps_m 0.05
-- join kerb pieces whose end points are closer than this (m); must exceed 2 × edge_eps_m
\set street_parking_edge_bridge_m 0.2
-- vertex densification (m) before projecting onto an edge
\set street_parking_sample_m 1
-- simplify (m) after snap, before kink detection
\set street_parking_simplify_m 0.1
-- split snapped lines where azimuth turns more than this (degrees)
\set street_parking_split_angle_deg 30
-- max undirected angle (deg) between a segment and the original line at its nearest point
\set street_parking_parallel_max_deg 30
-- half-window (m) for the original-line azimuth around the nearest point
\set street_parking_parallel_az_window_m 0.01
-- staggered: packet size along the merged highway (cars)
\set street_parking_staggered_group_n_min 3
\set street_parking_staggered_group_n_max 7
-- staggered: tube width (m) from the highway toward a parking side
\set street_parking_staggered_tube_m 10
-- nearest-highway search (m) for layer fallback, road_left, and missing road_oneway
\set street_parking_layer_search_m 15

-- street_parking_point.sql — points along parking lines (vehicle centres)
\set street_parking_point_seed 0.424242
\set street_parking_point_parallel_m 5.2
\set street_parking_point_diagonal_m 3.1
\set street_parking_point_perpendicular_m 2.5
\set street_parking_point_bus_m 12
\set street_parking_point_bus_end_m 6
\set street_parking_point_offset_parallel_m 1.0
\set street_parking_point_offset_diagonal_m 2.1
\set street_parking_point_offset_perpendicular_m 2.2
\set street_parking_point_diagonal_along_m 1.2
\set street_parking_point_hgv_buffer_m 8
\set street_parking_point_hgv_angle_deg 5
\set street_parking_point_hgv_prob 0.3
\set street_parking_point_landuse_buffer_m 25
-- share of all motor_vehicle points that become hgv (baseline; landuse adds more)
\set street_parking_point_base_hgv 0.08
\set street_parking_point_commercial_hgv 0.20
\set street_parking_point_industrial_hgv 0.35
\set street_parking_point_industrial_articulated 0.08
\set street_parking_point_box_length_m 4.4
\set street_parking_point_box_width_m 2.0
-- vehicle body colours (comma-separated hex) and matching integer weights
\set street_parking_point_colours '#808080,#FFFFFF,#171717,#C0C0C0,#244A73,#B52B32,#356B43,#8B7355,#D4AF37,#E87524,#805080'
\set street_parking_point_colour_weights '52,50,44,18,16,6,6,4,2,1,1'
\set street_parking_point_colour_taxi '#F0E4B2'
\set street_parking_point_colour_emergency '#469de4'
-- mix with standard road carriageway fill (QGIS highway_area road: 168,168,167)
\set street_parking_point_colour_road '#A8A8A7'
\set street_parking_point_colour_mix 0.5


-- =============================================================================
-- 4) ONEWAY LINES
-- =============================================================================

-- oneway.sql

-- punch-out radius (m) around one-way junctions and corridor ends
\set oneway_junction_buffer_m 11
-- drop leftover fragments shorter than this (m)
\set oneway_min_fragment_m 1


-- =============================================================================
-- 5) TREES / FORESTS
-- =============================================================================

-- OSM tree nodes (osm_import.lua process_tree), Berlin cadastre fit:
--   diameter_crown = height * 0.6  |  circumference * 7.6  |  age(years) * 0.2
--   circumference > 50 m ignored as implausible
--   crown rotation ±20° in QGIS (rand seed from tid / position), not in DB
--   forest points / mixed leaf_type / crown size: cell-hash-stable in tree.sql

-- tree.sql — interpolate tree points in forest/wood/trees areas

-- Shrink forest polygons inward so generated trees stay off the edge (m)
\set tree_forest_edge_shrink_m 1.5
-- Shrink clipped grid cells before placing a point (fraction of grid size)
\set tree_forest_cell_shrink_frac 0.2

-- Size classes by forest area (ground m²): small | medium (≥ this) | large (≥ this)
\set tree_forest_area_medium_m2 15000
\set tree_forest_area_large_m2 100000

-- Hexagon grid base edge length (m) for medium forests
\set tree_forest_grid_m 6
-- Dampens size_factor deviation for grid: grid = grid_m * (1 + (size_factor - 1) * this).
-- Crowns scale fully with size_factor, grid only partially — so larger forests still look denser.
\set tree_forest_grid_size_factor 0.67

-- Crown diameter base range (m) for medium forests; small/large scale via factors
\set tree_forest_crown_min_m 8.0
\set tree_forest_crown_max_m 17.0
\set tree_forest_size_factor_small 0.85
\set tree_forest_size_factor_large 1.25

-- leaf_type probabilities when forest leaf_type is mixed / unknown
\set tree_forest_mixed_needleleaved_frac 0.33
\set tree_forest_unknown_needleleaved_frac 0.1


-- =============================================================================
-- 6) BUILDINGS
-- =============================================================================

-- building.sql — shade: base + (max - base) * (1 - exp(-max(height - offset, 0) / scale))

-- Minimum shade length (m) at/below height offset
\set building_shade_base_m 0.0
-- Asymptotic maximum shade length (m)
\set building_shade_max_m 7.5
-- Height (m) below which shade length stays at base (no extrude growth)
\set building_shade_height_offset_m 5.0
-- Characteristic height (m) above offset: ~63% of (max - base) reached at offset + this
\set building_shade_height_scale_m 20.0
-- Extrude direction (degrees; 0 = east, 90 = north → 45 = northeast / sun from SW)
\set building_shade_angle_deg 40


-- =============================================================================
-- 7) RAILWAY
-- =============================================================================

-- node_railway_direction.sql — along-track walk from railway=buffer_stop
-- in each direction, looking for a track end. A switch aborts that direction.

-- Maximum walk length (m, along the rails, not straight-line)
\set railway_buffer_stop_end_walk_m 50
