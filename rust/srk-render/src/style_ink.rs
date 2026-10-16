//! Design research preset `ink`: fantasy-book ink map.
//!
//! Mission (docs/design-research/02-fantasy-ink-map): black ink on warm paper. The ground is a
//! plan; buildings stay in plan too (dense rows would collide in oblique view) but get a hatched
//! roof along the slope, a ridge line and a narrow south facade band. Landmarks and trees stand
//! upright, painted north → south. One category (playgrounds) is lifted out in an accent ink.

use anyhow::Result;
use geo_types::{Geometry, Polygon};
use postgres::Client;
use tiny_skia::{BlendMode, Color, PathBuilder, Pixmap};

use crate::paint::geometry_lines;
use crate::sql_cache::PreparedCache;
use crate::style_kit::*;
use crate::style_ink_extra as extra;
use crate::style_la::point_in_polygon;
use crate::tile::RenderExtent;

const PAPER_SEPIA: &str = "#F1E7CF";
const INK_SEPIA: &str = "#2B2620";
const PAPER_WHITE: &str = "#FBFAF6";
const INK_BLACK: &str = "#151515";

/// `SRK_INK_PAPER=white`: pure black ink on white paper (print), instead of sepia on parchment.
fn white_paper() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var("SRK_INK_PAPER").map(|v| v == "white").unwrap_or(false))
}
fn paper_hex() -> &'static str {
    if white_paper() { PAPER_WHITE } else { PAPER_SEPIA }
}
fn ink_hex() -> &'static str {
    if white_paper() { INK_BLACK } else { INK_SEPIA }
}
const ACCENT: &str = "#C8452C";

fn ink(a: f32) -> Color {
    with_alpha(hex(ink_hex()), a)
}

