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

// Palette from the user's Pinterest board (swatch pin) + measured historic plans.
const PAPER: &str = "#EAE9E3";
const LAWN: &str = "#CBD4BC";
const MEADOW: &str = "#C2C5A6";
const SHRUB: &str = "#B5B39C";
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
            fill(&mut pm, &path, &paint(hex(col)), None);
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
    // watercolour mottling on green
    if let Some(mask) = mask_of(&ctx, &green) {
        apply_grain(&ctx, &mut pm, Some(&mask), 18.0, 3, 0.05, 11);
        apply_grain(&ctx, &mut pm, Some(&mask), 2.5, 2, 0.025, 12);
    }
    // shrub beds: darker edge + dabs
    if let Some(mask) = mask_of(&ctx, &shrubs) {
        let dab = with_alpha(shade(hex(SHRUB), 0.82), 0.55);
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
                line(&mut pm, &path, &paint(with_alpha(shade(hex(SHRUB), 0.7), 0.7)), &stroke(ctx.m(0.15).max(0.5)), None);
            }
        }
    }

    let water = ctx.polygons("0::bigint AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "water_body_dissolved", "")?;
    for f in &water {
        if let Some(path) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &path, &paint(hex(WATER)), None);
            line(&mut pm, &path, &paint(hex(WATER_EDGE)), &stroke(ctx.m(0.4).max(0.8)), None);
        }
    }

    // ---- streets
    let areas = ctx.polygons(
        r#"osm_id AS id, "area:highway" AS class, class AS sub, 0::float8 AS num"#,
        "highway_area",
        "ORDER BY COALESCE(layer,0)",
    )?;
    for f in &areas {
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
    let paths = ctx.lines(
        "osm_id AS id, highway AS class, class AS sub, COALESCE(width, 0)::float8 AS num",
        "highway WHERE type = 'path'",
        "ORDER BY COALESCE(layer,0), osm_id",
    )?;
    for f in &paths {
        let w = if f.num > 0.0 { f.num } else if f.class == "cycleway" { 1.6 } else { 1.8 };
        let col = match f.class.as_str() {
            "cycleway" => CYCLE,
            "footway" | "pedestrian" | "steps" if f.sub == "sidewalk" || f.sub == "crossing" => SIDEWALK,
            _ => "#DCD3BC",
        };
        if let Some(path) = line_path(&ctx, &f.geom) {
            line(&mut pm, &path, &paint(hex(col)), &stroke(ctx.m(w).max(0.8)), None);
        }
    }

    // ---- buildings: hard SE shadow, white volume, crisp outline, rare red roof
    let buildings = ctx.polygons(
        r#"osm_id AS id, COALESCE(building, 'yes') AS class, "building:part" AS sub,
           COALESCE(height, "building:levels" * 3.0, 9)::float8 AS num"#,
        "building",
        "ORDER BY COALESCE(height, 0), osm_id",
    )?;
    let sh = ctx.m(2.2);
    for (k, a) in [(1.0f32, 0.16f32), (0.66, 0.12), (0.33, 0.10)] {
        let mut pb = PathBuilder::new();
        for f in buildings.iter().filter(|f| f.sub.is_empty()) {
            let off = sh * k * (f.num as f32 / 15.0).clamp(0.4, 1.6);
            if let Some(p) = poly_path_shifted(&ctx, &f.geom, off, off * 0.75) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            fill(&mut pm, &p, &paint_blend(with_alpha(hex(SHADOW), a), BlendMode::Multiply), None);
        }
    }
    for f in buildings.iter().filter(|f| f.sub.is_empty()) {
        let Some(path) = poly_path(&ctx, &f.geom) else { continue };
        let r = rand01(f.id, 3);
        let landmark = matches!(f.class.as_str(), "church" | "chapel" | "cathedral" | "public" | "civic" | "school");
        let small = polygon_area_m2(&f.geom) < 300.0;
        let col = if landmark {
            "#F5F4EF"
        } else if small && r < 0.14 {
            if r < 0.08 { "#C98C7A" } else { "#B98270" }
        } else if r < 0.16 {
            "#E3E1DA"
        } else {
            BUILDING
        };
        fill(&mut pm, &path, &paint(hex(col)), None);
        line(&mut pm, &path, &paint(hex(BUILDING_LINE)), &stroke(ctx.m(0.22).clamp(0.7, 1.6)), None);
    }
    for f in buildings.iter().filter(|f| !f.sub.is_empty()) {
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
    draw_trees(&mut ctx, &mut pm, &woods)?;

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

fn draw_trees(ctx: &mut Ctx, pm: &mut Pixmap, woods: &[&Polygon<f64>]) -> Result<()> {
    let trees = ctx.points(
        "osm_id AS id, COALESCE(genus, leaf_type, '') AS class, COALESCE(leaf_type, '') AS sub, COALESCE(diameter_crown, 6)::float8 AS num",
        "tree",
        "",
    )?;
    let mut crowns: Vec<Crown> = Vec::new();
    for t in &trees {
        let (x, y) = ctx.px(t.geom.0);
        let key = if t.class.is_empty() { t.id } else { t.class.bytes().fold(7i64, |h, b| h.wrapping_mul(31).wrapping_add(i64::from(b))) };
        let variant = if t.sub == "needleleaved" { 3 } else { (rand01(key, 5) * 3.0) as u8 };
        let colour = hex(CROWNS[(rand01(key, 9) * CROWNS.len() as f32) as usize % CROWNS.len()]);
        crowns.push(Crown { x, y, r: ctx.m(t.num.clamp(2.0, 18.0) / 2.0), variant, colour, seed: t.id });
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
            crowns.push(Crown {
                x,
                y,
                r: ctx.m(3.2 + 2.2 * f64::from(r)),
                variant: (rand01(seed, 2) * 3.0) as u8,
                colour: hex(CROWNS[(rand01(seed, 4) * 6.0) as usize % 6]),
                seed,
            });
        }
    }
    // shadows first (multiply), then crowns big → small
    let mut pb = PathBuilder::new();
    for c in &crowns {
        let o = c.r * 0.35;
        pb.push_circle(c.x + o, c.y + o * 0.8, c.r);
    }
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint_blend(with_alpha(hex(SHADOW), 0.16), BlendMode::Multiply), None);
    }
    crowns.sort_by(|a, b| b.r.total_cmp(&a.r));
    for c in &crowns {
        draw_crown(pm, c);
    }
    Ok(())
}

