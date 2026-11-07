//! Additions to the `la` preset (landscape-architecture plan): genus tree symbols, bridges,
//! refined play equipment and street furniture, water labels. Child module of `style_la`.

use anyhow::Result;
use tiny_skia::{BlendMode, Color, PathBuilder, Pixmap};

use super::Crown;
use crate::style_kit::*;

const LINE: &str = "#4E4D46";
const FURNITURE: &str = "#5F5E57";
const WATER: &str = "#A9BEBD";
const WATER_EDGE: &str = "#7E9896";
const SHADOW: &str = "#6C6B5A";

// ---------------------------------------------------------------------------------------------
// trees per genus

/// Plan symbol, default crown diameter (m) and palette slot for a genus. `None` → generic tree.
pub struct GenusSpec {
    pub variant: u8,
    pub default_d: f64,
    pub colour: usize,
}

/// Symbol ids ≥ 4 are drawn here; 0–3 are the generic symbols in `style_la::draw_crown`.
pub const V_TILIA: u8 = 4;
pub const V_ACER: u8 = 5;
pub const V_BETULA: u8 = 6;
pub const V_QUERCUS: u8 = 7;
pub const V_PLATANUS: u8 = 8;
pub const V_BLOSSOM: u8 = 9;
pub const V_SALIX: u8 = 10;
pub const V_CARPINUS: u8 = 11;
pub const V_CONIFER: u8 = 3;

pub fn genus_spec(genus: &str) -> Option<GenusSpec> {
    let g = genus.split([';', ' ']).next().unwrap_or("").to_ascii_lowercase();
    let (variant, default_d, colour) = match g.as_str() {
        "tilia" => (V_TILIA, 8.0, 0),
        "acer" => (V_ACER, 7.0, 5),
        "betula" => (V_BETULA, 6.0, 2),
        "quercus" => (V_QUERCUS, 12.0, 3),
        "platanus" => (V_PLATANUS, 13.0, 4),
        "prunus" | "malus" | "pyrus" | "sorbus" | "crataegus" | "cercis" | "magnolia" => (V_BLOSSOM, 4.0, 2),
        "salix" => (V_SALIX, 9.0, 1),
        "carpinus" | "fagus" | "ulmus" => (V_CARPINUS, 6.0, 1),
        "robinia" | "sophora" | "styphnolobium" | "gleditsia" | "fraxinus" => (1, 7.0, 0),
        "pinus" | "pseudotsuga" | "picea" | "abies" | "taxus" | "larix" | "thuja" => (V_CONIFER, 6.0, 3),
        _ => return None,
    };
    Some(GenusSpec { variant, default_d, colour })
}