pub fn render(client: &mut Client, prep: &mut PreparedCache, extent: RenderExtent, z: u32) -> Result<Pixmap> {
    let mut pm = Pixmap::new(extent.width_px, extent.height_px).expect("pixmap");
    let paper = hex(paper_hex());
    pm.fill(paper);
    let mut ctx = Ctx { client, prep, extent, z, margin_m: 40.0 };


    // base pen width; a little heavier when zoomed out so blocks still read
    let lw = ctx.m(0.16).clamp(if z <= 17 { 0.85 } else { 0.7 }, 1.6);
    // Which category gets the accent ink: playground (default) | bench | tree | none
    let accent_cat = std::env::var("SRK_ACCENT").unwrap_or_else(|_| "playground".into());

    // ---- landuse textures (plan view)
    let landuse = ctx.polygons(
        "osm_id AS id, class, NULL::text AS sub, ST_Area(geom)::float8 AS num",
        "landuse",
        "ORDER BY ST_Area(geom) DESC",
    )?;
    let mut lawns = Vec::new();
    let mut shrubs = Vec::new();
    let mut sands = Vec::new();
    let mut playgrounds = Vec::new();
    let mut woods = Vec::new();
    let mut pools = Vec::new();
    let mut cemeteries = Vec::new();
    for f in &landuse {
        match f.class.as_str() {
            "cemetery" => {
                lawns.push(&f.geom);
                cemeteries.push(f.geom.clone());
            }
            "grass" | "park" | "greenery" | "garden" | "recreation_ground" | "village_green" | "dog_park"
            | "allotments" | "meadow" => lawns.push(&f.geom),
            "scrub" | "flowerbed" | "tree_pit" => shrubs.push(&f.geom),
            "sand" | "bare_ground" | "ground" | "woodchips" | "gravel" | "fitness_station" => sands.push(&f.geom),
            "playground" => playgrounds.push(&f.geom),
            "forest" | "wood" => woods.push(&f.geom),
            "swimming_pool" => pools.push(f.geom.clone()),
            _ => {}
        }
    }
    // lawn: grass tufts + thin edge
    if let Some(mask) = mask_of(&ctx, &lawns) {
        let mut pb = PathBuilder::new();
        let h = ctx.m(zcell(z, 0.8)).max(2.4);
        for (x, y, r) in world_scatter(&ctx, zcell(z, 3.6), 0.38, 41) {
            let (px, py) = ctx.extent.map_to_px(x, y);
            let s = h * (0.7 + 0.6 * r);
            for (dx, lean) in [(-0.45f32, -0.35f32), (0.0, 0.0), (0.45, 0.35)] {
                pb.move_to(px + dx * s * 0.5, py);
                pb.line_to(px + dx * s * 0.5 + lean * s * 0.4, py - s * (1.0 - dx.abs() * 0.3));
            }
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink(0.7)), &stroke(lw * 0.7), Some(&mask));
        }
        for g in &lawns {
            if let Some(p) = wobbly_poly(&ctx, g, 0.5) {
                line(&mut pm, &p, &paint(ink(0.45)), &stroke(lw * 0.6), None);
            }
        }
    }
    // shrubs: small scribbled loops
    if let Some(mask) = mask_of(&ctx, &shrubs) {
        let mut pb = PathBuilder::new();
        // small open "c" loops (bush scribbles), sparse enough that the bed stays light
        for (x, y, r) in world_scatter(&ctx, zcell(z, 2.0), 0.6, 43) {
            let (px, py) = ctx.extent.map_to_px(x, y);
            let rr = ctx.m(zcell(z, 0.5 + 0.3 * f64::from(r))).max(1.4);
            let pts = scallop_pts(px, py, rr, 5, 0.25, r * 6.0);
            let open = &pts[..pts.len() * 3 / 4];
            if let Some(p) = pts_path(open, false) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink(0.5)), &stroke(lw * 0.55), Some(&mask));
        }
    }
    // cemeteries: small scattered crosses (on top of the lawn texture)
    let cem: Vec<&Polygon<f64>> = cemeteries.iter().collect();
    if let Some(mask) = mask_of(&ctx, &cem).filter(|_| !cem.is_empty()) {
        let mut pb = PathBuilder::new();
        let s = ctx.m(zcell(z, 0.9)).max(2.5);
        for (x, y, _) in world_scatter(&ctx, zcell(z, 4.0), 0.55, 61) {
            let (px, py) = ctx.extent.map_to_px(x, y);
            pb.move_to(px, py - s);
            pb.line_to(px, py + s * 0.8);
            pb.move_to(px - s * 0.5, py - s * 0.35);
            pb.line_to(px + s * 0.5, py - s * 0.35);
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink(0.8)), &stroke(lw * 0.8), Some(&mask));
        }
    }
    // sand: stipple
    stipple(&ctx, &mut pm, &sands, zcell(z, 0.55), 0.6, ink(0.75), 45);

    // ---- water: wavy hatch + ripple lines following the shore
    let water = ctx.polygons("0::bigint AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "water_body_dissolved", "")?;
    if !water.is_empty() || !pools.is_empty() {
        let ws: Vec<&Polygon<f64>> = water.iter().map(|f| &f.geom).chain(pools.iter()).collect();
        if let Some(mask) = mask_of(&ctx, &ws) {
            for d in [ctx.m(3.0), ctx.m(1.8), ctx.m(0.8)] {
                for g in &ws {
                    if let Some(p) = poly_path(&ctx, g) {
                        line(&mut pm, &p, &paint(ink(0.55)), &stroke(2.0 * d + lw * 0.7), Some(&mask));
                        line(&mut pm, &p, &paint(paper), &stroke(2.0 * d - lw * 0.7), Some(&mask));
                    }
                }
            }
            let mut pb = PathBuilder::new();
            let gap = ctx.m(1.6).max(5.0);
            for (x, y, _) in world_scatter(&ctx, zcell(z, 2.6), 0.5, 47) {
                let (px, py) = ctx.extent.map_to_px(x, y);
                let pts: Vec<(f32, f32)> = (0..=8).map(|i| {
                    let t = i as f32 / 8.0;
                    (px - gap + 2.0 * gap * t, py + (t * std::f32::consts::TAU).sin() * gap * 0.12)
                }).collect();
                if let Some(p) = pts_path(&pts, false) {
                    pb.push_path(&p);
                }
            }
            if let Some(p) = pb.finish() {
                line(&mut pm, &p, &paint(ink(0.6)), &stroke(lw * 0.7), Some(&mask));
            }
        }
        for g in &ws {
            if let Some(p) = wobbly_poly(&ctx, g, 0.6) {
                line(&mut pm, &p, &paint(ink(1.0)), &stroke(lw * 1.6), None);
            }
        }
    }

    // ---- pitches: plan outline
    let pitches = ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "pitch", "")?;
    for f in &pitches {
        if let Some(p) = wobbly_poly(&ctx, &f.geom, 0.5) {
            line(&mut pm, &p, &paint(ink(0.8)), &stroke(lw), None);
        }
    }

    if let Some(p) = pitch_marking_path(&mut ctx)? {
        line(&mut pm, &p, &paint(ink(0.75)), &stroke(lw * 0.7), None);
    }

    // ---- railways: double line with cross ties (old-map railway sign)
    // unclipped lines: ties are spaced from the line start, which must not move with the tile
    let rails = ctx.lines_full(
        "osm_id AS id, railway AS class, COALESCE(service, '') AS sub, 0::float8 AS num",
        "railway_way WHERE railway IN ('rail', 'light_rail', 'subway', 'disused', 'tram', 'narrow_gauge') AND COALESCE(tunnel, 'no') = 'no'",
        "ORDER BY COALESCE(layer, 0)",
    )?;
    let rails: Vec<(Vec<(f32, f32)>, bool)> =
        rails.iter().map(|f| (line_pts(&ctx, &f.geom), f.sub.is_empty() && f.class != "disused")).collect();
    for (pts, main) in rails {
        let w = ctx.m(if main { 1.6 } else { 1.1 }).max(3.0);
        if let Some(p) = pts_path(&pts, false) {
            line(&mut pm, &p, &paint(ink(0.95)), &stroke(w + lw * 1.6), None);
            line(&mut pm, &p, &paint(paper), &stroke(w), None);
        }
        let mut ties = PathBuilder::new();
        for (x, y, a) in along(&pts, ctx.m(if main { 2.4 } else { 3.6 }).max(6.0), 1.0) {
            let (nx, ny) = (-a.sin(), a.cos());
            let h = w * 0.5 + lw;
            ties.move_to(x - nx * h, y - ny * h);
            ties.line_to(x + nx * h, y + ny * h);
        }
        if let Some(p) = ties.finish() {
            line(&mut pm, &p, &paint(ink(0.9)), &stroke(lw * 0.9), None);
        }
    }

    // ---- bridges: paper deck over rails and water (parapets after the streets)
    let decks = extra::bridges(&mut ctx)?;
    extra::draw_bridge_decks(&ctx, &mut pm, &decks, paper);

    // ---- streets: carriageway outline + sparse stipple, paths as double lines
    let areas = ctx.polygons(
        r#"osm_id AS id, "area:highway" AS class, class AS sub, 0::float8 AS num"#,
        "highway_area",
        "ORDER BY COALESCE(layer,0)",
    )?;
    let road: Vec<&Polygon<f64>> = areas
        .iter()
        .filter(|f| {
            matches!(
                f.class.as_str(),
                "residential" | "secondary" | "tertiary" | "tertiary_link" | "primary" | "service" | "living_street"
                    | "turning_circle" | "unclassified" | "cycleway"
            )
        })
        .map(|f| &f.geom)
        .collect();
    // carriageways occlude what lies below (rails under a bridge)
    for g in &road {
        if let Some(p) = poly_path(&ctx, g) {
            fill(&mut pm, &p, &paint(paper), None);
        }
    }
    stipple(&ctx, &mut pm, &road, zcell(z, 1.1), 0.35, ink(0.55), 49);
    for g in &road {
        if let Some(p) = wobbly_poly(&ctx, g, 0.5) {
            line(&mut pm, &p, &paint(ink(0.9)), &stroke(lw * 0.9), None);
        }
    }
    let paths = ctx.lines(
        "osm_id AS id, highway AS class, class AS sub, COALESCE(width, 0)::float8 AS num",
        "highway WHERE type = 'path'",
        "ORDER BY COALESCE(layer,0), osm_id",
    )?;
    for f in &paths {
        if f.sub == "sidewalk" || f.sub == "crossing" {
            continue; // sidewalks are the paper between kerb and house
        }
        let w = ctx.m(if f.num > 0.0 { f.num } else { 1.6 }).max(2.5);
        if let Some(p) = line_path(&ctx, &f.geom) {
            line(&mut pm, &p, &paint(ink(0.75)), &stroke(w + lw * 1.4), None);
            line(&mut pm, &p, &paint(paper), &stroke(w), None);
        }
    }

    extra::draw_bridge_parapets(&ctx, &mut pm, &decks, lw, ink(1.0));

    // ---- accent: playgrounds (wash, hatch, outline, equipment)
    let pg_poly = ctx.polygons("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_polygon", "")?;
    let pg_nodes = ctx.points("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_node", "")?;
    let pg_ways = ctx.lines("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_way", "")?;
    let accent = hex(ACCENT);
    let pg_on = accent_cat == "playground";
    let pg_col = if pg_on { accent } else { ink(0.85) };
    if !pg_on {
        stipple(&ctx, &mut pm, &playgrounds, zcell(z, 0.7), 0.5, ink(0.6), 46);
    }
    if let Some(mask) = mask_of(&ctx, &playgrounds).filter(|_| pg_on) {
        let (w, h) = (ctx.extent.width_px as f32, ctx.extent.height_px as f32);
        if let Some(p) = extra::hatch_world(&ctx, ctx.m(1.1).max(4.0), 45.0, 0.0, 0.0, w, h) {
            line(&mut pm, &p, &paint(with_alpha(accent, 0.45)), &stroke(lw * 0.7), Some(&mask));
        }
        let p = PathBuilder::from_rect(tiny_skia::Rect::from_xywh(0.0, 0.0, w, h).unwrap());
        fill(&mut pm, &p, &paint_blend(with_alpha(accent, 0.10), BlendMode::Multiply), Some(&mask));
    }
    for g in &playgrounds {
        if let Some(p) = wobbly_poly(&ctx, g, 0.6) {
            line(&mut pm, &p, &paint(pg_col), &stroke(lw * 1.3), None);
        }
    }
    for f in &pg_poly {
        if let Some(p) = wobbly_poly(&ctx, &f.geom, 0.4) {
            line(&mut pm, &p, &paint(with_alpha(pg_col, 0.9)), &stroke(lw), None);
        }
    }
    for f in &pg_ways {
        if let Some(p) = line_path(&ctx, &f.geom) {
            line(&mut pm, &p, &paint(pg_col), &stroke(lw * 1.2), None);
        }
    }

    // ---- embankments / cliffs: hachures
    // unclipped (lines_full) so hachures, fence ticks and hedge loops keep their phase across tiles
    let slopes = ctx.lines_full("osm_id AS id, class, NULL::text AS sub, 0::float8 AS num", "landscape_way WHERE class IN ('cliff', 'embankment', 'earth_bank')", "")?;
    for f in &slopes {
        let pts = line_pts(&ctx, &f.geom);
        if let Some(p) = pts_path(&wobble_pts(&ctx, &pts, 0.3, 5.0, 17), false) {
            line(&mut pm, &p, &paint(ink(0.95)), &stroke(lw * 1.1), None);
        }
        let l = ctx.m(if f.class == "cliff" { 2.2 } else { 1.6 }).max(4.0);
        if let Some(p) = hachures(&pts, ctx.m(0.7).max(2.6), l) {
            line(&mut pm, &p, &paint(ink(0.8)), &stroke(lw * 0.7), None);
        }
    }

    // ---- fences (+-+-), walls (heavy), hedges (bumpy line)
    let barriers = ctx.lines_full("osm_id AS id, barrier AS class, NULL::text AS sub, 0::float8 AS num", "barrier_way", "")?;
    for f in &barriers {
        let pts = line_pts(&ctx, &f.geom);
        match f.class.as_str() {
            "fence" | "handrail" => {
                if let Some(p) = pts_path(&pts, false) {
                    line(&mut pm, &p, &paint(ink(0.85)), &stroke(lw * 0.6), None);
                }
                let tick = ctx.m(0.35).max(1.6);
                let mut pb = PathBuilder::new();
                for (x, y, a) in along(&pts, ctx.m(2.2).max(6.0), 2.0) {
                    let (nx, ny) = (-a.sin(), a.cos());
                    pb.move_to(x - nx * tick, y - ny * tick);
                    pb.line_to(x + nx * tick, y + ny * tick);
                }
                if let Some(p) = pb.finish() {
                    line(&mut pm, &p, &paint(ink(0.85)), &stroke(lw * 0.7), None);
                }
            }
            "wall" | "retaining_wall" => {
                if let Some(p) = pts_path(&wobble_pts(&ctx, &pts, 0.3, 5.0, 13), false) {
                    line(&mut pm, &p, &paint(ink(1.0)), &stroke(ctx.m(0.35).max(lw * 1.6)), None);
                }
            }
            "hedge" => {
                let r = ctx.m(0.55).max(1.6);
                let mut pb = PathBuilder::new();
                for (x, y, _) in along(&pts, r * 1.1, 0.0) {
                    pb.push_circle(x, y, r);
                }
                if let Some(p) = pb.finish() {
                    fill(&mut pm, &p, &paint(paper), None);
                    line(&mut pm, &p, &paint(ink(0.7)), &stroke(lw * 0.6), None);
                }
            }
            _ => {}
        }
    }

    // ---- buildings (plan + roof hatch + ridge + south facade band), north → south
    draw_buildings(&mut ctx, &mut pm, lw)?;

    // ---- upright things: trees and playground equipment, painted north → south
    let trees = ctx.points("osm_id AS id, COALESCE(leaf_type,'') AS class, NULL::text AS sub, COALESCE(diameter_crown, 6)::float8 AS num", "tree", "")?;
    let mut uprights: Vec<(f32, f32, f32, i64, u8)> = Vec::new();
    // woodland: one cloud silhouette with a heavy outline, light arcs inside (fantasy-map forest);
    // mapped trees inside a wood join the silhouette instead of being drawn one by one
    let mut forest: Vec<(f32, f32, f32, i64)> = Vec::new();
    for t in &trees {
        let (x, y) = ctx.px(t.geom.0);
        let r = ctx.m(t.num.clamp(2.0, 16.0) / 2.0 * 0.85);
        if woods.iter().any(|p| point_in_polygon(t.geom.0, p)) {
            forest.push((x, y, r, t.id));
            continue;
        }
        let kind = if t.class == "needleleaved" { 1 } else { 0 };
        uprights.push((x, y, r, t.id, kind));
    }
    // coarser forest when zoomed out: cell and crown size grow with √2 per zoom level below z19
    let fk = 2f64.powf((19.0 - f64::from(z)).max(0.0) / 2.0);
    for (wx, wy, r) in world_scatter(&ctx, 5.0 * fk, 0.9, 51) {
        let pt = geo_types::Coord { x: wx, y: wy };
        if woods.iter().any(|p| point_in_polygon(pt, p)) {
            let (x, y) = ctx.extent.map_to_px(wx, wy);
            forest.push((x, y, ctx.m((2.6 + 1.6 * f64::from(r)) * fk), (wx * 3.0) as i64 ^ (wy * 5.0) as i64));
        }
    }
    draw_forest(&ctx, &mut pm, &mut forest, lw, paper);
    for n in &pg_nodes {
        let (x, y) = ctx.px(n.geom.0);
        uprights.push((x, y, ctx.m(0.9), n.id, 9));
    }
    if z >= 18 || accent_cat == "bench" {
        let benches = ctx.points("osm_id AS id, class, NULL::text AS sub, COALESCE(direction, -1)::float8 AS num", "feature_node WHERE class = 'bench'", "")?;
        for b in &benches {
            let (x, y) = ctx.px(b.geom.0);
            uprights.push((x, y, ctx.m(0.9), b.id, 8));
        }
    }
    let water_on = accent_cat == "water";
    for (id, kind, (x, y)) in extra::furniture(&mut ctx, water_on)? {
        let r = if kind == extra::FOUNTAIN { ctx.m(1.8).max(5.0) } else { ctx.m(0.95).max(3.0) };
        uprights.push((x, y, r, id, kind));
    }
    uprights.sort_by(|a, b| a.1.total_cmp(&b.1));
    for &(x, y, r, id, kind) in &uprights {
        match kind {
            9 => draw_equipment(&mut pm, x, y, r.max(2.5), lw, pg_col, paper, eq_kind(id, &pg_nodes)),
            8 => {
                let on = accent_cat == "bench";
                draw_bench(&mut pm, x, y, if on { r.max(3.5) * 1.3 } else { r.max(2.2) }, lw, if on { accent } else { ink(0.85) }, paper)
            }
            k if k >= extra::LAMP => {
                let on = water_on && extra::is_water(k);
                let s = if on { r.max(3.2) * 1.3 } else { r };
                extra::draw_furniture(&mut pm, k, x, y, s, lw, if on { accent } else { ink(0.9) }, paper)
            }
            1 => draw_conifer(&ctx, &mut pm, x, y, r, id, lw, paper, if accent_cat == "tree" { accent } else { ink(1.0) }),
            _ => draw_tree(&ctx, &mut pm, x, y, r, id, lw, paper, if accent_cat == "tree" { accent } else { ink(1.0) }),
        }
    }

    draw_area_labels(
        &mut ctx,
        &mut pm,
        &LabelStyle {
            family: "Hoefler Text",
            italic: false,
            weight: 400,
            size_px: 15.0,
            letter_spacing_em: 0.32,
            uppercase: true,
            fill: ink_hex(),
            halo: paper_hex(),
            halo_px: 3.5,
            repeat_px: 0.0,
        },
        40_000.0,
        30.0,
    )?;
    if z >= 16 {
        draw_street_labels(
            &mut ctx,
            &mut pm,
            &LabelStyle {
                family: "Hoefler Text",
                italic: true,
                weight: 400,
                size_px: match z { 20.. => 21.0, 19 => 17.0, _ => 14.0 },
                letter_spacing_em: 0.06,
                uppercase: false,
                fill: ink_hex(),
                halo: paper_hex(),
                halo_px: 3.2,
                repeat_px: 560.0,
            },
        )?;
    }
    // paper: large blotches + fine grain over everything (ink sits in the paper, fills don't hide it)
    if !white_paper() {
        apply_grain(&ctx, &mut pm, None, 90.0, 3, 0.045, 1);
    }
    apply_grain(&ctx, &mut pm, None, 0.5, 1, 0.03, 2);
    Ok(pm)
}

