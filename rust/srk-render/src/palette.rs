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

pub fn fill_sandpit() -> Color {
    hex("#e3e6c0")
}

/// Playground equipment fills (`vector/.../furniture.ts`).
pub fn fill_playground() -> Color {
    hex("#d2c8a0")
}

pub fn stroke_playground() -> Color {
    hex("#b7916e")
}

pub fn fill_playground_climbingframe() -> Color {
    hex("#e77148")
}

pub fn stroke_playground_climbingframe() -> Color {
    hex("#232323")
}

pub fn fill_furniture_pad() -> Color {
    hex("#bfbecf")
}

pub fn stroke_fire_hydrant() -> Color {
    hex("#ff0000")
}

pub fn stroke_jelbi_ring() -> Color {
    hex("#f0d722")
}

pub fn stroke_barrier_fence() -> Color {
    hex("#505050")
}

pub fn stroke_barrier_hedge() -> Color {
    hex("#a7cd9d")
}

pub fn stroke_barrier_kerb() -> Color {
    hex("#7e7e7e")
}

pub fn stroke_barrier_palisade() -> Color {
    hex("#656565")
}

pub fn fill_barrier_polygon_hedge() -> Color {
    hex("#c7d6b8")
}

pub fn fill_barrier_polygon_planter() -> Color {
    hex("#c7d6b8")
}

pub fn fill_barrier_polygon_wall() -> Color {
    hex("#c0c0c0")
}

pub fn gate_access_fill(foot: Option<&str>) -> Color {
    match foot.unwrap_or("").trim() {
        "no" | "private" => hex("#ff0000"),
        "yes" => hex("#90ee90"),
        "permissive" | "destination" | "customers" => hex("#ffff00"),
        _ => hex("#ffffff"),
    }
}

pub fn fill_entrance_parking() -> Color {
    hex("#20ecdb")
}

pub fn stroke_entrance_parking() -> Color {
    let mut c = Color::from_rgba8(35, 0, 119, 128);
    c.set_alpha(0.5);
    c
}

pub fn fill_entrance_generic() -> Color {
    hex("#dad1d1")
}

pub fn stroke_waterway() -> Color {
    hex("#b2abe0")
}

pub fn fill_building() -> Color {
    // QGIS building_parts_dissolved_height SimpleFill `#ffe9e9` (no shapeburst).
    hex("#ffe9e9")
}

/// Road marking line colour (CSS names from PostGIS).
pub fn road_marking_colour(name: Option<&str>) -> Color {
    let n = name.unwrap_or("white").trim().to_ascii_lowercase();
    let h = match n.as_str() {
        "yellow" => "#ffd52b",
        "red" => "#e31a1c",
        "blue" => "#1f78b4",
        "orange" => "#ff7f00",
        "black" => "#232323",
        "green" => "#00c503",
        _ => "#ffffff", // white / default
    };
    hex(h)
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

pub fn stroke_landscape() -> Color {
    hex("#965220")
}

pub fn stroke_tactile() -> Color {
    hex("#d3d3d3")
}

/// Path casing: sidewalk/sidepath `#d3d3d3`, footway/informal `#979c90`.
pub fn stroke_path_casing(class: Option<&str>) -> Color {
    if matches!(class, Some("sidewalk" | "crossing" | "link")) {
        hex("#d3d3d3")
    } else {
        hex("#979c90")
    }
}

pub fn stroke_path(highway: Option<&str>, class: Option<&str>) -> Color {
    let class = class.unwrap_or("");
    // QGIS sidewalk / crossing / link → slightly lighter beige.
    if matches!(class, "sidewalk" | "crossing" | "link") {
        return hex("#ebedd6");
    }
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

/// How QGIS evaluates a RasterFill `angle` data-defined property.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureAngle {
    /// Fixed 0° (or `rand(0, 360)` in the project: not reproducible per feature, drawn unrotated).
    Zero,
    /// `"direction"` attribute; NULL falls back to the RasterFill default (0°).
    Direction,
    /// `"direction" + 45` (paving stones); NULL falls back to 0°.
    DirectionPlus45,
}

/// One QGIS RasterFill overlay as evaluated for a feature. Values transcribed from
/// `style/strassenraumkarte.qgz` (`highway_area`, `landuse`, `landuse surface`, `pitch surface`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextureRule {
    /// Key into [`crate::textures::TextureCatalog`] (`style/textures/**/*.png`).
    pub id: &'static str,
    /// Symbol `alpha` from the project XML.
    pub alpha: f32,
    /// Ground metres per texture repeat (`MapUnit × @mercator_scale`); `None` → native texture pixels.
    pub width_m: Option<f64>,
    pub angle: TextureAngle,
    /// Multiply composite (`highway_area` drawSource blend 13; `landuse surface` / `pitch surface`
    /// layer blend 6). Class overlays on `landuse` are Normal.
    pub multiply: bool,
}

impl TextureRule {
    /// Pattern rotation in degrees for a feature's `direction` attribute.
    pub fn angle_deg(self, direction: Option<f64>) -> f64 {
        match self.angle {
            TextureAngle::Zero => 0.0,
            TextureAngle::Direction => direction.unwrap_or(0.0),
            TextureAngle::DirectionPlus45 => direction.map(|d| d + 45.0).unwrap_or(0.0),
        }
    }
}

