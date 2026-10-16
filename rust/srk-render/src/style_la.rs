//! Design research preset `la`: landscape-architecture site plan.
//!
//! Mission (docs/design-research/01-landscape-architecture): the open space is the subject,
//! drawn in cool sage/khaki pastels; trees are small plan drawings; buildings are calm white
//! volumes with a crisp outline and a hard SE shadow, the odd terracotta roof as accent.

use anyhow::Result;
use geo_types::Polygon;
use postgres::Client;
use tiny_skia::{BlendMode, Color, PathBuilder, Pixmap};

use crate::sql_cache::PreparedCache;
use crate::style_kit::*;
use crate::tile::RenderExtent;

#[path = "style_la_extra.rs"]
mod extra;

// Palette from the user's Pinterest board (swatch pin) + measured historic plans.
const PAPER: &str = "#EAE9E3";
const LAWN: &str = "#CBD4BC";
const MEADOW: &str = "#C2C5A6";
const SHRUB: &str = "#BDBBA4";
const WOOD_GROUND: &str = "#B8BB9E";
const SAND: &str = "#DDD6C2";
const PAVING: &str = "#E4E2DA";
const SIDEWALK: &str = "#F1F0EB";
const ROAD: &str = "#C9C5BA";
const PARKING: &str = "#DAD7CF";
const CYCLE: &str = "#D3A796";
const WATER: &str = "#A9BEBD";
const WATER_EDGE: &str = "#7E9896";
const BUILDING: &str = "#FBFAF7";
const BUILDING_LINE: &str = "#4E4D46";
const SHADOW: &str = "#6C6B5A";
const CROWNS: [&str; 6] = ["#A6A48C", "#9AA07C", "#B3B596", "#85835F", "#8E8F70", "#7C735F"];
const CROWNS_VIVID: [&str; 6] = ["#7FA05A", "#6E9150", "#93B06A", "#5C7F45", "#88A863", "#A3B776"];

/// `SRK_LA_PALETTE=vivid`: the saturated greens of modern rendered plans instead of the board's
/// sage/khaki. Only the planting tones change; paper, streets and buildings stay.
fn vivid() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var("SRK_LA_PALETTE").map(|v| v == "vivid").unwrap_or(false))
}

fn tone(c: &'static str) -> &'static str {
    if !vivid() {
        return c;
    }
    match c {
        LAWN => "#BCD39A",
        MEADOW => "#B3C68C",
        SHRUB => "#93AC72",
        WOOD_GROUND => "#9DB77F",
        "#9FAA8C" => "#8FA96A",
        _ => c,
    }
}

fn crown_palette() -> &'static [&'static str; 6] {
    if vivid() { &CROWNS_VIVID } else { &CROWNS }
}

fn landuse_colour(class: &str) -> Option<&'static str> {
    Some(match class {
        "grass" | "park" | "greenery" | "garden" | "recreation_ground" | "village_green" | "dog_park"
        | "cemetery" | "allotments" => LAWN,
        "meadow" => MEADOW,
        "scrub" | "flowerbed" | "tree_pit" => SHRUB,
        "forest" | "wood" => WOOD_GROUND,
        "playground" | "sand" | "bare_ground" | "ground" | "woodchips" | "gravel" | "fitness_station" => SAND,
        "parking" => PARKING,
        "school" | "kindergarten" | "community_centre" | "social_facility" | "outdoor_seating" | "biergarten" => PAVING,
        "swimming_pool" => WATER,
        _ => return None,
    })
}

fn area_highway_colour(ah: &str) -> Option<&'static str> {
    Some(match ah {
        "residential" | "secondary" | "tertiary" | "tertiary_link" | "primary" | "service" | "living_street"
        | "turning_circle" | "unclassified" => ROAD,
        "parking" | "parking_space" => PARKING,
        "footway" | "pedestrian" | "steps" | "traffic_island" => PAVING,
        "cycleway" => CYCLE,
        _ => return None,
    })
}

