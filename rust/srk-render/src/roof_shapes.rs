//! Design research: roof shapes from `data/processing/sql/roof_shape.sql`.
//!
//! Reads three tables (see that file for the sanitising rules):
//! - `roof_mass`       one roof per connected group of similar buildings (courtyards are holes)
//! - `roof_facet`      polygon planes with `aspect_deg` (downslope bearing, 0 = north, clockwise)
//! - `roof_shape_line` ridge / hip / valley / parapet lines
//!
//! Switch: `SRK_ROOFS=0` turns the roof data off in both styles (default on). It is also off when
//! the tables are missing (older database), so the styles fall back to their own roof drawing.
//!
//! `--layers roofs` is the preview preset: paper, footprints, facets toned by aspect, lines.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use anyhow::Result;
use geo_types::{LineString, Polygon};
use postgres::Client;
use tiny_skia::{Color, FillRule, Mask, Pixmap, Transform};

use crate::sql_cache::PreparedCache;
use crate::style_kit::*;
use crate::tile::RenderExtent;

const PAPER_SEPIA: &str = "#F1E7CF";
const INK_SEPIA: &str = "#2B2620";

/// Light from the north-west (azimuth 315°): 1.0 for a facet facing the light, 0.0 facing away.
/// Used by the landscape-architecture style (its shadow falls south-east).
pub fn lit_factor(aspect_deg: f64) -> f32 {
    let d = (aspect_deg - 315.0).to_radians();
    ((1.0 + d.cos()) / 2.0) as f32
}

/// Ink style light comes from the south-west, so the north-east half of a roof is the shaded one
/// (the same half that carries the cross-hatch in `style_ink`).
pub fn ink_shaded(aspect_deg: f64) -> bool {
    ((aspect_deg - 45.0).to_radians()).cos() > 0.0
}

/// Roof data for one tile, indexed by building `osm_id` (a building belongs to the mass that
/// contains its id in `roof_mass.osm_ids`).
#[derive(Default)]
pub struct BuildingRoofs {
    /// facets of hipped / gabled masses: (polygon, aspect_deg)
    pub facets: HashMap<i64, Vec<(Polygon<f64>, f64)>>,
    /// ridge / hip / valley / parapet lines of the mass
    pub lines: HashMap<i64, Vec<(String, LineString<f64>)>>,
    /// buildings whose mass is a flat roof (no slope, parapet only)
    pub flat: HashSet<i64>,
}

impl BuildingRoofs {
    /// True when the roof data covers this building (its facets or its flat mass are known).
    pub fn covers(&self, id: i64) -> bool {
        self.flat.contains(&id) || self.facets.contains_key(&id)
    }
}

/// Roof data on for this process: `SRK_ROOFS` is not `0`/`off`/`false` and the tables exist.
pub fn enabled(client: &mut Client) -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        if matches!(std::env::var("SRK_ROOFS").ok().as_deref(), Some("0" | "off" | "false")) {
            return false;
        }
        client
            .query_one(
                "SELECT to_regclass('public.roof_mass') IS NOT NULL
                    AND to_regclass('public.roof_facet') IS NOT NULL
                    AND to_regclass('public.roof_shape_line') IS NOT NULL",
                &[],
            )
            .and_then(|r| r.try_get::<_, bool>(0))
            .unwrap_or(false)
    })
}