fn wobbly_poly(ctx: &Ctx, poly: &Polygon<f64>, amp: f32) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    for ring in poly_rings_px(ctx, poly) {
        let pts = wobble_pts(ctx, &ring, amp, 6.0, 5);
        let mut it = pts.iter();
        let Some((x, y)) = it.next() else { continue };
        pb.move_to(*x, *y);
        for (x, y) in it {
            pb.line_to(*x, *y);
        }
        pb.close();
    }
    pb.finish()
}

fn stipple(ctx: &Ctx, pm: &mut Pixmap, polys: &[&Polygon<f64>], cell_m: f64, density: f32, colour: Color, seed: u64) {
    if polys.is_empty() {
        return;
    }
    let Some(mask) = mask_of(ctx, polys) else { return };
    let mut pb = PathBuilder::new();
    let r = ctx.m(0.08).clamp(0.45, 0.9);
    for (x, y, k) in world_scatter(ctx, cell_m, density, seed) {
        let (px, py) = ctx.extent.map_to_px(x, y);
        pb.push_circle(px, py, r * (0.7 + 0.6 * k));
    }
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(colour), Some(&mask));
    }
}

/// Key of a lifted small group from a building's kind ("group;<h>;<key>"); None for other kinds.
fn group_key(sub: &str) -> Option<&str> {
    let mut parts = sub.split(';');
    if parts.next()? != "group" {
        return None;
    }
    parts.next()?;
    parts.next()
}

