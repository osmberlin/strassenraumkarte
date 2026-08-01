//! Approximate fill/stroke colours for the `full-approx` paint stack.
//!
//! Flat SimpleFill / SimpleLine only — no RasterFill textures, SVG, labels, or QGIS effects.
//! Landuse colours mirror `vector/src/style/colors.ts` (QGIS categorized). Buildings alone
//! use `#ffe9e9`; urban fabric classes stay neutral greys.

use tiny_skia::Color;

use crate::tile::parse_hex_color;

fn hex(h: &str) -> Color {
    parse_hex_color(h).expect("static palette hex")
}

/// Neutral greys for urban fabric / unknown landuse — never building pink.
const LANDUSE_GREY: &str = "#d8dacf";
const LANDUSE_GREY_COOL: &str = "#dbdde1";

/// Landuse class → fill. Unknown / residential-like → neutral grey (never `#ffe9e9`).
pub fn fill_for_landuse(class: Option<&str>) -> Color {
    let Some(c) = class else {
        return hex(LANDUSE_GREY);
    };
    let h = match c {
        // Greens / parks
        "park" | "allotments" | "cemetery" => "#dfefce",
        "grass" | "recreation_ground" | "village_green" | "flowerbed" | "tree_pit"
        | "greenery" | "dog_park" | "biergarten" | "bbq" => "#d4e3c4",
        "forest" | "wood" | "trees" | "scrub" | "shrub" | "shrubbery" => "#c4d8af",
        "meadow" | "heath" | "orchard" | "grassland" | "vineyard" | "plant_nursery"
        | "greenhouse_horticulture" => "#cedcbf",
        "playground" | "fitness_station" | "miniature_golf" | "traffic_park" => "#dce6cb",
        "garden" => "#e3d3b2",
        "woodchips" => "#e0e4d2",
        "tundra" => "#a8c399",
        "mud" => "#dfcfbb",

        // Institutions (warm beige — not building pink)
        "school" | "college" | "kindergarten" | "community_centre" | "social_facility" => {
            "#ede6e0"
        }

        // Urban fabric / paved — greys only (NEVER #ffe9e9)
        "residential" | "commercial" | "retail" | "industrial" | "garages" | "warehouse"
        | "construction" | "brownfield" | "farmland" | "farmyard" | "religious" | "hospital"
        | "clinic" | "government" | "institutional" | "education" | "mixed" | "military"
        | "railway" | "depot" | "port" | "quarry" | "landfill" | "bare_ground" | "ground"
        | "basin" | "salt_pond" => LANDUSE_GREY,
        "parking" | "car_rental" | "fire_station" | "fuel" | "garages_area" => LANDUSE_GREY_COOL,
        "outdoor_seating" => LANDUSE_GREY, // MapLibre placeholder blue; keep grey here

        // Rock / sand / water-ish
        "gravel" | "scree" | "shingle" | "bare_rock" | "rock" | "blockfield" => "#dddddd",
        "sand" | "beach" | "dune" | "shoal" => "#e3e6c0",
        "swimming_pool" | "reef" => "#cac7ed",
        "glacier" => "#e5e3ed",

        _ => LANDUSE_GREY,
    };
    hex(h)
}

pub fn fill_pitch() -> Color {
    hex("#d1d7c6")
}

pub fn fill_water() -> Color {
    hex("#cac7ed")
}

pub fn stroke_waterway() -> Color {
    hex("#b2abe0")
}

pub fn fill_building() -> Color {
    hex("#ffe9e9")
}

pub fn fill_building_shade() -> Color {
    hex("#232323")
}

pub fn fill_tree_crown() -> Color {
    hex("#6b8f4e")
}

pub fn fill_tree_trunk() -> Color {
    hex("#8d8a63")
}

pub fn stroke_service() -> Color {
    hex("#cccccc")
}

pub fn stroke_path(highway: Option<&str>) -> Color {
    let h = match highway.unwrap_or("") {
        "cycleway" => "#d2d1d2",
        "steps" => "#979c90",
        "footway" | "path" | "bridleway" => "#e1e3bd",
        "pedestrian" => "#d7d8c5",
        _ => "#e1e3bd",
    };
    hex(h)
}

/// QGIS rule-based class fills for `highway_area` (SimpleFill only; no RasterFill).
///
/// Values mirror `audit/tile-regression/HIGHWAY_AREA_RULES.md`. Classes outside
/// this set are not painted (no ELSE rule in QGIS).
pub fn fill_for_area_highway(area: Option<&str>) -> Option<Color> {
    let hex_s = match area? {
        "footway" | "path" | "steps" | "bridleway" => "#e1e3bd",
        "pedestrian" => "#d7d8c5",
        "cycleway" | "service" => "#cccccc",
        "living_street" => "#bbbbb2",
        "parking" => "#a8a8a7",
        "motorway" | "trunk" | "motorway_link" | "trunk_link" | "primary" | "primary_link"
        | "secondary" | "secondary_link" | "tertiary" | "tertiary_link" | "residential"
        | "unclassified" | "road" | "bus_guideway" | "bus_bay" | "turning_circle"
        | "turning_loop" => "#a8a8a7",
        _ => return None,
    };
    Some(hex(hex_s))
}

/// Union of QGIS class-fill `area:highway` filters (SQL `IN` list).
pub const AREA_HIGHWAY_PAINTED: &str = "(\
  'footway','path','steps','bridleway',\
  'pedestrian','cycleway','service','parking','living_street',\
  'primary','primary_link','secondary','secondary_link',\
  'tertiary','tertiary_link','residential','unclassified','road',\
  'bus_guideway','bus_bay','turning_circle','turning_loop',\
  'motorway','trunk','motorway_link','trunk_link'\
)";