/// Loads facets, lines and flat masses for the extent of `ctx`.
pub fn load(ctx: &mut Ctx) -> Result<BuildingRoofs> {
    let mut out = BuildingRoofs::default();
    // one row per (building, facet): a mass is repeated for each building it contains
    let facets = ctx.polygons(
        "osm_id AS id, dir AS class, kind AS sub, aspect_deg AS num",
        "(SELECT ob.osm_id, f.dir, f.kind, f.aspect_deg, f.geom
          FROM roof_facet AS f
          JOIN roof_mass AS m USING (mass_id)
          CROSS JOIN LATERAL unnest(m.osm_ids) AS ob(osm_id)) AS rf",
        "",
    )?;
    for f in facets {
        out.facets.entry(f.id).or_default().push((f.geom, f.num));
    }
    let flat = ctx.polygons(
        "osm_id AS id, 'flat' AS class, 'flat' AS sub, 0::float8 AS num",
        "(SELECT ob.osm_id, m.geom
          FROM roof_mass AS m
          CROSS JOIN LATERAL unnest(m.osm_ids) AS ob(osm_id)
          WHERE m.kind = 'flat') AS rm",
        "",
    )?;
    out.flat.extend(flat.into_iter().map(|f| f.id));
    let lines = ctx.lines(
        "osm_id AS id, lclass AS class, '' AS sub, 0::float8 AS num",
        "(SELECT ob.osm_id, l.class AS lclass, l.geom
          FROM roof_shape_line AS l
          JOIN roof_mass AS m USING (mass_id)
          CROSS JOIN LATERAL unnest(m.osm_ids) AS ob(osm_id)) AS rl",
        "",
    )?;
    for l in lines {
        out.lines.entry(l.id).or_default().push((l.class, l.geom));
    }
    Ok(out)
}

/// Ink: facets of one building, clipped to its footprint (`mask` gives a fresh footprint mask).
/// Every facet gets the main slope hatch (along the downslope direction); shaded facets get a
/// second hatch along the ridge. `lift` moves the roof up for oblique free-standing buildings.
pub fn draw_ink_facets(
    ctx: &Ctx,
    pm: &mut Pixmap,
    facets: &[(Polygon<f64>, f64)],
    mask: &dyn Fn() -> Option<Mask>,
    bounds: (f32, f32, f32, f32),
    lift: f32,
    hatch_sp: f32,
    lw: f32,
    alpha_main: f32,
    ink: &dyn Fn(f32) -> Color,
) {
    let (x0, y0, x1, y1) = bounds;
    for (poly, aspect) in facets {
        let Some(fp) = poly_path_shifted(ctx, poly, 0.0, -lift) else { continue };
        let Some(mut m) = mask() else { continue };
        m.intersect_path(&fp, FillRule::EvenOdd, true, Transform::identity());
        // screen angle of a bearing vector is bearing - 90° (see style_ink's axis_px)
        let downslope = (*aspect - 90.0) as f32;
        if let Some(h) = hatch_path(ctx, hatch_sp, downslope, x0, y0, x1, y1) {
            line(pm, &h, &paint(ink(alpha_main)), &stroke(lw * 0.55), Some(&m));
        }
        if ink_shaded(*aspect) {
            if let Some(h) = hatch_path(ctx, hatch_sp * 1.3, *aspect as f32, x0, y0, x1, y1) {
                line(pm, &h, &paint(ink(0.38)), &stroke(lw * 0.5), Some(&m));
            }
        }
    }
}

/// Ink: ridge, hip, valley and parapet lines of one building. Hips and parapets only from z18
/// (plan detail); the ridge is always drawn.
pub fn draw_ink_lines(
    ctx: &Ctx,
    pm: &mut Pixmap,
    lines: &[(String, LineString<f64>)],
    mask: &dyn Fn() -> Option<Mask>,
    lift: f32,
    lw: f32,
    ink: &dyn Fn(f32) -> Color,
) {
    for (class, l) in lines {
        let (width, alpha) = match class.as_str() {
            "ridge" => (lw * 1.1, 0.9),
            "hip" | "valley" if ctx.z >= 18 => (lw * 0.6, 0.7),
            "parapet" if ctx.z >= 18 => (lw * 0.5, 0.5),
            _ => continue,
        };
        let pts: Vec<(f32, f32)> = line_pts(ctx, l).into_iter().map(|(x, y)| (x, y - lift)).collect();
        if let (Some(p), Some(m)) = (pts_path(&pts, false), mask()) {
            line(pm, &p, &paint(ink(alpha)), &stroke(width), Some(&m));
        }
    }
}