fn draw_buildings(ctx: &mut Ctx, pm: &mut Pixmap, lw: f32) -> Result<()> {
    // kind = 'part' | 'free;<h>;<key>' | 'group;<h>;<key>' | 'block;<h>;<key>': connected clusters
    // (eps 0.8 m, as the old NOT EXISTS test) are counted over a window 300 m wider than the tile,
    // so the stats do not depend on the tile drawn. Areas are 3857 m² × 0.371 ≈ m² at Berlin latitude.
    // h = cluster maximum for free/group (one shared lift), own height for blocks (landmarks).
    let sql_from = r#"(
        WITH env AS (SELECT ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857) AS win),
        near AS (
          SELECT o.osm_id, o.geom, COALESCE(o.height, o."building:levels" * 3.0, 9) AS h,
                 ST_ClusterDBSCAN(o.geom, eps := 0.8, minpoints := 1) OVER () AS cid
          FROM building o, env
          WHERE o."building:part" IS NULL AND o.geom && ST_Expand(env.win, 300)
        ),
        cl AS (SELECT cid, count(*) AS n, sum(ST_Area(geom)) * 0.371 AS a, max(h) AS h, min(osm_id) AS key
               FROM near GROUP BY cid),
        grp AS (SELECT near.osm_id, cl.n, cl.a, cl.h, cl.key FROM near JOIN cl USING (cid))
        SELECT b.osm_id, b.building, b.geom,
          CASE WHEN b."building:part" IS NOT NULL THEN 'part'
               ELSE (CASE WHEN g.n = 1 THEN 'free' WHEN g.n <= 6 AND g.a <= 1800 THEN 'group' ELSE 'block' END)
                    || ';' || (CASE WHEN g.n <= 6 AND g.a <= 1800 THEN g.h
                                    ELSE COALESCE(b.height, b."building:levels" * 3.0, 9) END)::text
                    || ';' || g.key::text
          END AS kind,
          CASE WHEN ST_Distance(e.p1, e.p2) >= ST_Distance(e.p2, e.p3)
               THEN degrees(ST_Azimuth(e.p1, e.p2)) ELSE degrees(ST_Azimuth(e.p2, e.p3)) END AS axis,
          CASE WHEN ST_Area(b.geom) / NULLIF(ST_Area(e.oe), 0) > 0.72 THEN
            ST_Intersection(b.geom,
              CASE WHEN ST_Distance(e.p1, e.p2) >= ST_Distance(e.p2, e.p3)
                   THEN ST_MakeLine(ST_Centroid(ST_MakeLine(e.p2, e.p3)), ST_Centroid(ST_MakeLine(e.p4, e.p1)))
                   ELSE ST_MakeLine(ST_Centroid(ST_MakeLine(e.p1, e.p2)), ST_Centroid(ST_MakeLine(e.p3, e.p4))) END)
          END AS ridge
        FROM building b LEFT JOIN grp g ON g.osm_id = b.osm_id,
        LATERAL (
          SELECT oe, ST_PointN(ST_ExteriorRing(oe), 1) p1, ST_PointN(ST_ExteriorRing(oe), 2) p2,
                 ST_PointN(ST_ExteriorRing(oe), 3) p3, ST_PointN(ST_ExteriorRing(oe), 4) p4
          FROM (SELECT ST_OrientedEnvelope(b.geom) AS oe) q
          WHERE GeometryType(oe) = 'POLYGON'
        ) e
        WHERE b.geom && (SELECT win FROM env)
      ) bb"#;
    let buildings = ctx.polygons(
        r#"osm_id AS id, COALESCE(building, 'yes') AS class, kind AS sub, COALESCE(axis, 0)::float8 AS num,
           ST_AsBinary(ridge) AS wkb2"#,
        sql_from,
        "",
    )?;
    let paper = hex(paper_hex());
    let mut order: Vec<(f32, usize)> = buildings
        .iter()
        .enumerate()
        .filter(|(_, f)| f.sub != "part")
        .map(|(i, f)| {
            let pts = poly_rings_px(ctx, &f.geom).into_iter().next().unwrap_or_default();
            (bbox_px(&pts).3, i)
        })
        .collect();
    order.sort_by(|a, b| a.0.total_cmp(&b.0));
    let fh = ctx.m(1.7).clamp(3.0, 14.0); // facade band height
    // Variant: SRK_INK_OBLIQUE=freestanding lifts free-standing buildings and small connected groups
    // (<= 6 buildings, <= 1800 m²; one shared lift per group) into an oblique view (roof shifted north
    // by a stylised height, south walls visible); larger blocks and rows stay plan.
    let oblique = std::env::var("SRK_INK_OBLIQUE").map(|v| v == "freestanding").unwrap_or(false) && ctx.z >= 17;
    let mut lifts: std::collections::HashMap<i64, f32> = std::collections::HashMap::new();
    let hatch_sp = ctx.m(0.7).clamp(2.6, 6.0);
    let lift_of = |f: &Feature<Polygon<f64>>| -> f32 {
        let landmark = matches!(f.class.as_str(), "church" | "chapel" | "cathedral");
        let mut kind = f.sub.split(';');
        let mode = kind.next().unwrap_or("");
        let height_m: f64 = kind.next().and_then(|h| h.parse().ok()).unwrap_or(9.0);
        if oblique && (matches!(mode, "free" | "group") || landmark) {
            ctx.m((height_m * if landmark { 0.6 } else { 0.5 }).clamp(3.0, 18.0)).clamp(4.0, 60.0)
        } else {
            0.0
        }
    };
    // members of each lifted small group (by group key), to skip the walls between them
    let mut by_group: std::collections::HashMap<&str, Vec<usize>> = std::collections::HashMap::new();
    if oblique {
        for (i, f) in buildings.iter().enumerate() {
            if let Some(k) = group_key(&f.sub) {
                by_group.entry(k).or_default().push(i);
            }
        }
    }
    // lifted buildings cast a hatched shadow on the ground towards the east (light from the
    // south-west, as for the shaded roof half); drawn first so every building covers it
    if oblique {
        let mut shadow = PathBuilder::new();
        for (_, i) in &order {
            let f = &buildings[*i];
            let lift = lift_of(f);
            if lift <= 0.0 {
                continue;
            }
            for k in [0.2f32, 0.4, 0.6, 0.8, 1.0] {
                if let Some(p) = poly_path_shifted(ctx, &f.geom, lift * 0.75 * k, -lift * 0.35 * k) {
                    shadow.push_path(&p);
                }
            }
        }
        if let Some(sp) = shadow.finish() {
            if let Some(mut mask) = tiny_skia::Mask::new(ctx.extent.width_px, ctx.extent.height_px) {
                mask.fill_path(&sp, tiny_skia::FillRule::Winding, true, tiny_skia::Transform::identity());
                let (w, h) = (ctx.extent.width_px as f32, ctx.extent.height_px as f32);
                if let Some(hp) = extra::hatch_world(ctx, hatch_sp * 0.9, 45.0, 0.0, 0.0, w, h) {
                    line(pm, &hp, &paint(ink(0.42)), &stroke(lw * 0.55), Some(&mask));
                }
            }
        }
    }
    for (_, i) in order {
        let f = &buildings[i];
        let landmark = matches!(f.class.as_str(), "church" | "chapel" | "cathedral");
        let lift = lift_of(f);
        if lift > 0.0 {
            lifts.insert(f.id, lift);
        }
        let Some(roof) = poly_path(ctx, &f.geom).and_then(|p| p.transform(tiny_skia::Transform::from_translate(0.0, -lift))) else { continue };
        let rings = poly_rings_px(ctx, &f.geom);
        let ext = rings.first().cloned().unwrap_or_default();
        let (x0, y0, x1, y1) = bbox_px(&ext);
        let (y0, y1) = (y0 - lift, y1 - lift);
        let roof_mask = || {
            let mut m = tiny_skia::Mask::new(ctx.extent.width_px, ctx.extent.height_px)?;
            m.fill_path(&roof, tiny_skia::FillRule::EvenOdd, true, tiny_skia::Transform::identity());
            Some(m)
        };
        // south facade band (plan) or full south walls (lifted)
        let band = if lift > 0.0 { lift } else if ctx.z < 18 { 0.0 } else if landmark { fh * 2.2 } else { fh };
        let dir = if lift > 0.0 { -1.0 } else { 1.0 };
        let mut facade = PathBuilder::new();
        let mut windows = PathBuilder::new();
        for ring in &rings {
            for w in ring.windows(2) {
                let (ax, ay) = w[0];
                let (bx, by) = w[1];
                let (dx, dy) = (bx - ax, by - ay);
                let len = (dx * dx + dy * dy).sqrt();
                if len < 1.5 {
                    continue;
                }
                let (nx, ny) = (dy / len, -dx / len);
                let (mx, my) = ((ax + bx) / 2.0, (ay + by) / 2.0);
                let probe = ctx.world(mx + nx * 1.0, my + ny * 1.0);
                let inside = point_in_polygon(geo_types::Coord { x: probe.0, y: probe.1 }, &f.geom);
                let (ox, oy) = if inside { (-nx, -ny) } else { (nx, ny) };
                if oy < 0.3 || band <= 0.0 {
                    continue;
                }
                // lifted group: no wall where the outward side is another member of the same group
                if lift > 0.0 {
                    if let Some(members) = group_key(&f.sub).and_then(|k| by_group.get(k)) {
                        let (px, py) = ctx.world(mx + ox * 1.5, my + oy * 1.5);
                        let pt = geo_types::Coord { x: px, y: py };
                        if members.iter().any(|&j| j != i && point_in_polygon(pt, &buildings[j].geom)) {
                            continue;
                        }
                    }
                }
                let k = if lift > 0.0 { 1.0 } else { oy.min(1.0) };
                facade.move_to(ax, ay);
                facade.line_to(bx, by);
                facade.line_to(bx, by + dir * band * k);
                facade.line_to(ax, ay + dir * band * k);
                facade.close();
                // windows: short vertical ticks along the edge, one row per storey when lifted
                let step = ctx.m(3.2).max(6.0);
                let n = if ctx.z >= 19 || lift > 0.0 { (len / step).floor() as i32 } else { 0 };
                let rows = if lift > 0.0 { ((band / ctx.m(3.0).max(4.0)).round() as i32).max(1) } else { 1 };
                for r in 0..rows {
                    let (r0, r1) = ((r as f32 + 0.3) / rows as f32, (r as f32 + 0.7) / rows as f32);
                    for j in 0..n {
                        let t = (j as f32 + 0.5) / n as f32;
                        let wx = ax + dx * t;
                        let wy = ay + dy * t;
                        windows.move_to(wx, wy + dir * band * k * r0);
                        windows.line_to(wx, wy + dir * band * k * r1);
                    }
                }
            }
        }
        if let Some(p) = facade.finish() {
            fill(pm, &p, &paint(shade(paper, 0.96)), None);
            line(pm, &p, &paint(ink(0.85)), &stroke(lw * 0.8), None);
        }
        if let Some(p) = windows.finish() {
            line(pm, &p, &paint(ink(0.8)), &stroke(lw * 1.1), None);
        }
        // roof: paper, slope hatch clipped to the footprint
        fill(pm, &roof, &paint(paper), None);
        let axis_px = {
            let a = (f.num as f32).to_radians();
            (-(a.cos())).atan2(a.sin()).to_degrees()
        };
        if let Some(mask) = roof_mask() {
            if let Some(h) = hatch_path(ctx, hatch_sp, axis_px + 90.0, x0 - 4.0, y0 - 4.0, x1 + 4.0, y1 + 4.0) {
                let a = if landmark { 0.75 } else { 0.5 };
                line(pm, &h, &paint(ink(a)), &stroke(lw * 0.55), Some(&mask));
            }
        }
        if let Some(Geometry::LineString(_) | Geometry::MultiLineString(_)) = &f.aux {
            for l in geometry_lines(f.aux.clone().unwrap()) {
                let rp: Vec<(f32, f32)> = line_pts(ctx, &l).into_iter().map(|(x, y)| (x, y - lift)).collect();
                // shaded roof half: the side facing away from the light (NE), cross-hatched
                if let (Some(&(px, py)), Some(&(qx, qy))) = (rp.first(), rp.last()) {
                    let (dx, dy) = (qx - px, qy - py);
                    let len = (dx * dx + dy * dy).sqrt();
                    if len > 2.0 {
                        let (ux, uy) = (dx / len, dy / len);
                        let (mut nx, mut ny) = (-uy, ux);
                        if nx - ny < 0.0 {
                            nx = -nx;
                            ny = -ny;
                        }
                        let big = 400.0;
                        let quad = [
                            (px - ux * big, py - uy * big),
                            (qx + ux * big, qy + uy * big),
                            (qx + ux * big + nx * big, qy + uy * big + ny * big),
                            (px - ux * big + nx * big, py - uy * big + ny * big),
                        ];
                        if let (Some(mut mask), Some(half)) = (roof_mask(), pts_path(&quad, true)) {
                            mask.intersect_path(&half, tiny_skia::FillRule::Winding, true, tiny_skia::Transform::identity());
                            if let Some(h) = hatch_path(ctx, hatch_sp * 1.3, axis_px, x0 - 4.0, y0 - 4.0, x1 + 4.0, y1 + 4.0) {
                                line(pm, &h, &paint(ink(0.38)), &stroke(lw * 0.5), Some(&mask));
                            }
                        }
                    }
                }
                if let Some(p) = pts_path(&rp, false) {
                    line(pm, &p, &paint(ink(0.9)), &stroke(lw), None);
                }
            }
        }
        let mut pb = PathBuilder::new();
        for ring in &rings {
            let ring: Vec<(f32, f32)> = ring.iter().map(|&(x, y)| (x, y - lift)).collect();
            let pts = wobble_pts(ctx, &ring, 0.45, 6.0, 7);
            if let Some(p) = pts_path(&pts, true) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            line(pm, &p, &paint(ink(1.0)), &stroke(lw * 1.25), None);
        }
    }
    // building parts: thin lines on the roofs
    for f in buildings.iter().filter(|f| f.sub == "part") {
        if lifts.contains_key(&f.id) {
            continue;
        }
        if let Some(p) = poly_path(ctx, &f.geom) {
            line(pm, &p, &paint(ink(0.45)), &stroke(lw * 0.5), None);
        }
    }
    // landmarks: one spire per landmark, on its smallest polygon (usually the tower)
    let mut seen = std::collections::HashMap::new();
    for f in buildings.iter().filter(|f| matches!(f.class.as_str(), "church" | "chapel" | "cathedral")) {
        let ext = poly_rings_px(ctx, &f.geom).into_iter().next().unwrap_or_default();
        let a = polygon_px_area(&ext);
        if a < 20.0 {
            continue;
        }
        let e = seen.entry(f.id).or_insert((f32::MAX, ext.clone()));
        if a < e.0 {
            *e = (a, ext);
        }
    }
    // icons stand upright: collect (base y, draw) and paint north → south
    let mut icons: Vec<(f32, f32, Option<extra::Landmark>, f32)> = Vec::new();
    for (id, (_, ext)) in seen {
        let l = lifts.get(&id).copied().unwrap_or(0.0);
        let (x0, y0, x1, y1) = bbox_px(&ext);
        icons.push(((x0 + x1) / 2.0, (y0 + y1) / 2.0 + (y1 - y0) * 0.3 - l, None, ctx.m(4.5).max(10.0)));
    }
    // schools (bell turret) and civic buildings (clock tower): one icon per building, on its
    // largest polygon, from z17 and only on buildings that are big enough to carry it
    if ctx.z >= 17 {
        let min_a = ctx.m(1.0).powi(2) * 250.0;
        let mut best: std::collections::HashMap<i64, (f32, usize, extra::Landmark)> = std::collections::HashMap::new();
        for (i, f) in buildings.iter().enumerate() {
            let Some(kind) = extra::landmark_of(&f.class) else { continue };
            if f.sub == "part" {
                continue;
            }
            let ext = poly_rings_px(ctx, &f.geom).into_iter().next().unwrap_or_default();
            let a = polygon_px_area(&ext);
            if a < min_a {
                continue;
            }
            let e = best.entry(f.id).or_insert((0.0, i, kind));
            if a > e.0 {
                *e = (a, i, kind);
            }
        }
        for (id, (_, i, kind)) in best {
            let f = &buildings[i];
            let l = lifts.get(&id).copied().unwrap_or(0.0);
            // on the ridge if there is one, else well inside the footprint
            let ridge_mid = match &f.aux {
                Some(Geometry::LineString(ls)) if ls.0.len() >= 2 => {
                    let pts = line_pts(ctx, ls);
                    let len: f32 = pts.windows(2).map(|w| ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt()).sum();
                    Some(point_at(&pts, len / 2.0))
                }
                _ => None,
            };
            let ext = poly_rings_px(ctx, &f.geom).into_iter().next().unwrap_or_default();
            let Some((x, y)) = ridge_mid.or_else(|| extra::inner_point(&ext, &f.geom, ctx)) else { continue };
            let s = match kind {
                extra::Landmark::BellTurret => ctx.m(5.2).max(10.0),
                extra::Landmark::ClockTower => ctx.m(5.6).max(11.0),
            };
            icons.push((x, y - l, Some(kind), s));
        }
    }
    icons.sort_by(|a, b| a.1.total_cmp(&b.1));
    for (x, y, kind, s) in icons {
        match kind {
            None => draw_spire(pm, x, y, s, lw, paper),
            Some(k) => extra::draw_landmark(pm, k, x, y, s, lw, ink(1.0), paper),
        }
    }
    Ok(())
}