/// Genus symbols. Same light model as the generic crowns: translucent NW-lit fill + darker line.
pub fn draw_genus_crown(pm: &mut Pixmap, c: &Crown, k: f32) {
    let dark = shade(c.colour, 0.72);
    let w = (c.r * 0.06).clamp(0.5, 1.2);
    let phase = rand01(c.seed, 1) * std::f32::consts::TAU;
    let tau = std::f32::consts::TAU;
    match c.variant {
        // lime: dense, fine-scalloped dome with an inner ring (the crown's dense core)
        V_TILIA => {
            let pts = scallop_pts(c.x, c.y, c.r, 18, 0.05, phase);
            if let Some(p) = pts_path(&pts, true) {
                fill(pm, &p, &super::sphere_paint(c, (0.6 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.85)), &stroke(w), None);
            }
            if c.r > 4.0 {
                let pts = scallop_pts(c.x, c.y, c.r * 0.55, 11, 0.07, phase + 0.3);
                if let Some(p) = pts_path(&pts, true) {
                    line(pm, &p, &paint(with_alpha(dark, 0.4)), &stroke(w * 0.7), None);
                }
            }
        }
        // maple: five to seven deep lobes, veins from the trunk into each lobe
        V_ACER => {
            let n = 5 + (rand01(c.seed, 6) * 3.0) as u32;
            let pts = scallop_pts(c.x, c.y, c.r, n, 0.16, phase);
            if let Some(p) = pts_path(&pts, true) {
                fill(pm, &p, &super::sphere_paint(c, (0.6 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.85)), &stroke(w), None);
            }
            if c.r > 4.0 {
                let mut pb = PathBuilder::new();
                for i in 0..n {
                    // scallop_pts puts lobe tips at phase + i/n·τ
                    let t = phase + i as f32 / n as f32 * tau;
                    pb.move_to(c.x, c.y);
                    pb.quad_to(
                        c.x + c.r * 0.45 * (t + 0.15).cos(),
                        c.y + c.r * 0.45 * (t + 0.15).sin(),
                        c.x + c.r * 0.8 * t.cos(),
                        c.y + c.r * 0.8 * t.sin(),
                    );
                }
                if let Some(p) = pb.finish() {
                    line(pm, &p, &paint(with_alpha(dark, 0.55)), &stroke(w * 0.7), None);
                }
            }
        }
        // birch: light, airy crown — pale wash, dashed rim, a stipple of leaf dots
        V_BETULA => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &paint(with_alpha(mix(c.colour, Color::WHITE, 0.25), 0.4 * k)), None);
                let mut s = stroke(w * 0.8);
                s.dash = tiny_skia::StrokeDash::new(vec![c.r * 0.22, c.r * 0.12], phase);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &s, None);
            }
            if c.r > 3.0 {
                let mut pb = PathBuilder::new();
                let n = (c.r * c.r * 0.2).clamp(5.0, 40.0) as i64;
                for i in 0..n {
                    let a = rand01(c.seed.wrapping_add(i), 31) * tau;
                    let d = rand01(c.seed.wrapping_add(i), 32).sqrt() * c.r * 0.85;
                    pb.push_circle(c.x + d * a.cos(), c.y + d * a.sin(), (c.r * 0.05).clamp(0.5, 1.1));
                }
                if let Some(p) = pb.finish() {
                    fill(pm, &p, &paint(with_alpha(dark, 0.45)), None);
                }
            }
        }
        // oak: broad irregular cloud of overlapping sub-crowns, darker and heavier
        V_QUERCUS => {
            // sub-crowns filled one by one into an opaque layer (no even-odd holes, overlaps do
            // not darken), composited translucent; the outer scallop gives the silhouette
            let n = 6;
            let mut subs = Vec::with_capacity(n + 1);
            for i in 0..n {
                let t = phase + i as f32 / n as f32 * tau;
                let rr = c.r * (0.42 + 0.1 * rand01(c.seed.wrapping_add(i as i64), 41));
                subs.push((c.x + (c.r - rr) * t.cos(), c.y + (c.r - rr) * t.sin(), rr));
            }
            subs.push((c.x, c.y, c.r * 0.5));
            let mut layer = Pixmap::new(pm.width(), pm.height()).expect("pixmap");
            let fillp = super::sphere_paint(c, 1.0);
            let mut pb = PathBuilder::new();
            for &(x, y, r) in &subs {
                if let Some(p) = PathBuilder::from_circle(x, y, r) {
                    fill(&mut layer, &p, &fillp, None);
                }
                pb.push_circle(x, y, r);
            }
            draw_layer(pm, &layer, (0.62 * k).min(1.0), BlendMode::SourceOver);
            if let Some(p) = pb.finish() {
                line(pm, &p, &paint(with_alpha(dark, 0.22)), &stroke(w * 0.6), None);
            }
            let pts = scallop_pts(c.x, c.y, c.r * 0.95, 6, 0.08, phase);
            if let Some(p) = pts_path(&pts, true) {
                line(pm, &p, &paint(with_alpha(dark, 0.85)), &stroke(w * 1.1), None);
            }
        }
        // plane: large, light disc, concentric ring and long radial branches
        V_PLATANUS => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &super::sphere_paint(c, (0.5 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
            let mut pb = PathBuilder::new();
            if c.r > 4.0 {
                pb.push_circle(c.x, c.y, c.r * 0.62);
            }
            let n = 9;
            for i in 0..n {
                let t = phase + i as f32 / n as f32 * tau;
                pb.move_to(c.x + c.r * 0.1 * t.cos(), c.y + c.r * 0.1 * t.sin());
                pb.line_to(c.x + c.r * 0.92 * t.cos(), c.y + c.r * 0.92 * t.sin());
            }
            if let Some(p) = pb.finish() {
                line(pm, &p, &paint(with_alpha(dark, 0.5)), &stroke(w * 0.7), None);
            }
        }
        // ornamental / blossom trees: small, round, ring of blossom dots
        V_BLOSSOM => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r) {
                fill(pm, &p, &super::sphere_paint(c, (0.6 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(w), None);
            }
            if c.r > 2.5 {
                let mut pb = PathBuilder::new();
                let n = 8;
                for i in 0..n {
                    let t = phase + i as f32 / n as f32 * tau;
                    pb.push_circle(c.x + c.r * 0.62 * t.cos(), c.y + c.r * 0.62 * t.sin(), (c.r * 0.1).clamp(0.5, 1.4));
                }
                if let Some(p) = pb.finish() {
                    fill(pm, &p, &paint(with_alpha(hex("#F4ECE6"), 0.9)), None);
                    line(pm, &p, &paint(with_alpha(dark, 0.5)), &stroke(0.4), None);
                }
            }
        }
        // willow: hanging fringe — many short strokes along the rim
        V_SALIX => {
            if let Some(p) = PathBuilder::from_circle(c.x, c.y, c.r * 0.9) {
                fill(pm, &p, &super::sphere_paint(c, (0.5 * k).min(1.0)), None);
            }
            let n = (c.r * 3.0).clamp(16.0, 70.0) as i32;
            let mut pb = PathBuilder::new();
            for i in 0..n {
                let t = phase + i as f32 / n as f32 * tau;
                let r0 = c.r * (0.55 + 0.15 * rand01(c.seed.wrapping_add(i64::from(i)), 51));
                pb.move_to(c.x + r0 * t.cos(), c.y + r0 * t.sin());
                pb.line_to(c.x + c.r * (t + 0.05).cos(), c.y + c.r * (t + 0.05).sin());
            }
            if let Some(p) = pb.finish() {
                line(pm, &p, &paint(with_alpha(dark, 0.7)), &stroke(w * 0.7), None);
            }
        }
        // hornbeam / beech / elm: compact, double scallop
        _ => {
            let pts = scallop_pts(c.x, c.y, c.r, 12, 0.09, phase);
            if let Some(p) = pts_path(&pts, true) {
                fill(pm, &p, &super::sphere_paint(c, (0.66 * k).min(1.0)), None);
                line(pm, &p, &paint(with_alpha(dark, 0.85)), &stroke(w), None);
            }
            if c.r > 4.0 {
                let pts = scallop_pts(c.x, c.y, c.r * 0.68, 9, 0.12, phase + 0.5);
                if let Some(p) = pts_path(&pts, true) {
                    line(pm, &p, &paint(with_alpha(dark, 0.45)), &stroke(w * 0.7), None);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// roof colours

/// SQL expression for the mapped `roof:colour`, or `''` when the import predates the column (it
/// was added to `osm_import.lua` on 2026-10-16). `building:colour` is imported too but not used:
/// it is the facade colour, which a plan view does not show.
pub fn roof_colour_sql(client: &mut postgres::Client) -> &'static str {
    static HAS: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    let has = *HAS.get_or_init(|| {
        client
            .query_one("SELECT count(*) FROM information_schema.columns WHERE table_name = 'building' AND column_name = 'roof:colour'", &[])
            .map(|r| r.get::<_, i64>(0) == 1)
            .unwrap_or(false)
    });
    if has { r#"COALESCE("roof:colour", '')"# } else { "''::text" }
}

/// What a mapped roof colour means for the plan. The mission keeps buildings white with the odd
/// red roof, so the data only decides *where* the accents go, not a palette of its own.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum RoofTone {
    /// saturated red/orange/brown: terracotta accent (small buildings only, see style_la)
    Red,
    /// saturated green: green roof, a very pale sage tint
    Green,
    /// anything else that parses (greys, whites, muted tones, blues): plain white volume, and
    /// never the random red accent
    Plain,
}

pub fn roof_tone(tag: &str) -> Option<RoofTone> {
    let t = tag.trim().to_ascii_lowercase();
    if t.is_empty() {
        return None;
    }
    match t.as_str() {
        "red" | "darkred" | "brown" | "maroon" | "orange" | "terracotta" | "brick" | "sienna" | "firebrick" | "chocolate"
        | "darkbrown" | "saddlebrown" | "indianred" | "tomato" => return Some(RoofTone::Red),
        "green" | "darkgreen" | "olive" | "olivedrab" | "forestgreen" => return Some(RoofTone::Green),
        _ => {}
    }
    let Some(h) = t.strip_prefix('#').filter(|h| h.len() == 6) else {
        // other colour names (grey, white, black, silver …)
        return t.chars().all(|c| c.is_ascii_alphabetic()).then_some(RoofTone::Plain);
    };
    let v = u32::from_str_radix(h, 16).ok()?;
    let (r, g, b) = (((v >> 16) & 255) as f32, ((v >> 8) & 255) as f32, (v & 255) as f32);
    let (mx, mn) = (r.max(g).max(b), r.min(g).min(b));
    // saturation relative to the brightest channel: khaki and taupe (#948975, #A29893) stay plain
    let sat = if mx > 0.0 { (mx - mn) / mx } else { 0.0 };
    Some(if sat < 0.3 {
        RoofTone::Plain
    } else if r >= g && r >= b {
        RoofTone::Red
    } else if g >= r && g >= b {
        RoofTone::Green
    } else {
        RoofTone::Plain
    })
}

#[cfg(test)]
#[test]
fn roof_tone_classes() {
    use RoofTone::*;
    for (tag, want) in [
        ("#CD8A73", Some(Red)),
        ("#c56b60", Some(Red)),
        ("red", Some(Red)),
        ("#4A5624", Some(Green)),
        ("#948975", Some(Plain)),
        ("#A29893", Some(Plain)),
        ("#7382AD", Some(Plain)),
        ("gray", Some(Plain)),
        ("white", Some(Plain)),
        ("", None),
        ("#12", None),
    ] {
        assert_eq!(roof_tone(tag), want, "{tag}");
    }
}

// ---------------------------------------------------------------------------------------------
// bridges

/// White deck with a crisp edge and a soft shadow onto whatever lies below (water, rails, roads).
/// Drawn between the ground-level and the raised street areas.
pub fn draw_bridges(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    let bridges = ctx.polygons(
        "osm_id AS id, COALESCE(name, '') AS class, NULL::text AS sub, GREATEST(COALESCE(layer, 1), 1)::float8 AS num",
        "bridge",
        "ORDER BY COALESCE(layer, 1)",
    )?;
    if bridges.is_empty() {
        return Ok(());
    }
    let mut layer = new_layer(ctx);
    let mut pb = PathBuilder::new();
    for f in &bridges {
        let off = ctx.m(2.6 * f.num.min(3.0));
        for k in [0.4f32, 0.75, 1.0] {
            if let Some(p) = poly_path_shifted(ctx, &f.geom, off * k, off * k * 0.75) {
                pb.push_path(&p);
            }
        }
    }
    if let Some(p) = pb.finish() {
        fill(&mut layer, &p, &paint(hex(SHADOW)), None);
    }
    blur_layer(&mut layer, ctx.m(0.5).max(1.0) as usize);
    draw_layer(pm, &layer, 0.5, BlendMode::Multiply);
    for f in &bridges {
        let Some(p) = poly_path(ctx, &f.geom) else { continue };
        fill(pm, &p, &paint(hex("#F6F5F0")), None);
        line(pm, &p, &paint(hex(LINE)), &stroke(ctx.m(0.2).clamp(0.7, 1.4)), None);
    }
    Ok(())
}

/// Parapet line drawn after the street surfaces: a thin inner edge so the deck reads raised.
pub fn draw_bridge_edges(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    if ctx.z < 17 {
        return Ok(());
    }
    let bridges = ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "bridge", "")?;
    for f in &bridges {
        if let Some(p) = poly_path(ctx, &f.geom) {
            line(pm, &p, &paint(hex(LINE)), &stroke(ctx.m(0.2).clamp(0.7, 1.4)), None);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// play equipment

fn outlined(pm: &mut Pixmap, p: &tiny_skia::Path, fill_col: Color, w: f32) {
    fill(pm, p, &paint(fill_col), None);
    line(pm, p, &paint(hex(FURNITURE)), &stroke(w), None);
}

/// Play areas: sandpits with a timber edge, water basins, white structures with outline;
/// line equipment (slides, beams, swings) as small plan drawings; node equipment as symbols.
pub fn draw_play(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    let thin = ctx.m(0.06).clamp(0.5, 0.9);
    let pg = ctx.polygons("osm_id AS id, COALESCE(playground, '') AS class, NULL::text AS sub, 0::float8 AS num", "playground_polygon", "")?;
    for f in &pg {
        let Some(p) = poly_path(ctx, &f.geom) else { continue };
        match f.class.as_str() {
            "sandpit" => {
                fill(pm, &p, &paint(hex("#E9E1CB")), None);
                // timber edging: warm band + fine line
                line(pm, &p, &paint(hex("#B9A988")), &stroke(ctx.m(0.25).max(1.0)), None);
                line(pm, &p, &paint(hex(FURNITURE)), &stroke(thin * 0.8), None);
            }
            "water_basin" | "splash_pad" => {
                fill(pm, &p, &paint(hex(WATER)), None);
                line(pm, &p, &paint(hex(WATER_EDGE)), &stroke(thin), None);
            }
            "trampoline" => outlined(pm, &p, hex("#8C8B7E"), thin),
            "mound" => {
                fill(pm, &p, &paint(with_alpha(hex("#A6A48C"), 0.35)), None);
                line(pm, &p, &paint(with_alpha(hex("#85835F"), 0.7)), &stroke(thin), None);
            }
            "playhouse" | "structure" | "platform" | "climbingframe" => {
                outlined(pm, &p, Color::WHITE, thin);
                // roofed / platform structures get the plan cross
                if matches!(f.class.as_str(), "playhouse" | "platform") && ctx.z >= 19 {
                    let pts = poly_rings_px(ctx, &f.geom);
                    if let Some(r) = pts.first() {
                        let (x0, y0, x1, y1) = bbox_px(r);
                        let mut pb = PathBuilder::new();
                        pb.move_to(x0, y0);
                        pb.line_to(x1, y1);
                        pb.move_to(x0, y1);
                        pb.line_to(x1, y0);
                        if let (Some(c), Some(m)) = (pb.finish(), mask_of(ctx, &[&f.geom])) {
                            line(pm, &c, &paint(with_alpha(hex(FURNITURE), 0.45)), &stroke(0.5), Some(&m));
                        }
                    }
                }
            }
            _ => outlined(pm, &p, Color::WHITE, thin),
        }
    }
    // unclipped: slide rungs and swing seats are placed from the line ends
    let pgw = ctx.lines_full("osm_id AS id, COALESCE(playground, '') AS class, NULL::text AS sub, 0::float8 AS num", "playground_way", "")?;
    let dark = hex(FURNITURE);
    for f in &pgw {
        let pts = line_pts(ctx, &f.geom);
        let Some(p) = pts_path(&pts, false) else { continue };
        match f.class.as_str() {
            // slide: chute as a white band with outline, ladder rungs at the start
            "slide" => {
                let w = ctx.m(0.55).max(2.0);
                line(pm, &p, &paint(dark), &stroke(w + 1.4), None);
                line(pm, &p, &paint(hex("#FFFFFF")), &stroke(w), None);
                if ctx.z >= 19 {
                    let mut pb = PathBuilder::new();
                    for (x, y, a) in along(&pts, ctx.m(0.35).max(2.0), 0.0).into_iter().take(3) {
                        let (nx, ny) = (-a.sin() * w * 0.5, a.cos() * w * 0.5);
                        pb.move_to(x - nx, y - ny);
                        pb.line_to(x + nx, y + ny);
                    }
                    if let Some(r) = pb.finish() {
                        line(pm, &r, &paint(dark), &stroke(0.6), None);
                    }
                }
            }
            // swing frame: beam with seats hanging off it
            "swing" | "basketswing" => {
                line(pm, &p, &paint(dark), &stroke(ctx.m(0.15).max(1.0)), None);
                draw_seats(ctx, pm, &pts, f.class == "basketswing");
            }
            "water_channel" | "water_stream" => {
                line(pm, &p, &paint(hex(WATER_EDGE)), &stroke(ctx.m(0.5).max(1.6) + 1.0), None);
                line(pm, &p, &paint(hex(WATER)), &stroke(ctx.m(0.5).max(1.6)), None);
            }
            "ropebridge" => {
                let w = ctx.m(0.6).max(2.0);
                line(pm, &p, &paint(dark), &stroke(w + 1.0), None);
                line(pm, &p, &paint(hex("#E9E1CB")), &stroke(w), None);
            }
            // beams, bars: thin dark line with end posts
            _ => {
                line(pm, &p, &paint(dark), &stroke(ctx.m(0.12).max(0.8)), None);
                if ctx.z >= 19 {
                    let mut pb = PathBuilder::new();
                    for &(x, y) in [pts.first(), pts.last()].into_iter().flatten() {
                        pb.push_circle(x, y, ctx.m(0.12).max(0.9));
                    }
                    if let Some(c) = pb.finish() {
                        fill(pm, &c, &paint(dark), None);
                    }
                }
            }
        }
    }
    if ctx.z < 18 {
        return Ok(());
    }
    let pgn = ctx.points("osm_id AS id, COALESCE(playground, '') AS class, NULL::text AS sub, 0::float8 AS num", "playground_node", "")?;
    for f in &pgn {
        let (x, y) = ctx.px(f.geom.0);
        // no orientation in the data: a stable angle per object
        let ang = rand01(f.id, 61) * std::f32::consts::PI;
        match f.class.as_str() {
            "swing" | "basketswing" => {
                let l = ctx.m(1.6);
                let (c, s) = (ang.cos() * l, ang.sin() * l);
                let pts = vec![(x - c, y - s), (x + c, y + s)];
                if let Some(p) = pts_path(&pts, false) {
                    line(pm, &p, &paint(dark), &stroke(ctx.m(0.15).max(1.0)), None);
                }
                draw_seats(ctx, pm, &pts, f.class == "basketswing");
            }
            "seesaw" => {
                if let Some(p) = rect_rot(x, y, ctx.m(3.0), ctx.m(0.3).max(1.2), ang) {
                    outlined(pm, &p, Color::WHITE, 0.6);
                }
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.2).max(1.0)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            "springy" | "spring_board" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.4).max(1.6)) {
                    outlined(pm, &p, Color::WHITE, 0.6);
                }
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.1).max(0.6)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            "table" | "sand_pulley" | "water_barrier" | "sandpit_table" => {
                if let Some(p) = rect_rot(x, y, ctx.m(1.0).max(2.5), ctx.m(0.7).max(1.8), ang) {
                    outlined(pm, &p, Color::WHITE, 0.6);
                }
            }
            "roundabout" | "spinning_disc" | "rotator" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(1.0).max(2.0)) {
                    outlined(pm, &p, Color::WHITE, 0.6);
                }
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.15).max(0.6)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            "water_pump" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.35).max(1.4)) {
                    fill(pm, &p, &paint(hex(WATER)), None);
                    line(pm, &p, &paint(hex(WATER_EDGE)), &stroke(0.6), None);
                }
            }
            // posts, poles, ladders: small dark dot
            "climbing_pole" | "ladder" | "pole" | "horizontal_bar" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.12).max(0.9)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            _ => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.4).max(1.5)) {
                    outlined(pm, &p, Color::WHITE, 0.6);
                }
            }
        }
    }
    Ok(())
}