/// `"sett:length"` → ground width of the sett texture (QGIS `CASE` expression).
pub fn sett_width_m(sett_length: Option<&str>) -> f64 {
    match sett_length {
        Some("5 cm") => 6.0,
        Some("10 cm") => 8.5,
        _ => 11.0,
    }
}

/// `highway_area` surface overlays (Multiply, drawSource blend 13).
pub fn highway_surface_rule(surface: &str, sett_length: Option<&str>) -> Option<TextureRule> {
    Some(match surface {
        "concrete" | "concrete:plates" => TextureRule {
            id: "surface/concrete",
            alpha: 0.35,
            width_m: Some(3.0),
            angle: TextureAngle::Zero,
            multiply: true,
        },
        "paving_stones" => TextureRule {
            id: "surface/paving_stones",
            alpha: 0.10,
            width_m: Some(4.5),
            angle: TextureAngle::DirectionPlus45,
            multiply: true,
        },
        "sett" => TextureRule {
            id: "surface/sett",
            alpha: 0.12,
            width_m: Some(sett_width_m(sett_length)),
            angle: TextureAngle::Direction,
            multiply: true,
        },
        "asphalt" => TextureRule {
            id: "surface/asphalt",
            alpha: 0.06,
            width_m: Some(6.0),
            angle: TextureAngle::Zero,
            multiply: true,
        },
        _ => return None,
    })
}

/// `landuse surface` (layer blend Multiply). `pitch surface` shares this table.
pub fn landuse_surface_rule(surface: &str, sett_length: Option<&str>) -> Option<TextureRule> {
    let (id, alpha, width_m, angle) = match surface {
        "artificial_turf" | "asphalt" | "rubber" | "rubbercrumb" | "tartan" => {
            ("surface/asphalt", 0.06, Some(6.0), TextureAngle::Zero)
        }
        "clay" | "compacted" | "dirt" | "earth" | "fine_gravel" | "ground" | "gravel" | "sand" => {
            ("sand", 0.08, None, TextureAngle::Zero)
        }
        "concrete" | "concrete:plates" => ("surface/concrete", 0.15, Some(3.0), TextureAngle::Zero),
        "grass" => ("grass", 0.06, None, TextureAngle::Zero),
        "paving_stones" => (
            "surface/paving_stones",
            0.07,
            Some(4.5),
            TextureAngle::DirectionPlus45,
        ),
        "sett" => ("surface/sett", 0.12, Some(sett_width_m(sett_length)), TextureAngle::Zero),
        "woodchips" => ("woodchips", 0.10, Some(8.0), TextureAngle::Zero),
        _ => return None,
    };
    Some(TextureRule {
        id,
        alpha,
        width_m,
        angle,
        multiply: true,
    })
}

/// `pitch surface` uses the same surface table as `landuse surface`.
pub fn pitch_surface_rule(surface: &str, sett_length: Option<&str>) -> Option<TextureRule> {
    landuse_surface_rule(surface, sett_length)
}

const fn class_overlay(id: &'static str, alpha: f32, width_m: Option<f64>) -> TextureRule {
    TextureRule {
        id,
        alpha,
        width_m,
        angle: TextureAngle::Zero,
        multiply: false,
    }
}

const CLASS_GRASS_006: TextureRule = class_overlay("grass", 0.06, None);
const CLASS_GRASS_009: TextureRule = class_overlay("grass", 0.09, None);
const CLASS_GRAVEL_008: TextureRule = class_overlay("gravel", 0.08, None);
const CLASS_GRAVEL_008_W65: TextureRule = class_overlay("gravel", 0.08, Some(65.0));
const CLASS_SAND_008: TextureRule = class_overlay("sand", 0.08, None);
const CLASS_WOODCHIPS_010: TextureRule = class_overlay("woodchips", 0.10, Some(8.0));
const CLASS_FLOWERBED_025: TextureRule = class_overlay("flowerbed", 0.25, Some(10.0));
const CLASS_WATER_020: TextureRule = class_overlay("water", 0.20, Some(30.0));
const CLASS_WETLAND_015: TextureRule = class_overlay("wetland", 0.15, Some(30.0));

/// `landuse` class RasterFill overlays (Normal blend), drawn above the class SimpleFill.
pub fn landuse_class_rules(class: &str) -> &'static [TextureRule] {
    match class {
        "allotments" | "bbq" | "biergarten" | "cemetery" | "dog_park" | "garden" | "grass"
        | "greenery" | "park" | "recreation_ground" | "tree_pit" | "village_green" => {
            &[CLASS_GRASS_006]
        }
        "flowerbed" => &[CLASS_GRASS_006, CLASS_FLOWERBED_025],
        "forest" | "grassland" | "heath" | "meadow" | "orchard" | "plant_nursery" | "scrub"
        | "shrub" | "shrubbery" | "trees" | "tundra" | "vineyard" | "wood" => &[CLASS_GRASS_009],
        "bare_rock" | "landfill" | "quarry" | "railway" | "rock" | "scree" => &[CLASS_GRAVEL_008],
        "blockfield" | "shingle" => &[CLASS_GRAVEL_008_W65],
        "basin" | "beach" | "dune" | "sand" | "salt_pond" => &[CLASS_SAND_008],
        "woodchips" => &[CLASS_WOODCHIPS_010],
        "glacier" | "mud" | "shoal" | "swimming_pool" => &[CLASS_WATER_020],
        "reef" => &[CLASS_WATER_020, CLASS_WETLAND_015],
        _ => &[],
    }
}