fn polygon_px_area(pts: &[(f32, f32)]) -> f32 {
    let mut a = 0.0;
    for w in pts.windows(2) {
        a += w[0].0 * w[1].1 - w[1].0 * w[0].1;
    }
    (a / 2.0).abs()
}

fn draw_spire(pm: &mut Pixmap, cx: f32, base: f32, s: f32, lw: f32, paper: Color) {
    let w = s * 0.55;
    let tower_h = s * 1.6;
    let spire_h = s * 1.8;
    let mut body = PathBuilder::new();
    body.move_to(cx - w / 2.0, base);
    body.line_to(cx - w / 2.0, base - tower_h);
    body.line_to(cx + w / 2.0, base - tower_h);
    body.line_to(cx + w / 2.0, base);
    body.close();
    let mut cap = PathBuilder::new();
    cap.move_to(cx - w * 0.62, base - tower_h);
    cap.line_to(cx, base - tower_h - spire_h);
    cap.line_to(cx + w * 0.62, base - tower_h);
    cap.close();
    for pb in [body, cap] {
        if let Some(p) = pb.finish() {
            fill(pm, &p, &paint(paper), None);
            line(pm, &p, &paint(ink(1.0)), &stroke(lw * 1.2), None);
        }
    }
    // shading + window + cross
    let mut d = PathBuilder::new();
    let mut t = 0.0;
    while t < tower_h {
        d.move_to(cx + w * 0.1, base - t);
        d.line_to(cx + w * 0.5, base - t);
        t += lw * 2.6;
    }
    d.move_to(cx, base - tower_h * 0.55);
    d.line_to(cx, base - tower_h * 0.8);
    d.move_to(cx, base - tower_h - spire_h);
    d.line_to(cx, base - tower_h - spire_h - s * 0.45);
    d.move_to(cx - s * 0.15, base - tower_h - spire_h - s * 0.3);
    d.line_to(cx + s * 0.15, base - tower_h - spire_h - s * 0.3);
    if let Some(p) = d.finish() {
        line(pm, &p, &paint(ink(0.85)), &stroke(lw * 0.8), None);
    }
}