pub fn render(client: &mut Client, prep: &mut PreparedCache, extent: RenderExtent, z: u32) -> Result<Pixmap> {
    let mut pm = Pixmap::new(extent.width_px, extent.height_px).expect("pixmap");
    pm.fill(hex(PAPER));
    let mut ctx = Ctx { client, prep, extent, z, margin_m: 40.0 };

    // ---- ground
    let landuse = ctx.polygons(
        "osm_id AS id, class, NULL::text AS sub, ST_Area(geom)::float8 AS num",
        "landuse",
        "ORDER BY ST_Area(geom) DESC",
    )?;
    let mut green: Vec<&Polygon<f64>> = Vec::new();
    let mut shrubs: Vec<&Polygon<f64>> = Vec::new();
    let mut woods: Vec<&Polygon<f64>> = Vec::new();
    for f in &landuse {
        let Some(col) = landuse_colour(&f.class) else { continue };
        if let Some(path) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &path, &paint(hex(tone(col))), None);
        }
        match col {
            LAWN | MEADOW => green.push(&f.geom),
            SHRUB => shrubs.push(&f.geom),
            WOOD_GROUND => woods.push(&f.geom),
            _ => {}
        }
    }
    let pitches = ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "pitch", "")?;
    for f in &pitches {
        if let Some(path) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &path, &paint(hex("#C3CBB0")), None);
            line(&mut pm, &path, &paint(with_alpha(hex("#FFFFFF"), 0.8)), &stroke(ctx.m(0.12).max(0.6)), None);
        }
    }
    if let Some(p) = pitch_marking_path(&mut ctx)? {
        line(&mut pm, &p, &paint(with_alpha(Color::WHITE, 0.9)), &stroke(ctx.m(0.1).max(0.6)), None);
    }
    // watercolour mottling on green + a darker, bled rim along the edges
    if let Some(mask) = mask_of(&ctx, &green) {
        let mut rim = new_layer(&ctx);
        let rim_w = ctx.m(1.2).clamp(3.0, 12.0);
        for g in &green {
            if let Some(p) = poly_path(&ctx, g) {
                line(&mut rim, &p, &paint(hex(tone("#9FAA8C"))), &stroke(rim_w), Some(&mask));
            }
        }
        blur_layer(&mut rim, (rim_w * 0.5) as usize);
        draw_layer(&mut pm, &rim, 0.45, BlendMode::Multiply);
        apply_grain(&ctx, &mut pm, Some(&mask), 18.0, 3, 0.05, 11);
        apply_grain(&ctx, &mut pm, Some(&mask), 2.5, 2, 0.025, 12);
    }
    // shrub beds: darker edge + dabs
    if let Some(mask) = mask_of(&ctx, &shrubs) {
        let dab = with_alpha(shade(hex(tone(SHRUB)), 0.86), 0.45);
        let mut pb = PathBuilder::new();
        for (x, y, r) in world_scatter(&ctx, zcell(z, 1.6), 0.9, 21) {
            let (px, py) = ctx.extent.map_to_px(x, y);
            pb.push_circle(px, py, ctx.m(zcell(z, 0.35 + 0.35 * f64::from(r))).max(0.6));
        }
        if let Some(p) = pb.finish() {
            fill(&mut pm, &p, &paint(dab), Some(&mask));
        }
        for g in &shrubs {
            if let Some(path) = poly_path(&ctx, g) {
                line(&mut pm, &path, &paint(with_alpha(shade(hex(tone(SHRUB)), 0.7), 0.7)), &stroke(ctx.m(0.15).max(0.5)), None);
            }
        }
    }

    let water = ctx.polygons("0::bigint AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "water_body_dissolved", "")?;
    for f in &water {
        if let Some(path) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &path, &paint(hex(WATER)), None);
        }
    }
    // watercolour depth: darker towards the banks (blurred inner edge), crisp bank line on top
    let wpolys: Vec<&Polygon<f64>> = water.iter().map(|f| &f.geom).collect();
    if let Some(mask) = mask_of(&ctx, &wpolys).filter(|_| !wpolys.is_empty()) {
        let mut edge = new_layer(&ctx);
        let w = ctx.m(2.5).clamp(4.0, 24.0);
        for g in &wpolys {
            if let Some(p) = poly_path(&ctx, g) {
                line(&mut edge, &p, &paint(hex(WATER_EDGE)), &stroke(w), Some(&mask));
            }
        }
        blur_layer(&mut edge, (w * 0.45) as usize);
        draw_layer(&mut pm, &edge, 0.55, BlendMode::Multiply);
        apply_grain(&ctx, &mut pm, Some(&mask), 6.0, 2, 0.04, 77);
        for g in &wpolys {
            if let Some(p) = poly_path(&ctx, g) {
                line(&mut pm, &p, &paint(hex(WATER_EDGE)), &stroke(ctx.m(0.3).max(0.8)), None);
            }
        }
    }

    draw_railways(&mut ctx, &mut pm)?;

    // ---- streets
    let areas = ctx.polygons(
        r#"osm_id AS id, "area:highway" AS class, class AS sub, COALESCE(layer, 0)::float8 AS num"#,
        "highway_area",
        "ORDER BY COALESCE(layer,0)",
    )?;
    // ground-level street areas, then bridge decks (shadow onto rails/water/roads), then raised areas
    let mut bridges_done = false;
    for f in &areas {
        if !bridges_done && f.num >= 1.0 {
            extra::draw_bridges(&mut ctx, &mut pm)?;
            bridges_done = true;
        }
        let Some(col) = area_highway_colour(&f.class) else { continue };
        if let Some(path) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &path, &paint(hex(col)), None);
            if col == ROAD {
                line(&mut pm, &path, &paint(with_alpha(hex("#9F9B90"), 0.9)), &stroke(ctx.m(0.12).max(0.6)), None);
            } else if f.class == "parking_space" {
                line(&mut pm, &path, &paint(with_alpha(Color::WHITE, 0.9)), &stroke(ctx.m(0.1).max(0.5)), None);
            }
        }
    }
    if !bridges_done {
        extra::draw_bridges(&mut ctx, &mut pm)?;
    }
    let paths = ctx.lines(
        "osm_id AS id, highway AS class, class AS sub, COALESCE(width, 0)::float8 AS num",
        "highway WHERE type = 'path'",
        "ORDER BY COALESCE(layer,0), osm_id",
    )?;
    // park paths (not sidewalks/crossings) get a fine edge: all edges first, then all fills, so
    // junctions merge cleanly
    let is_park_path = |f: &Feature<geo_types::LineString<f64>>| f.sub != "sidewalk" && f.sub != "crossing" && f.class != "cycleway";
    if z >= 17 {
        for f in paths.iter().filter(|f| is_park_path(f)) {
            let w = if f.num > 0.0 { f.num } else { 1.8 };
            if let Some(path) = line_path(&ctx, &f.geom) {
                line(&mut pm, &path, &paint(with_alpha(hex("#B8AE94"), 0.8)), &stroke(ctx.m(w).max(0.8) + 1.2), None);
            }
        }
    }
    for f in &paths {
        let w = if f.num > 0.0 { f.num } else if f.class == "cycleway" { 1.6 } else { 1.8 };
        let col = match f.class.as_str() {
            "cycleway" => CYCLE,
            "footway" | "pedestrian" | "steps" if f.sub == "sidewalk" || f.sub == "crossing" => SIDEWALK,
            _ => "#E2DAC4",
        };
        if let Some(path) = line_path(&ctx, &f.geom) {
            line(&mut pm, &path, &paint(hex(col)), &stroke(ctx.m(w).max(0.8)), None);
        }
    }

    // bridge decks: crisp parapet edge over the street surfaces
    extra::draw_bridge_edges(&mut ctx, &mut pm)?;

    // ---- paving joints (z19+): ticks across sidewalks, fine grid on pedestrian areas
    if z >= 19 {
        let joint = paint(with_alpha(hex("#B9B5AA"), 0.55));
        let mut pb = PathBuilder::new();
        for f in paths.iter().filter(|f| f.sub == "sidewalk") {
            let w = ctx.m(if f.num > 0.0 { f.num } else { 1.8 }) * 0.5;
            let pts = line_pts(&ctx, &f.geom);
            for (x, y, a) in along(&pts, ctx.m(1.5).max(4.0), 0.0) {
                let (nx, ny) = (-a.sin(), a.cos());
                pb.move_to(x - nx * w, y - ny * w);
                pb.line_to(x + nx * w, y + ny * w);
            }
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &joint, &stroke(0.5), None);
        }
        let ped: Vec<&Polygon<f64>> = areas.iter().filter(|f| matches!(f.class.as_str(), "pedestrian" | "footway")).map(|f| &f.geom).collect();
        if let Some(mask) = mask_of(&ctx, &ped).filter(|_| !ped.is_empty()) {
            let (w, h) = (ctx.extent.width_px as f32, ctx.extent.height_px as f32);
            for ang in [0.0f32, 90.0] {
                if let Some(p) = hatch_path(&ctx, ctx.m(1.2).max(4.0), ang, 0.0, 0.0, w, h) {
                    line(&mut pm, &p, &paint(with_alpha(hex("#B9B5AA"), 0.4)), &stroke(0.5), Some(&mask));
                }
            }
        }
    }

    // ---- buildings: hard SE shadow, white volume, crisp outline, rare red roof
    // `sub` = building:part | mapped roof colour (empty when not tagged or not imported)
    let roof_sql = extra::roof_colour_sql(ctx.client);
    let buildings = ctx.polygons(
        &format!(
            r#"osm_id AS id, COALESCE(building, 'yes') AS class, COALESCE("building:part", '') || '|' || {roof_sql} AS sub,
               COALESCE(height, "building:levels" * 3.0, 9)::float8 AS num"#
        ),
        "building",
        "ORDER BY COALESCE(height, 0), osm_id",
    )?;
    let is_part = |f: &Feature<Polygon<f64>>| !f.sub.starts_with('|');
    let sh = ctx.m(2.2);
    {
        let mut layer = new_layer(&ctx);
        let mut pb = PathBuilder::new();
        for f in buildings.iter().filter(|f| !is_part(f)) {
            let off = sh * (f.num as f32 / 15.0).clamp(0.4, 1.6);
            for k in [0.33f32, 0.66, 1.0] {
                if let Some(p) = poly_path_shifted(&ctx, &f.geom, off * k, off * k * 0.75) {
                    pb.push_path(&p);
                }
            }
        }
        if let Some(p) = pb.finish() {
            fill(&mut layer, &p, &paint(hex(SHADOW)), None);
        }
        blur_layer(&mut layer, (ctx.m(0.35).max(1.0)) as usize);
        draw_layer(&mut pm, &layer, 0.34, BlendMode::Multiply);
    }
    for f in buildings.iter().filter(|f| !is_part(f)) {
        let Some(path) = poly_path(&ctx, &f.geom) else { continue };
        let r = rand01(f.id, 3);
        let landmark = matches!(f.class.as_str(), "church" | "chapel" | "cathedral" | "public" | "civic" | "school");
        let area = polygon_area_m2(&f.geom);
        let outbuilding = matches!(f.class.as_str(), "garage" | "garages" | "shed" | "roof" | "carport" | "hut" | "service" | "transformer_tower");
        let home = matches!(f.class.as_str(), "house" | "detached" | "semidetached_house" | "terrace" | "residential" | "chalet" | "allotment_house" | "bungalow");
        // red roofs: an accent on small homes only (unknown `building=yes` only when tiny)
        let red = !landmark && ((home && area < 250.0) || (f.class == "yes" && area < 120.0)) && r < 0.25;
        let mapped = f.sub.split_once('|').and_then(|(_, c)| extra::roof_tone(c));
        let col = if let Some(m) = mapped {
            m
        } else if landmark {
            "#F5F4EF"
        } else if outbuilding {
            "#DEDBD3"
        } else if red {
            if r < 0.15 { "#C98C7A" } else { "#B98270" }
        } else {
            BUILDING
        };
        fill(&mut pm, &path, &paint(hex(col)), None);
        line(&mut pm, &path, &paint(hex(BUILDING_LINE)), &stroke(ctx.m(0.22).clamp(0.7, 1.6)), None);
    }
    for f in buildings.iter().filter(|f| is_part(f)) {
        if let Some(path) = poly_path(&ctx, &f.geom) {
            line(&mut pm, &path, &paint(with_alpha(hex(BUILDING_LINE), 0.35)), &stroke(ctx.m(0.08).clamp(0.4, 0.8)), None);
        }
    }

    // road markings from the shared painters, pulled towards grey (no signal red in a site plan)
    {
        let mut t: Option<&mut crate::profile::StageTimers> = None;
        let mut layer = Pixmap::new(ctx.extent.width_px, ctx.extent.height_px).expect("pixmap");
        crate::layers::paint_road_marking_polygon(ctx.client, ctx.prep, &mut layer, ctx.extent, ctx.z, &mut t)?;
        crate::layers::paint_road_marking_way(ctx.client, ctx.prep, &mut layer, ctx.extent, ctx.z, &mut t)?;
        draw_desaturated(&mut pm, &mut layer, 0.8, 0.85);
    }

    // ---- hedges, fences, walls and street furniture (plan symbols)
    draw_details(&mut ctx, &mut pm)?;

    // ---- trees
    draw_trees(&mut ctx, &mut pm, &woods, &green)?;

    draw_area_labels(
        &mut ctx,
        &mut pm,
        &LabelStyle {
            family: "Avenir Next",
            italic: false,
            weight: 600,
            size_px: 11.5,
            letter_spacing_em: 0.28,
            uppercase: true,
            fill: "#6C6B5A",
            halo: "#E4E8DA",
            halo_px: 2.5,
            repeat_px: 0.0,
        },
        40_000.0,
        16.0,
    )?;
    extra::draw_water_labels(&mut ctx, &mut pm)?;
    if z >= 17 {
        draw_street_labels(
            &mut ctx,
            &mut pm,
            &LabelStyle {
                family: "Avenir Next",
                italic: false,
                weight: 500,
                size_px: 10.5,
                letter_spacing_em: 0.16,
                uppercase: true,
                fill: "#5F5E57",
                halo: "#F1F0EB",
                halo_px: 2.6,
                repeat_px: 520.0,
            },
        )?;
    }
    apply_grain(&ctx, &mut pm, None, 0.6, 1, 0.018, 99);
    Ok(pm)
}