fn draw_crown(pm: &mut Pixmap, c: &Crown) {
    let dark = shade(c.colour, 0.72);
    let w = (c.r * 0.06).clamp(0.5, 1.2);
    let phase = rand01(c.seed, 1) * 6.28;
    match c.variant {
        // board canonical: translucent disc, thin ring, centre dot
        0 => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &paint(with_alpha(c.colour, 0.5)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
        }
        // radial branches
        1 => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &paint(with_alpha(c.colour, 0.42)), None);
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
                fill(pm, &p, &paint(with_alpha(c.colour, 0.6)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
            if let Some(p) = PathBuilder::from_circle(c.x - c.r * 0.22, c.y - c.r * 0.22, c.r * 0.55) {
                fill(pm, &p, &paint(with_alpha(mix(c.colour, Color::WHITE, 0.35), 0.35)), None);
            }
        }
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
                fill(pm, &p, &paint(with_alpha(shade(c.colour, 0.85), 0.6)), None);
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
    // play equipment: structures white with outline, lines (slides, beams) as dark strokes
    let pg = ctx.polygons("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_polygon", "")?;
    for f in &pg {
        if let Some(p) = poly_path(ctx, &f.geom) {
            let col = if f.class == "sandpit" { "#E8E2D0" } else { "#FFFFFF" };
            fill(pm, &p, &paint(hex(col)), None);
            line(pm, &p, &paint(hex("#7C7A70")), &stroke(0.7), None);
        }
    }
    let pgw = ctx.lines("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_way", "")?;
    for f in &pgw {
        if let Some(p) = line_path(ctx, &f.geom) {
            line(pm, &p, &paint(hex("#6C6B5A")), &stroke(ctx.m(0.25).max(0.9)), None);
        }
    }
    if ctx.z < 18 {
        return Ok(());
    }
    let pgn = ctx.points("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_node", "")?;
    for f in &pgn {
        let (x, y) = ctx.px(f.geom.0);
        if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.5).max(1.5)) {
            fill(pm, &p, &paint(hex("#FFFFFF")), None);
            line(pm, &p, &paint(hex("#6C6B5A")), &stroke(0.7), None);
        }
    }
    let furniture = ctx.points(
        "osm_id AS id, class, subclass AS sub, COALESCE(direction, -1)::float8 AS num",
        "feature_node WHERE class IN ('bench', 'waste_basket', 'bicycle_parking', 'street_lamp', 'table_tennis', 'drinking_water')",
        "",
    )?;
    let dark = hex("#5F5E57");
    for f in &furniture {
        let (x, y) = ctx.px(f.geom.0);
        let ang = if f.num >= 0.0 { (f.num as f32).to_radians() } else { 0.0 };
        match f.class.as_str() {
            "bench" => {
                if let Some(p) = rect_rot(x, y, ctx.m(1.8).max(3.0), ctx.m(0.55).max(1.2), ang) {
                    fill(pm, &p, &paint(hex("#FFFFFF")), None);
                    line(pm, &p, &paint(dark), &stroke(0.7), None);
                }
            }
            "table_tennis" => {
                if let Some(p) = rect_rot(x, y, ctx.m(2.7), ctx.m(1.5), ang) {
                    fill(pm, &p, &paint(hex("#FFFFFF")), None);
                    line(pm, &p, &paint(dark), &stroke(0.7), None);
                }
            }
            "waste_basket" | "drinking_water" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.3).max(1.0)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            "street_lamp" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.25).max(0.9)) {
                    line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(0.6), None);
                }
            }
            _ => {
                if let Some(p) = rect_rot(x, y, ctx.m(1.6).max(2.5), ctx.m(0.12).max(0.6), ang) {
                    fill(pm, &p, &paint(with_alpha(dark, 0.8)), None);
                }
            }
        }
    }
    Ok(())
}