fn draw_tree(ctx: &Ctx, pm: &mut Pixmap, x: f32, y: f32, r: f32, id: i64, lw: f32, paper: Color, pen: Color) {
    let r = r.max(2.5);
    let cx = x;
    let cy = y - r * 0.85;
    // ground shadow tick
    let mut g = PathBuilder::new();
    g.move_to(x - r * 0.45, y + 0.5);
    g.line_to(x + r * 0.75, y + 0.5);
    if let Some(p) = g.finish() {
        line(pm, &p, &paint(ink(0.55)), &stroke(lw * 0.8), None);
    }
    // trunk
    let mut t = PathBuilder::new();
    t.move_to(x, y);
    t.line_to(x, cy + r * 0.5);
    if let Some(p) = t.finish() {
        line(pm, &p, &paint(ink(0.95)), &stroke(lw * 1.2), None);
    }
    let bumps = 7 + (rand01(id, 3) * 5.0) as u32;
    let shape = (rand01(id, 8) * 10.0) as u32; // 0–5 scalloped, 6–8 round, 9 tall
    let pts: Vec<(f32, f32)> = match shape {
        6..=8 => scallop_pts(cx, cy, r, 5, 0.05, rand01(id, 4) * std::f32::consts::TAU),
        9 => scallop_pts(cx, cy - r * 0.35, r, bumps, 0.12, rand01(id, 4) * std::f32::consts::TAU)
            .into_iter()
            .map(|(px, py)| (cx + (px - cx) * 0.7, (cy - r * 0.35) + (py - (cy - r * 0.35)) * 1.35))
            .collect(),
        _ => scallop_pts(cx, cy, r, bumps, 0.16, rand01(id, 4) * std::f32::consts::TAU),
    };
    let pts = wobble_pts(ctx, &pts, 0.3, 4.0, id as u64);
    if let Some(p) = pts_path(&pts, true) {
        fill(pm, &p, &paint(paper), None);
        // shading strokes lower right, clipped by drawing inside the crown only
        let mut s = PathBuilder::new();
        let n = (r * 1.1) as i32 + 3;
        for i in 0..n {
            let a = -0.2 + 1.9 * rand01(id, 10 + i as u64);
            let rr = r * (0.35 + 0.5 * rand01(id, 40 + i as u64));
            let (px, py) = (cx + rr * a.cos(), cy + rr * a.sin());
            s.move_to(px, py);
            s.line_to(px - r * 0.2, py + r * 0.16);
        }
        if let Some(sp) = s.finish() {
            line(pm, &sp, &paint(ink(0.6)), &stroke(lw * 0.6), None);
        }
        line(pm, &p, &paint(pen), &stroke(lw * 1.05), None);
    }
}