fn polygon_area_m2(p: &Polygon<f64>) -> f64 {
    let c: Vec<_> = p.exterior().coords().collect();
    let mut a = 0.0;
    for w in c.windows(2) {
        a += w[0].x * w[1].y - w[1].x * w[0].y;
    }
    // Web Mercator area → rough ground area at Berlin (cos² φ ≈ 0.37)
    (a / 2.0).abs() * 0.37
}

struct Crown {
    x: f32,
    y: f32,
    r: f32,
    variant: u8,
    colour: Color,
    seed: i64,
}

fn draw_trees(ctx: &mut Ctx, pm: &mut Pixmap, woods: &[&Polygon<f64>], green: &[&Polygon<f64>]) -> Result<()> {
    // `sub` = leaf_type | name of the street the tree stands on (nearest named road within ~12 m)
    let trees = ctx.points(
        "id, class, sub, num",
        r#"(SELECT t.osm_id AS id, COALESCE(t.genus, t.leaf_type, '') AS class,
                   COALESCE(t.leaf_type, '') || '|' || COALESCE((SELECT h.name FROM highway h
                       WHERE h.type = 'road' AND h.name IS NOT NULL AND ST_DWithin(h.geom, t.geom, 20)
                       ORDER BY h.geom <-> t.geom LIMIT 1), '') AS sub,
                   COALESCE(t.diameter_crown, 0)::float8 AS num, t.geom
            FROM tree t WHERE t.geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)) q"#,
        "",
    )?;
    let mut crowns: Vec<Crown> = Vec::new();
    let mut forest: Vec<Crown> = Vec::new();
    for t in &trees {
        let (x, y) = ctx.px(t.geom.0);
        let in_wood = woods.iter().any(|p| point_in_polygon(t.geom.0, p));
        let (leaf, street) = t.sub.split_once('|').unwrap_or((t.sub.as_str(), ""));
        let street_tree = !street.is_empty() && !in_wood && !green.iter().any(|p| point_in_polygon(t.geom.0, p));
        // known genus → its own plan symbol, colour and default crown size; street trees without
        // genus → one symbol and tone per street (rows read as rows); otherwise generic by id
        let spec = extra::genus_spec(&t.class);
        let (variant, colour, default_d) = match &spec {
            Some(g) => (g.variant, hex(crown_palette()[g.colour]), g.default_d),
            None if street_tree && leaf != "needleleaved" => {
                let key = street.bytes().fold(7i64, |h, b| h.wrapping_mul(31).wrapping_add(i64::from(b)));
                let base = hex(crown_palette()[(rand01(key, 9) * 6.0) as usize % 6]);
                // small per-tree tone jitter, so the row is uniform but not stamped
                (((rand01(key, 5) * 3.0) as u8), mix(base, Color::WHITE, 0.08 * rand01(t.id, 13)), 5.5)
            }
            None => {
                let v = if leaf == "needleleaved" { 3 } else { (rand01(t.id, 5) * 3.0) as u8 };
                (v, hex(crown_palette()[(rand01(t.id, 9) * 6.0) as usize % 6]), 6.0)
            }
        };
        let d = if t.num > 0.0 { t.num } else { default_d };
        let c = Crown { x, y, r: ctx.m(d.clamp(2.0, 18.0) / 2.0), variant, colour, seed: t.id };
        if in_wood { forest.push(c) } else { crowns.push(c) }
    }
    // woodland: world-anchored scatter of crowns inside forest polygons
    if !woods.is_empty() {
        for (wx, wy, r) in world_scatter(ctx, 5.5, 0.92, 33) {
            let pt = geo_types::Coord { x: wx, y: wy };
            if !woods.iter().any(|p| point_in_polygon(pt, p)) {
                continue;
            }
            let (x, y) = ctx.extent.map_to_px(wx, wy);
            let seed = ((wx * 7.0) as i64) ^ ((wy * 13.0) as i64);
            forest.push(Crown {
                x,
                y,
                r: ctx.m(3.2 + 2.2 * f64::from(r)),
                variant: (rand01(seed, 2) * 3.0) as u8,
                colour: hex(crown_palette()[(rand01(seed, 4) * 6.0) as usize % 6]),
                seed,
            });
        }
    }
    // shadows first (multiply), then crowns big → small
    let mut pb = PathBuilder::new();
    for c in crowns.iter().chain(forest.iter()) {
        let o = c.r * 0.35;
        pb.push_circle(c.x + o, c.y + o * 0.8, c.r);
    }
    if let Some(p) = pb.finish() {
        let mut layer = new_layer(ctx);
        fill(&mut layer, &p, &paint(hex(SHADOW)), None);
        blur_layer(&mut layer, (ctx.m(0.6).max(1.5)) as usize);
        draw_layer(pm, &layer, 0.26, BlendMode::Multiply);
    }
    // woodland: crowns drawn opaque into their own layer (overlaps do not darken), then the
    // layer goes on at reduced opacity → one even canopy with visible crown structure
    if !forest.is_empty() {
        let mut layer = new_layer(ctx);
        forest.sort_by(|a, b| a.y.total_cmp(&b.y));
        for c in &forest {
            draw_crown(&mut layer, c, 2.0);
        }
        draw_layer(pm, &layer, 0.8, BlendMode::SourceOver);
    }
    crowns.sort_by(|a, b| b.r.total_cmp(&a.r));
    for c in &crowns {
        draw_crown(pm, c, 1.0);
    }
    Ok(())
}

