//! Design research: roof shapes from `data/processing/sql/roof_shape.sql`.
//!
//! Reads three tables (see that file for the sanitising rules):
//! - `roof_mass`       one roof per connected group of similar buildings (courtyards are holes)
//! - `roof_facet`      polygon planes with `aspect_deg` (downslope bearing, 0 = north, clockwise)
//! - `roof_shape_line` ridge / hip / valley / parapet lines
//!
//! The styles load and draw the roof data themselves (`load_roofs` in `style_kit.rs`,
//! `draw_roof_facets` in `style_ink.rs`, facet tones in `style_la.rs`). This module holds what they
//! share: the light term `lit_factor` and the switch `switched_off` (`SRK_ROOFS=off`, `0` or
//! `false`; default on). Without the tables the styles fall back to their own roof drawing.
//!
//! `--layers roofs` is the preview preset: paper, footprints, facets toned by aspect, lines.

use anyhow::Result;
use postgres::Client;
use tiny_skia::Pixmap;

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

/// `SRK_ROOFS=off`, `0` or `false`: roof data switched off (ink, LA and the preview read this).
pub fn switched_off() -> bool {
    matches!(std::env::var("SRK_ROOFS").ok().as_deref(), Some("0" | "off" | "false"))
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