fn draw_conifer(ctx: &Ctx, pm: &mut Pixmap, x: f32, y: f32, r: f32, id: i64, lw: f32, paper: Color, pen: Color) {
    let _ = ctx;
    let h = r * 2.6;
    let w = r * 0.9;
    let mut pb = PathBuilder::new();
    pb.move_to(x, y - h);
    for i in 1..=3 {
        let t = i as f32 / 3.0;
        pb.line_to(x + w * t, y - h + h * t * 0.85);
        pb.line_to(x + w * t * 0.45, y - h + h * t * 0.85);
    }
    for i in (1..=3).rev() {
        let t = i as f32 / 3.0;
        pb.line_to(x - w * t * 0.45, y - h + h * t * 0.85);
        pb.line_to(x - w * t, y - h + h * t * 0.85);
    }
    pb.close();
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(paper), None);
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
    let _ = id;
}

fn eq_kind(id: i64, nodes: &[Feature<geo_types::Point<f64>>]) -> u8 {
    match nodes.iter().find(|n| n.id == id).map(|n| n.class.as_str()) {
        Some("swing" | "basketswing") => 0,
        Some("slide" | "chute") => 1,
        Some("springy" | "spring_board" | "seesaw" | "spinner" | "spinning_disc") => 2,
        Some("climbingframe" | "structure" | "climbing_pole" | "ladder") => 3,
        _ => 4,
    }
}

