//! Design research: roof shapes from `data/processing/sql/roof_shape.sql`.
//!
//! Reads three tables (see that file for the sanitising rules):
//! - `roof_mass`       one roof per connected group of similar buildings (courtyards are holes)
//! - `roof_facet`      polygon planes with `aspect_deg` (downslope bearing, 0 = north, clockwise)
//! - `roof_shape_line` ridge / hip / valley / parapet lines
//!
//! The styles load and draw the roof data themselves (`load_roofs` in `style_kit.rs`,
//! `draw_roof_facets` in `style_ink.rs`, facet tones in `style_la.rs`). This module holds what they
//! share: the one light (`LIGHT_AZIMUTH_DEG`, `lit_factor`, `shadow_dir_px`) and the switch
//! `switched_off` (`SRK_ROOFS=off`, `0` or `false`; default on). Without the tables the styles fall
//! back to their own roof drawing.
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

/// The one light for every style: azimuth in degrees (0 = north, clockwise). North-west, so shaded
/// faces look south-east and cast shadows fall south-east.
pub const LIGHT_AZIMUTH_DEG: f64 = 315.0;

/// Light from the north-west: 1.0 for a facet facing the light, 0.0 facing away.
/// Used by the landscape-architecture and ink styles (their shadows fall south-east).
pub fn lit_factor(aspect_deg: f64) -> f32 {
    let d = (aspect_deg - LIGHT_AZIMUTH_DEG).to_radians();
    ((1.0 + d.cos()) / 2.0) as f32
}

/// Unit vector in pixel space (x right, y down) in which cast shadows fall, away from the light:
/// south-east for `LIGHT_AZIMUTH_DEG`. A face is in shade when its outward normal has a positive dot
/// product with it.
pub fn shadow_dir_px() -> (f32, f32) {
    let a = LIGHT_AZIMUTH_DEG.to_radians();
    ((-a.sin()) as f32, a.cos() as f32)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// One light for every style: a facet is in shade exactly when it faces the shadow direction.
    #[test]
    fn shade_follows_the_shadow_direction() {
        let (sx, sy) = shadow_dir_px();
        let diag = std::f32::consts::FRAC_1_SQRT_2;
        assert!((sx - diag).abs() < 1e-4 && (sy - diag).abs() < 1e-4, "shadow falls south-east, got {sx},{sy}");
        // bearing → pixel direction the facet faces (x east, y down): (sin b, -cos b)
        for b in [0.0f64, 90.0, 135.0, 180.0, 270.0, 315.0] {
            let r = b.to_radians();
            let (vx, vy) = (r.sin() as f32, -(r.cos()) as f32);
            let in_shade = vx * sx + vy * sy > 0.0;
            assert_eq!(in_shade, lit_factor(b) < 0.5, "bearing {b}");
        }
        assert!((lit_factor(LIGHT_AZIMUTH_DEG) - 1.0).abs() < 1e-6);
    }
}