fn draw_crown(pm: &mut Pixmap, c: &Crown, k: f32) {
    let dark = shade(c.colour, 0.72);
    let w = (c.r * 0.06).clamp(0.5, 1.2);
    let phase = rand01(c.seed, 1) * 6.28;
    match c.variant {
        // board canonical: translucent disc, thin ring, centre dot
        0 => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &sphere_paint(c, (0.55 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
        }
        // radial branches
        1 => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &paint(with_alpha(c.colour, 0.42 * k)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.6)), &stroke(w * 0.8), None);
            }
            let n = 7 + (rand01(c.seed, 6) * 4.0) as i32;
            let mut pb = PathBuilder::new();
            for i in 0..n {
                let t = phase + i as f32 / n as f32 * std::f32::consts::TAU;
                pb.move_to(c.x + c.r * 0.12 * t.cos(), c.y + c.r * 0.12 * t.sin());
                pb.line_to(c.x + c.r * 0.85 * t.cos(), c.y + c.r * 0.85 * t.sin());
            }
            if let Some(p) = pb.finish() {
                line(pm, &p, &paint(with_alpha(dark, 0.7)), &stroke(w * 0.8), None);
            }
        }
        // scalloped, two-tone
        2 => {
            let pts = scallop_pts(c.x, c.y, c.r, 9 + (rand01(c.seed, 7) * 5.0) as u32, 0.12, phase);
            if let Some(p) = pts_path(&pts, true) {
                fill(pm, &p, &sphere_paint(c, (0.62 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
        }
        4.. => extra::draw_genus_crown(pm, c, k),
        // conifer: star
        _ => {
            let n = 12;
            let pts: Vec<(f32, f32)> = (0..n * 2)
                .map(|i| {
                    let t = phase + i as f32 / (n * 2) as f32 * std::f32::consts::TAU;
                    let rr = if i % 2 == 0 { c.r } else { c.r * 0.62 };
                    (c.x + rr * t.cos(), c.y + rr * t.sin())
                })
                .collect();
            if let Some(p) = pts_path(&pts, true) {
                fill(pm, &p, &paint(with_alpha(shade(c.colour, 0.85), 0.6 * k)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.85)), &stroke(w), None);
            }
        }
    }
    if c.r > 3.0 {
        if let Some(p) = PathBuilder::from_circle(c.x, c.y, (c.r * 0.07).clamp(0.6, 1.6)) {
            fill(pm, &p, &paint(with_alpha(dark, 0.9)), None);
        }
    }
}

pub fn point_in_polygon(pt: geo_types::Coord<f64>, poly: &Polygon<f64>) -> bool {
    fn ring(pt: geo_types::Coord<f64>, r: &geo_types::LineString<f64>) -> bool {
        let c: Vec<_> = r.coords().collect();
        let mut inside = false;
        let mut j = c.len().saturating_sub(1);
        for i in 0..c.len() {
            let (a, b) = (c[i], c[j]);
            if (a.y > pt.y) != (b.y > pt.y) && pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x {
                inside = !inside;
            }
            j = i;
        }
        inside
    }
    ring(pt, poly.exterior()) && !poly.interiors().iter().any(|h| ring(pt, h))
}

fn draw_details(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    // embankments: soft shaded band on the downhill side + fine comb
    let slopes = ctx.lines("osm_id AS id, class, NULL::text AS sub, 0::float8 AS num", "landscape_way WHERE class IN ('cliff', 'embankment', 'earth_bank')", "")?;
    for f in &slopes {
        let pts = line_pts(ctx, &f.geom);
        let l = ctx.m(1.8).max(4.0);
        if let Some(p) = hachures(&pts, ctx.m(0.6).max(2.5), l) {
            line(pm, &p, &paint(with_alpha(hex("#8E8F70"), 0.55)), &stroke(0.6), None);
        }
        if let Some(p) = pts_path(&pts, false) {
            line(pm, &p, &paint(with_alpha(hex("#6C6B5A"), 0.7)), &stroke(0.8), None);
        }
    }
    let barriers = ctx.lines("osm_id AS id, barrier AS class, NULL::text AS sub, 0::float8 AS num", "barrier_way", "")?;
    let hedge = hex("#8E8F70");
    for f in &barriers {
        let pts = line_pts(ctx, &f.geom);
        match f.class.as_str() {
            "hedge" => {
                let r = ctx.m(0.6).max(1.2);
                let mut pb = PathBuilder::new();
                for (x, y, _) in along(&pts, r * 0.9, 0.0) {
                    pb.push_circle(x, y, r);
                }
                if let Some(p) = pb.finish() {
                    fill(pm, &p, &paint(with_alpha(hedge, 0.55)), None);
                    line(pm, &p, &paint(with_alpha(shade(hedge, 0.75), 0.5)), &stroke(0.5), None);
                }
            }
            "wall" | "retaining_wall" => {
                if let Some(p) = pts_path(&pts, false) {
                    line(pm, &p, &paint(hex("#7C7A70")), &stroke(ctx.m(0.3).max(1.0)), None);
                }
            }
            "fence" | "handrail" => {
                if let Some(p) = pts_path(&pts, false) {
                    line(pm, &p, &paint(with_alpha(hex("#7C7A70"), 0.8)), &stroke(ctx.m(0.06).max(0.5)), None);
                }
            }
            _ => {}
        }
    }
    extra::draw_play(ctx, pm)?;
    extra::draw_furniture(ctx, pm)?;
    Ok(())
}

/// Crown fill lit from the north-west: light cap fading into the base colour (spherical read).
fn sphere_paint(c: &Crown, alpha: f32) -> tiny_skia::Paint<'static> {
    let light = with_alpha(mix(c.colour, Color::WHITE, 0.38), alpha);
    let base = with_alpha(c.colour, alpha);
    let edge = with_alpha(shade(c.colour, 0.88), alpha);
    let mut p = paint(base);
    if let Some(sh) = tiny_skia::RadialGradient::new(
        tiny_skia::Point::from_xy(c.x - c.r * 0.35, c.y - c.r * 0.35),
        0.0,
        tiny_skia::Point::from_xy(c.x, c.y),
        c.r * 1.25,
        vec![
            tiny_skia::GradientStop::new(0.0, light),
            tiny_skia::GradientStop::new(0.55, base),
            tiny_skia::GradientStop::new(1.0, edge),
        ],
        tiny_skia::SpreadMode::Pad,
        tiny_skia::Transform::identity(),
    ) {
        p.shader = sh;
    }
    p
}