fn draw_equipment(pm: &mut Pixmap, x: f32, y: f32, s: f32, lw: f32, accent: Color, paper: Color, kind: u8) {
    let mut pb = PathBuilder::new();
    match kind {
        0 => {
            // swing: A-frame with a seat
            pb.move_to(x - s, y);
            pb.line_to(x - s * 0.6, y - s * 1.6);
            pb.line_to(x - s * 0.2, y);
            pb.move_to(x + s * 0.2, y);
            pb.line_to(x + s * 0.6, y - s * 1.6);
            pb.line_to(x + s, y);
            pb.move_to(x - s * 0.6, y - s * 1.6);
            pb.line_to(x + s * 0.6, y - s * 1.6);
            pb.move_to(x, y - s * 1.6);
            pb.line_to(x, y - s * 0.5);
        }
        1 => {
            // slide: ladder + chute
            pb.move_to(x - s * 0.8, y);
            pb.line_to(x - s * 0.8, y - s * 1.5);
            pb.line_to(x + s * 1.0, y);
            for k in 1..4 {
                let t = k as f32 / 4.0;
                pb.move_to(x - s * 0.95, y - s * 1.5 * t);
                pb.line_to(x - s * 0.65, y - s * 1.5 * t);
            }
        }
        2 => {
            // spring rider: spring + seat blob
            for k in 0..4 {
                let yy = y - k as f32 * s * 0.22;
                pb.move_to(x - s * 0.25, yy);
                pb.line_to(x + s * 0.25, yy - s * 0.11);
            }
            pb.push_circle(x, y - s * 1.1, s * 0.35);
        }
        3 => {
            // climbing frame: dome grid
            pb.move_to(x - s, y);
            pb.quad_to(x, y - s * 2.2, x + s, y);
            pb.move_to(x - s * 0.5, y);
            pb.quad_to(x, y - s * 1.2, x + s * 0.5, y);
            pb.move_to(x - s * 0.85, y - s * 0.55);
            pb.line_to(x + s * 0.85, y - s * 0.55);
        }
        _ => {
            pb.push_rect(tiny_skia::Rect::from_xywh(x - s * 0.5, y - s * 1.0, s, s).unwrap());
        }
    }
    if let Some(p) = pb.finish() {
        line(pm, &p, &paint(paper), &stroke(lw * 3.0), None);
        line(pm, &p, &paint(accent), &stroke(lw * 1.1), None);
    }
}

fn draw_bench(pm: &mut Pixmap, x: f32, y: f32, s: f32, lw: f32, pen: Color, paper: Color) {
    // seat, backrest and two legs, seen from the front
    let mut pb = PathBuilder::new();
    pb.move_to(x - s, y - s * 0.55);
    pb.line_to(x + s, y - s * 0.55);
    pb.move_to(x - s, y - s * 1.15);
    pb.line_to(x + s, y - s * 1.15);
    pb.move_to(x - s * 0.8, y);
    pb.line_to(x - s * 0.8, y - s * 1.15);
    pb.move_to(x + s * 0.8, y);
    pb.line_to(x + s * 0.8, y - s * 1.15);
    if let Some(p) = pb.finish() {
        line(pm, &p, &paint(paper), &stroke(lw * 3.0), None);
        line(pm, &p, &paint(pen), &stroke(lw * 1.1), None);
    }
}

fn draw_forest(ctx: &Ctx, pm: &mut Pixmap, crowns: &mut [(f32, f32, f32, i64)], lw: f32, paper: Color) {
    if crowns.is_empty() {
        return;
    }
    crowns.sort_by(|a, b| a.1.total_cmp(&b.1));
    let shape = |&(x, y, r, id): &(f32, f32, f32, i64)| {
        let pts = scallop_pts(x, y - r * 0.7, r, 7 + (rand01(id, 3) * 4.0) as u32, 0.16, rand01(id, 4) * std::f32::consts::TAU);
        pts_path(&wobble_pts(ctx, &pts, 0.3, 4.0, id as u64), true)
    };
    let mut all = PathBuilder::new();
    for c in crowns.iter() {
        if let Some(p) = shape(c) {
            all.push_path(&p);
        }
    }
    let Some(all) = all.finish() else { return };
    // 1) heavy outline of every crown, 2) paper fill of every crown on top → only the silhouette stays
    line(pm, &all, &paint(ink(1.0)), &stroke(lw * 2.6), None);
    // Winding, not EvenOdd: overlaps must stay filled or the inner outlines shine through
    pm.fill_path(&all, &paint(paper), tiny_skia::FillRule::Winding, tiny_skia::Transform::identity(), None);
    // 3) inside: the lower-right half of each crown as a light arc, plus a few shading strokes
    let mut arcs = PathBuilder::new();
    let mut shading = PathBuilder::new();
    for &(x, y, r, id) in crowns.iter() {
        let cy = y - r * 0.7;
        let a0 = -0.3 + rand01(id, 5) * 0.4;
        let steps = 10;
        for k in 0..=steps {
            let a = a0 + (k as f32 / steps as f32) * 2.4;
            let (px, py) = (x + r * a.cos(), cy + r * a.sin());
            if k == 0 { arcs.move_to(px, py) } else { arcs.line_to(px, py) }
        }
        for k in 0..3 {
            let a = 0.3 + 1.2 * rand01(id, 20 + k);
            let rr = r * (0.45 + 0.35 * rand01(id, 30 + k));
            let (px, py) = (x + rr * a.cos(), cy + rr * a.sin());
            shading.move_to(px, py);
            shading.line_to(px - r * 0.22, py + r * 0.15);
        }
    }
    if let Some(p) = arcs.finish() {
        line(pm, &p, &paint(ink(0.55)), &stroke(lw * 0.7), None);
    }
    if let Some(p) = shading.finish() {
        line(pm, &p, &paint(ink(0.45)), &stroke(lw * 0.6), None);
    }
}