/// Landscape architecture: a light facet tone on the white roof, ridge hairlines only.
/// `shade` is 1 − `lit_factor` (NW light, matching the south-east shadow of the style).
pub fn draw_la_facets(
    ctx: &Ctx,
    pm: &mut Pixmap,
    facets: &[(Polygon<f64>, f64)],
    mask: &dyn Fn() -> Option<Mask>,
    tone: &dyn Fn(f32) -> Color,
) {
    for (poly, aspect) in facets {
        let Some(fp) = poly_path(ctx, poly) else { continue };
        let Some(mut m) = mask() else { continue };
        m.intersect_path(&fp, FillRule::EvenOdd, true, Transform::identity());
        let shade = 1.0 - lit_factor(*aspect);
        fill(pm, &fp, &paint(tone(0.03 + 0.10 * shade)), Some(&m));
    }
}

/// Landscape architecture: ridge hairlines of one building (z18+).
pub fn draw_la_ridges(
    ctx: &Ctx,
    pm: &mut Pixmap,
    lines: &[(String, LineString<f64>)],
    mask: &dyn Fn() -> Option<Mask>,
    color: Color,
) {
    if ctx.z < 18 {
        return;
    }
    for (_, l) in lines.iter().filter(|(c, _)| c == "ridge") {
        let pts = line_pts(ctx, l);
        if let (Some(p), Some(m)) = (pts_path(&pts, false), mask()) {
            line(pm, &p, &paint(with_alpha(color, 0.5)), &stroke(0.35), Some(&m));
        }
    }
}

/// A fresh footprint mask for a building path (tiny_skia masks are consumed by intersect).
pub fn footprint_mask(path: &tiny_skia::Path, w: u32, h: u32) -> Option<Mask> {
    let mut m = Mask::new(w, h)?;
    m.fill_path(path, FillRule::EvenOdd, true, Transform::identity());
    Some(m)
}

/// Preview preset `--layers roofs`.
pub fn render(client: &mut Client, prep: &mut PreparedCache, extent: RenderExtent, z: u32) -> Result<Pixmap> {
    let mut pm = Pixmap::new(extent.width_px, extent.height_px).expect("pixmap");
    let paper = hex(PAPER_SEPIA);
    let ink = hex(INK_SEPIA);
    pm.fill(paper);
    let mut ctx = Ctx { client, prep, extent, z, margin_m: 40.0 };

    let lw = ctx.m(0.16).clamp(if z <= 17 { 0.85 } else { 0.7 }, 1.6);

    let facets = ctx.polygons("mass_id::bigint AS id, kind AS class, dir AS sub, aspect_deg AS num", "roof_facet", "")?;
    for f in &facets {
        let shade = 1.0 - lit_factor(f.num);
        if let Some(p) = poly_path(&ctx, &f.geom) {
            fill(&mut pm, &p, &paint(with_alpha(ink, 0.05 + 0.30 * shade)), None);
        }
    }
    let masses = ctx.polygons("mass_id::bigint AS id, kind AS class, '' AS sub, n_buildings::float8 AS num", "roof_mass", "")?;
    for m in &masses {
        if let Some(path) = poly_path(&ctx, &m.geom) {
            line(&mut pm, &path, &paint(ink), &stroke(lw), None);
        }
    }
    let lines = ctx.lines("mass_id::bigint AS id, class, '' AS sub, 0::float8 AS num", "roof_shape_line", "")?;
    for (class, width) in [("parapet", 0.5_f32), ("hip", 0.7), ("valley", 0.7), ("ridge", 1.5)] {
        let mut pb = tiny_skia::PathBuilder::new();
        for l in lines.iter().filter(|l| l.class == class) {
            let pts = line_pts(&ctx, &l.geom);
            if let Some(p) = pts_path(&pts, false) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink), &stroke(lw * width), None);
        }
    }
    Ok(pm)
}