/// Railways sit below streets and bridges, so they are drawn before the street layer.
fn draw_railways(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    // railways: gravel bed, two rails, sleepers from z18
    for (pts, main) in railway_lines(ctx)? {
        let Some(p) = pts_path(&pts, false) else { continue };
        let bed = ctx.m(if main { 3.4 } else { 2.6 }).max(2.0);
        line(pm, &p, &paint(hex("#D3CDBF")), &stroke(bed), None);
        if ctx.z >= 18 {
            let mut sl = PathBuilder::new();
            for (x, y, a) in along(&pts, ctx.m(0.65).max(2.0), 0.0) {
                let (nx, ny) = (-a.sin(), a.cos());
                let h = bed * 0.38;
                sl.move_to(x - nx * h, y - ny * h);
                sl.line_to(x + nx * h, y + ny * h);
            }
            if let Some(sp) = sl.finish() {
                line(pm, &sp, &paint(with_alpha(hex("#9A9384"), 0.8)), &stroke(ctx.m(0.25).max(0.6)), None);
            }
        }
        let gauge = ctx.m(0.72).max(1.0);
        for side in [-1.0f32, 1.0] {
            let off: Vec<(f32, f32)> = pts
                .windows(2)
                .flat_map(|w| {
                    let (dx, dy) = (w[1].0 - w[0].0, w[1].1 - w[0].1);
                    let l = (dx * dx + dy * dy).sqrt().max(1e-3);
                    let (nx, ny) = (-dy / l * gauge * side, dx / l * gauge * side);
                    [(w[0].0 + nx, w[0].1 + ny), (w[1].0 + nx, w[1].1 + ny)]
                })
                .collect();
            if let Some(rp) = pts_path(&off, false) {
                line(pm, &rp, &paint(hex("#6C6B5A")), &stroke(ctx.m(0.12).max(0.6)), None);
            }
        }
    }
    Ok(())
}
