//! Approximate fill/stroke colours for the `full-approx` paint stack.
//!
//! Flat SimpleFill / SimpleLine base colours; RasterFill overlays via `textures` + `paint`.
//! SVG, labels, and full QGIS effect stacks remain deferred.
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

/// QGIS `pitch` fill CASE on `surface:colour` / `surface` / `sport`.
pub fn fill_for_pitch(
    surface_colour: Option<&str>,
    surface: Option<&str>,
    sport: Option<&str>,
) -> Color {
    let colour = surface_colour.unwrap_or("").to_ascii_lowercase();
    if colour.contains("red") {
        return hex("#dbc1b9");
    }
    if colour.contains("green") {
        return hex("#b5daa9");
    }
    if colour.contains("blue") {
        return hex("#c3c1d7");
    }
    if colour.contains("gray") || colour.contains("grey") {
        return hex("#c6c9c1");
    }
    if colour.contains("yellow") {
        return hex("#e3e6c0");
    }
    let surface = surface.unwrap_or("");
    match surface {
        "asphalt" | "compacted" | "concrete" | "fine_gravel" | "gravel" | "paved"
        | "paving_stones" | "pebblestone" => return hex("#c6c9c1"),
        _ => {}
    }
    if surface.contains("grass") {
        return hex("#b5daa9");
    }
    if surface.contains("sand") {
        return hex("#e3e6c0");
    }
    if sport == Some("table_tennis") {
        return hex("#c6c9c1");
    }
    fill_pitch()
}

/// `pitch surface` uses the same texture table as `landuse surface`.
pub fn pitch_surface_texture(surface: &str) -> Option<(&'static str, f32)> {
    landuse_surface_texture(surface)
}

/// Map `pitch_markings.sport` (+ hoops / dist_long) → SVG stem in `style/textures/pitches/`.
pub fn pitch_marking_svg_stem(sport: Option<&str>, hoops: Option<&str>, dist_long: Option<f32>) -> Option<&'static str> {
    let sport = sport.unwrap_or("");
    if sport.contains("multi") {
        return Some("multi");
    }
    if sport.contains("soccer") {
        return if dist_long.unwrap_or(0.0) > 50.0 {
            Some("soccer")
        } else {
            Some("soccer_small")
        };
    }
    if sport.contains("basketball") || sport.contains("streetball") {
        return if hoops == Some("2") {
            Some("basketball_2")
        } else {
            Some("basketball_1")
        };
    }
    if sport.contains("tennis") && !sport.contains("table_tennis") {
        return Some("tennis");
    }
    if sport.contains("volleyball") {
        return Some("volleyball");
    }
    if sport.contains("badminton") {
        return Some("badminton");
    }
    if sport.contains("handball") {
        return Some("handball");
    }
    if sport.contains("field_hockey") {
        return Some("field_hockey");
    }
    if sport.contains("rugby_league") {
        return Some("rugby_league");
    }
    if sport.contains("rugby_union") {
        return Some("rugby_union");
    }
    if sport.contains("chess") {
        return Some("chess");
    }
    None
}

pub fn fill_water() -> Color {
    hex("#cac7ed")
}

pub fn stroke_waterway() -> Color {
    hex("#b2abe0")
}

pub fn fill_building() -> Color {
    // QGIS building_parts_dissolved_height SimpleFill `#ffe9e9` (no shapeburst).
    hex("#ffe9e9")
}

/// CSS / QGIS named colours for `road_marking_polygon.colour` (surface_colour / crossing).
/// Green special-cased like QGIS (`#00c503`); others follow CSS names.
pub fn surface_colour(name: Option<&str>) -> Option<Color> {
    let n = name?.trim().to_ascii_lowercase();
    if n.is_empty() || n == "no" || n == "none" {
        return None;
    }
    let h = match n.as_str() {
        "green" => "#00c503",
        "red" => "#ff0000",
        "yellow" => "#ffd52b",
        "blue" => "#1f78b4",
        "orange" => "#ff7f00",
        "white" => "#ffffff",
        "black" => "#000000",
        _ if n.starts_with('#') && n.len() == 7 => return parse_hex_color(&n).ok(),
        _ => return None,
    };
    Some(hex(h))
}

#[allow(dead_code)] // QGIS shade fill unused while drawSource is off (shadow-only).
pub fn fill_building_shade() -> Color {
    hex("#232323")
}

pub fn fill_tree_crown() -> Color {
    // Soft light canopy green (QGIS RasterMarker averages to this when downscaled).
    hex("#a4c47a")
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

/// QGIS rule-based class fills for `highway_area` (SimpleFill base under RasterFill overlay).
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

/// `highway_area` RasterFill overlay (`vector/src/style/layers/streets.ts`).
/// Opacities slightly under QGIS XML — Bicubic sampling of high-contrast sett/asphalt
/// PNGs otherwise reads as coarse dither vs Qt's softer downscale.
pub fn highway_surface_texture(surface: &str) -> Option<(&'static str, f32)> {
    match surface {
        "asphalt" => Some(("surface/asphalt", 0.018)),
        "concrete" => Some(("surface/concrete", 0.28)),
        "concrete:plates" => Some(("surface/concrete", 0.28)),
        "paving_stones" => Some(("surface/paving_stones", 0.08)),
        "sett" => Some(("surface/sett", 0.028)),
        _ => None,
    }
}

/// `landuse surface` RasterFill (`vector/src/style/colors.ts` SURFACE_PATTERNS).
pub fn landuse_surface_texture(surface: &str) -> Option<(&'static str, f32)> {
    match surface {
        "artificial_turf" | "asphalt" | "rubber" | "rubbercrumb" | "tartan" => {
            Some(("surface/asphalt", 0.025))
        }
        "clay" | "compacted" | "dirt" | "earth" | "fine_gravel" | "gravel" | "ground" | "sand" => {
            Some(("sand", 0.06))
        }
        "concrete" | "concrete:plates" => Some(("surface/concrete", 0.12)),
        "grass" => Some(("grass", 0.04)),
        "paving_stones" => Some(("surface/paving_stones", 0.05)),
        "sett" => Some(("surface/sett", 0.035)),
        "woodchips" => Some(("woodchips", 0.08)),
        _ => None,
    }
}

/// Class-based landuse RasterFill (grass/gravel on parks/forest — no `surface` tag).
pub fn landuse_class_texture(class: &str) -> Option<(&'static str, f32)> {
    match class {
        "park" | "allotments" | "cemetery" => Some(("grass", 0.04)),
        "grass" | "recreation_ground" | "village_green" | "flowerbed" | "tree_pit"
        | "greenery" | "dog_park" | "biergarten" | "bbq" => Some(("grass", 0.04)),
        "forest" | "wood" | "trees" | "scrub" | "shrub" | "shrubbery" => Some(("grass", 0.06)),
        "meadow" | "heath" | "orchard" | "grassland" | "vineyard" | "plant_nursery"
        | "greenhouse_horticulture" => Some(("grass", 0.04)),
        "playground" | "fitness_station" | "miniature_golf" | "traffic_park" => {
            Some(("grass", 0.04))
        }
        "gravel" | "scree" | "shingle" | "bare_rock" | "rock" | "blockfield" => {
            Some(("gravel", 0.06))
        }
        "sand" | "beach" | "dune" | "shoal" => Some(("sand", 0.06)),
        "woodchips" => Some(("woodchips", 0.08)),
        _ => None,
    }
}