/// Swing seats: two flat seats (or one basket) hanging off a beam, drawn as small rectangles.
fn draw_seats(ctx: &Ctx, pm: &mut Pixmap, pts: &[(f32, f32)], basket: bool) {
    if ctx.z < 18 || pts.len() < 2 {
        return;
    }
    let (a, b) = (pts[0], pts[pts.len() - 1]);
    let ang = (b.1 - a.1).atan2(b.0 - a.0);
    let dark = hex(FURNITURE);
    let ts: &[f32] = if basket { &[0.5] } else { &[0.3, 0.7] };
    for &t in ts {
        let (x, y) = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
        let p = if basket {
            PathBuilder::from_circle(x, y, ctx.m(0.5).max(1.6))
        } else {
            rect_rot(x, y, ctx.m(0.45).max(1.6), ctx.m(0.2).max(1.0), ang)
        };
        if let Some(p) = p {
            fill(pm, &p, &paint(Color::WHITE), None);
            line(pm, &p, &paint(dark), &stroke(0.6), None);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// street furniture

/// Benches with their backrest side, bicycle stands as U-shapes, fountains and pumps as water.
pub fn draw_furniture(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    // fountains (areas): water basin with a double rim
    let fountains = ctx.polygons("osm_id AS id, class, NULL::text AS sub, 0::float8 AS num", "feature_polygon WHERE class = 'fountain'", "")?;
    for f in &fountains {
        let Some(p) = poly_path(ctx, &f.geom) else { continue };
        line(pm, &p, &paint(hex("#E4E2DA")), &stroke(ctx.m(0.8).max(2.0)), None);
        fill(pm, &p, &paint(hex(WATER)), None);
        line(pm, &p, &paint(hex(WATER_EDGE)), &stroke(ctx.m(0.12).max(0.7)), None);
        line(pm, &p, &paint(hex(LINE)), &stroke(ctx.m(0.08).max(0.5)), None);
    }
    if ctx.z < 18 {
        return Ok(());
    }
    // bicycle stands carry no direction: orient them across the nearest street line
    let furniture = ctx.points(
        "id, class, sub, num",
        r#"(SELECT f.osm_id AS id, f.class,
                   CASE WHEN f.class = 'bicycle_parking' THEN COALESCE(f.capacity, 0)::text ELSE COALESCE(f.subclass, '') END AS sub,
                   CASE WHEN f.direction IS NOT NULL THEN f.direction
                        WHEN f.class = 'bicycle_parking' THEN
                          COALESCE((SELECT 1000 + degrees(ST_Azimuth(
                              ST_LineInterpolatePoint(h.geom, GREATEST(ST_LineLocatePoint(h.geom, f.geom) - 0.02, 0)),
                              ST_LineInterpolatePoint(h.geom, LEAST(ST_LineLocatePoint(h.geom, f.geom) + 0.02, 1))))
                            FROM highway h WHERE h.type = 'road' AND ST_GeometryType(h.geom) = 'ST_LineString'
                            ORDER BY h.geom <-> f.geom LIMIT 1), -1)
                        ELSE -1 END::float8 AS num,
                   f.geom
            FROM feature_node f
            WHERE f.class IN ('bench', 'waste_basket', 'bicycle_parking', 'street_lamp', 'table_tennis', 'drinking_water',
                              'water_well', 'fountain', 'picnic_table')
              AND f.geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)) q"#,
        "",
    )?;
    let dark = hex(FURNITURE);
    for f in &furniture {
        let (x, y) = ctx.px(f.geom.0);
        let known = f.num >= 0.0;
        let ang = if known && f.num < 1000.0 { (f.num as f32).to_radians() } else { 0.0 };
        match f.class.as_str() {
            "bench" => {
                let (w, h) = (ctx.m(1.8).max(3.0), ctx.m(0.5).max(1.2));
                if let Some(p) = rect_rot(x, y, w, h, ang) {
                    fill(pm, &p, &paint(Color::WHITE), None);
                    line(pm, &p, &paint(dark), &stroke(0.6), None);
                }
                // backrest on the side opposite the view direction (local +y), only when known
                if known && f.sub.contains("backrest_yes") {
                    let (c, s) = (ang.cos(), ang.sin());
                    let (bx, by) = (x - s * h * 0.5, y + c * h * 0.5);
                    let mut pb = PathBuilder::new();
                    pb.move_to(bx - c * w * 0.5, by - s * w * 0.5);
                    pb.line_to(bx + c * w * 0.5, by + s * w * 0.5);
                    if let Some(p) = pb.finish() {
                        line(pm, &p, &paint(dark), &stroke(ctx.m(0.14).max(1.2)), None);
                    }
                }
            }
            "picnic_table" => {
                let (w, h) = (ctx.m(1.9).max(3.0), ctx.m(0.8).max(1.6));
                let (c, s) = (ang.cos(), ang.sin());
                for d in [-1.0f32, 1.0] {
                    let o = h * 0.5 + ctx.m(0.35).max(0.8);
                    if let Some(p) = rect_rot(x - s * o * d, y + c * o * d, w, ctx.m(0.3).max(0.8), ang) {
                        fill(pm, &p, &paint(Color::WHITE), None);
                        line(pm, &p, &paint(dark), &stroke(0.5), None);
                    }
                }
                if let Some(p) = rect_rot(x, y, w, h, ang) {
                    fill(pm, &p, &paint(Color::WHITE), None);
                    line(pm, &p, &paint(dark), &stroke(0.6), None);
                }
            }
            "table_tennis" => {
                if let Some(p) = rect_rot(x, y, ctx.m(2.7), ctx.m(1.5), ang) {
                    fill(pm, &p, &paint(Color::WHITE), None);
                    line(pm, &p, &paint(dark), &stroke(0.7), None);
                }
                // net
                let (c, s) = (ang.cos(), ang.sin());
                let h = ctx.m(0.85);
                let mut pb = PathBuilder::new();
                pb.move_to(x + s * h, y - c * h);
                pb.line_to(x - s * h, y + c * h);
                if let Some(p) = pb.finish() {
                    line(pm, &p, &paint(dark), &stroke(0.6), None);
                }
            }
            "waste_basket" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.3).max(1.0)) {
                    fill(pm, &p, &paint(dark), None);
                }
            }
            "drinking_water" | "water_well" | "fountain" => {
                let r = if f.class == "fountain" { ctx.m(1.5).max(3.0) } else { ctx.m(0.45).max(1.6) };
                if let Some(p) = PathBuilder::from_circle(x, y, r) {
                    fill(pm, &p, &paint(hex(WATER)), None);
                    line(pm, &p, &paint(hex(WATER_EDGE)), &stroke(0.7), None);
                }
                // Berlin street pumps: the pump body as a dark square next to the water dot
                if f.class == "water_well" {
                    if let Some(p) = rect_rot(x, y, r * 0.8, r * 0.8, 0.0) {
                        fill(pm, &p, &paint(dark), None);
                    }
                }
            }
            "street_lamp" => {
                if let Some(p) = PathBuilder::from_circle(x, y, ctx.m(0.25).max(0.9)) {
                    line(pm, &p, &paint(with_alpha(dark, 0.8)), &stroke(0.6), None);
                }
            }
            // bicycle stands: a row of U-shapes across the street direction
            _ => {
                // capacity counts bikes; one stand takes two
                let n = f.sub.parse::<i32>().ok().filter(|c| *c > 0).map(|c| (c + 1) / 2).unwrap_or(2).clamp(1, 6);
                // azimuth (cw from north, +1000 marker) → screen angle of the street
                let along_a = if known { ((f.num - 1000.0) as f32 - 90.0).to_radians() } else { 0.0 };
                let across_a = along_a + std::f32::consts::FRAC_PI_2;
                let step = ctx.m(1.0).max(2.5);
                let (ux, uy) = (along_a.cos(), along_a.sin());
                let (vx, vy) = (across_a.cos(), across_a.sin());
                let (half_w, depth) = (ctx.m(0.25).max(0.8), ctx.m(0.4).max(1.4));
                let mut pb = PathBuilder::new();
                for i in 0..n {
                    let o = (i as f32 - (n - 1) as f32 * 0.5) * step;
                    let (cx, cy) = (x + ux * o, y + uy * o);
                    // U opening towards +v
                    pb.move_to(cx - ux * half_w + vx * depth, cy - uy * half_w + vy * depth);
                    pb.line_to(cx - ux * half_w - vx * depth * 0.4, cy - uy * half_w - vy * depth * 0.4);
                    pb.quad_to(cx - vx * depth, cy - vy * depth, cx + ux * half_w - vx * depth * 0.4, cy + uy * half_w - vy * depth * 0.4);
                    pb.line_to(cx + ux * half_w + vx * depth, cy + uy * half_w + vy * depth);
                }
                if let Some(p) = pb.finish() {
                    line(pm, &p, &paint(with_alpha(dark, 0.9)), &stroke(ctx.m(0.06).clamp(0.6, 1.0)), None);
                }
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// water names

fn font_db() -> std::sync::Arc<resvg::usvg::fontdb::Database> {
    static DB: std::sync::OnceLock<std::sync::Arc<resvg::usvg::fontdb::Database>> = std::sync::OnceLock::new();
    DB.get_or_init(|| {
        let mut db = resvg::usvg::fontdb::Database::new();
        db.load_system_fonts();
        std::sync::Arc::new(db)
    })
    .clone()
}

/// Names of ponds and basins in italic, in the bank colour, centred on the water (cartographic
/// convention: water italic, land upright). Skipped when the name would not fit the surface.
pub fn draw_water_labels(ctx: &mut Ctx, pm: &mut Pixmap) -> Result<()> {
    if ctx.z < 17 {
        return Ok(());
    }
    let from = r#"(SELECT osm_id, name, ST_Area(geom) AS a, ST_PointOnSurface(geom) AS geom FROM water_body
                   WHERE name IS NOT NULL AND geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)) q"#;
    let pts = ctx.points("osm_id AS id, name AS class, NULL::text AS sub, a::float8 AS num", from, "")?;
    let mpp = ctx.extent.metres_per_px();
    let mut texts = String::new();
    for f in &pts {
        let area_px = f.num / (mpp * mpp);
        let size = (10.5 * (area_px / 4000.0).powf(0.1) as f32).clamp(10.0, 15.0);
        let est = f.class.chars().count() as f32 * size * 0.62;
        if f64::from(est) > area_px.sqrt() * 2.2 {
            continue;
        }
        let (x, y) = ctx.px(f.geom.0);
        let name = f.class.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
        texts.push_str(&format!("<text x=\"{x:.1}\" y=\"{y:.1}\" font-size=\"{size:.1}\" text-anchor=\"middle\">{name}</text>"));
    }
    if texts.is_empty() {
        return Ok(());
    }
    let (w, h) = (ctx.extent.width_px, ctx.extent.height_px);
    let svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
<g font-family="Avenir Next" font-style="italic" font-weight="500" letter-spacing="0.6" fill="#4F6866"
   stroke="#BFD0CE" stroke-width="2.4" stroke-linejoin="round" paint-order="stroke" dominant-baseline="central">{texts}</g></svg>"##
    );
    let mut opts = resvg::usvg::Options::default();
    opts.fontdb = font_db();
    let Ok(tree) = resvg::usvg::Tree::from_str(&svg, &opts) else { return Ok(()) };
    let Some(mut layer) = resvg::tiny_skia::Pixmap::new(w, h) else { return Ok(()) };
    resvg::render(&tree, resvg::tiny_skia::Transform::identity(), &mut layer.as_mut());
    if let Some(ours) = tiny_skia::IntSize::from_wh(w, h).and_then(|sz| Pixmap::from_vec(layer.take(), sz)) {
        pm.draw_pixmap(0, 0, ours.as_ref(), &tiny_skia::PixmapPaint::default(), tiny_skia::Transform::identity(), None);
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// legend

/// Tree symbol legend: `SRK_LA_LEGEND=out.png cargo test --release la_tree_legend -- --ignored`
/// (labels are added afterwards, see docs/design-research/01-landscape-architecture/README.md).
#[cfg(test)]
mod tests {
    use super::*;

    pub const LEGEND: [&str; 12] =
        ["Tilia", "Acer", "Betula", "Quercus", "Platanus", "Prunus", "Salix", "Carpinus", "Robinia", "Pinus", "", ""];

    #[test]
    #[ignore]
    fn la_tree_legend() {
        let out = std::env::var("SRK_LA_LEGEND").unwrap_or_else(|_| "/tmp/la-tree-legend.png".into());
        let (cell, cols) = (120u32, 6u32);
        let rows = (LEGEND.len() as u32).div_ceil(cols);
        let mut pm = Pixmap::new(cell * cols, cell * rows).unwrap();
        pm.fill(hex("#EAE9E3"));
        let px_per_m = 6.0f32;
        let palette = super::super::crown_palette();
        let mut crowns = Vec::new();
        for (i, g) in LEGEND.iter().enumerate() {
            let (cx, cy) = ((i as u32 % cols * cell + cell / 2) as f32, (i as u32 / cols * cell + cell / 2 - 8) as f32);
            let (variant, colour, d) = match genus_spec(g) {
                Some(s) => (s.variant, palette[s.colour], s.default_d as f32),
                None => ((i - 10) as u8 * 2, palette[i % 6], 7.0),
            };
            crowns.push(Crown { x: cx, y: cy, r: (d / 2.0 * px_per_m).min(cell as f32 * 0.4), variant, colour: hex(colour), seed: 17 + i as i64 });
        }
        let mut sh = Pixmap::new(pm.width(), pm.height()).unwrap();
        let mut pb = PathBuilder::new();
        for c in &crowns {
            pb.push_circle(c.x + c.r * 0.35, c.y + c.r * 0.28, c.r);
        }
        fill(&mut sh, &pb.finish().unwrap(), &paint(hex(SHADOW)), None);
        blur_layer(&mut sh, 4);
        draw_layer(&mut pm, &sh, 0.26, BlendMode::Multiply);
        for c in &crowns {
            super::super::draw_crown(&mut pm, c, 1.0);
        }
        pm.save_png(&out).unwrap();
    }
}
