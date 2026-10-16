//! Extra drawing for the `ink` preset (see `style_ink.rs`): bridges, landmark icons other than
//! the church spire, and small upright street-furniture glyphs.

use anyhow::Result;
use geo_types::Polygon;
use tiny_skia::{Color, PathBuilder, Pixmap};

use crate::style_kit::*;
use crate::style_la::point_in_polygon;

// ---------------------------------------------------------------- bridges

/// Bridge decks (`bridge` table) with the long axis (azimuth of the oriented envelope).
pub fn bridges(ctx: &mut Ctx) -> Result<Vec<Feature<Polygon<f64>>>> {
    let from = r#"(
        SELECT b.osm_id, b.geom,
          CASE WHEN ST_Distance(e.p1, e.p2) >= ST_Distance(e.p2, e.p3)
               THEN degrees(ST_Azimuth(e.p1, e.p2)) ELSE degrees(ST_Azimuth(e.p2, e.p3)) END AS axis
        FROM bridge b,
        LATERAL (
          SELECT ST_PointN(ST_ExteriorRing(oe), 1) p1, ST_PointN(ST_ExteriorRing(oe), 2) p2, ST_PointN(ST_ExteriorRing(oe), 3) p3
          FROM (SELECT ST_OrientedEnvelope(b.geom) AS oe) q
          WHERE GeometryType(oe) = 'POLYGON'
        ) e
        WHERE b.geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)
          -- only real crossings: rails, water, or a lower road under a deck of some size
          -- (tiny courtyard ramps and light-well covers would read as stray heavy lines)
          AND (EXISTS (SELECT 1 FROM railway_way r WHERE ST_Intersects(r.geom, b.geom))
               OR EXISTS (SELECT 1 FROM water_body w WHERE ST_Intersects(w.geom, b.geom))
               OR EXISTS (SELECT 1 FROM waterway w WHERE ST_Intersects(w.geom, b.geom))
               OR (ST_Area(b.geom) >= 100 AND EXISTS (
                     SELECT 1 FROM highway h WHERE ST_Crosses(h.geom, b.geom)
                       AND COALESCE(h.layer, 0) < COALESCE(b.layer, 1) AND (h.bridge IS NULL OR h.bridge = 'no'))))
      ) bb"#;
    ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, COALESCE(axis, 0)::float8 AS num", from, "")
}

/// Pixel angle (radians) of a map azimuth in degrees (0 = north, clockwise).
fn azimuth_px(az_deg: f64) -> f32 {
    let a = (az_deg as f32).to_radians();
    (-(a.cos())).atan2(a.sin())
}

/// Paper fill of every deck, so rails and water below are hidden.
pub fn draw_bridge_decks(ctx: &Ctx, pm: &mut Pixmap, decks: &[Feature<Polygon<f64>>], paper: Color) {
    for f in decks {
        if let Some(p) = poly_path(ctx, &f.geom) {
            fill(pm, &p, &paint(paper), None);
        }
    }
}

/// Parapets: heavy lines along the long sides of each deck with flared wing walls at both
/// ends (the old-map bridge sign), plus a hatched shadow strip below the south parapet.
pub fn draw_bridge_parapets(ctx: &Ctx, pm: &mut Pixmap, decks: &[Feature<Polygon<f64>>], lw: f32, pen: Color) {
    let flare = ctx.m(1.4).clamp(3.0, 12.0);
    let shadow = ctx.m(1.6).clamp(3.0, 14.0);
    for f in decks {
        let ax = azimuth_px(f.num);
        let (ux, uy) = (ax.cos(), ax.sin());
        let Some(ring) = poly_rings_px(ctx, &f.geom).into_iter().next() else { continue };
        if ring.len() < 4 {
            continue;
        }
        let (bx0, by0, bx1, by1) = bbox_px(&ring);
        if (bx1 - bx0).max(by1 - by0) < 6.0 {
            continue;
        }
        let (cx, cy) = ((bx0 + bx1) / 2.0, (by0 + by1) / 2.0);
        // edges parallel to the axis, chained into runs
        let n = ring.len() - 1;
        let parallel: Vec<bool> = (0..n)
            .map(|i| {
                let (a, b) = (ring[i], ring[i + 1]);
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let len = (dx * dx + dy * dy).sqrt();
                len > 0.5 && (dx * uy - dy * ux).abs() / len < 0.5
            })
            .collect();
        // start the walk at an edge that is not parallel so runs do not wrap around
        let Some(start) = (0..n).find(|&i| !parallel[i]) else { continue };
        let mut runs: Vec<Vec<(f32, f32)>> = Vec::new();
        let mut cur: Vec<(f32, f32)> = Vec::new();
        for k in 0..n {
            let i = (start + k) % n;
            if parallel[i] {
                if cur.is_empty() {
                    cur.push(ring[i]);
                }
                cur.push(ring[i + 1]);
            } else if !cur.is_empty() {
                runs.push(std::mem::take(&mut cur));
            }
        }
        if !cur.is_empty() {
            runs.push(cur);
        }
        let mut walls = PathBuilder::new();
        let mut shade = PathBuilder::new();
        for run in runs {
            let len: f32 = run.windows(2).map(|w| ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt()).sum();
            if len < 4.0 {
                continue;
            }
            // outward side: away from the deck centre
            let (mx, my) = point_at(&run, len / 2.0);
            let (mut nx, mut ny) = (-uy, ux);
            if (mx - cx) * nx + (my - cy) * ny < 0.0 {
                nx = -nx;
                ny = -ny;
            }
            let first = run[0];
            let last = *run.last().unwrap();
            // the run's own direction decides which end gets which flare
            let (dx, dy) = (last.0 - first.0, last.1 - first.1);
            let dl = (dx * dx + dy * dy).sqrt().max(0.01);
            let (rx, ry) = (dx / dl, dy / dl);
            let mut pts = vec![(first.0 - rx * flare * 0.7 + nx * flare, first.1 - ry * flare * 0.7 + ny * flare)];
            pts.extend(run.iter().copied());
            pts.push((last.0 + rx * flare * 0.7 + nx * flare, last.1 + ry * flare * 0.7 + ny * flare));
            if let Some(p) = pts_path(&wobble_pts(ctx, &pts, 0.3, 5.0, 23), false) {
                walls.push_path(&p);
            }
            // shadow below the south parapet: short vertical strokes hanging from the wall
            if ny > 0.3 {
                for (x, y, _) in along(&run, ctx.m(0.45).max(2.2), 1.0) {
                    let l = shadow * (0.75 + 0.25 * ((x * 0.37).sin()).abs());
                    shade.move_to(x, y + lw * 1.5);
                    shade.line_to(x, y + l);
                }
            }
        }
        if let Some(p) = shade.finish() {
            line(pm, &p, &paint(with_alpha(pen, 0.55)), &stroke(lw * 0.6), None);
        }
        if let Some(p) = walls.finish() {
            line(pm, &p, &paint(pen), &stroke(lw * 2.1), None);
        }
    }
}

// ---------------------------------------------------------------- landmarks

/// Upright landmark icon kinds (besides the church spire).
#[derive(Clone, Copy, PartialEq)]
pub enum Landmark {
    /// school, kindergarten: small roof turret with a bell
    BellTurret,
    /// civic, public, townhall: clock tower with a dome and a flag
    ClockTower,
}

pub fn landmark_of(building: &str) -> Option<Landmark> {
    match building {
        "school" | "kindergarten" | "college" | "university" => Some(Landmark::BellTurret),
        "civic" | "public" | "townhall" | "government" => Some(Landmark::ClockTower),
        _ => None,
    }
}

/// A point well inside a pixel ring: the inside grid point closest to the bbox centre.
pub fn inner_point(ring: &[(f32, f32)], poly: &Polygon<f64>, ctx: &Ctx) -> Option<(f32, f32)> {
    let (x0, y0, x1, y1) = bbox_px(ring);
    let (cx, cy) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
    let mut best: Option<(f32, (f32, f32))> = None;
    for i in 0..=8 {
        for j in 0..=8 {
            let (x, y) = (x0 + (x1 - x0) * (0.1 + 0.8 * i as f32 / 8.0), y0 + (y1 - y0) * (0.1 + 0.8 * j as f32 / 8.0));
            let w = ctx.world(x, y);
            if !point_in_polygon(geo_types::Coord { x: w.0, y: w.1 }, poly) {
                continue;
            }
            let d = (x - cx).powi(2) + (y - cy).powi(2);
            if best.map_or(true, |(bd, _)| d < bd) {
                best = Some((d, (x, y)));
            }
        }
    }
    best.map(|(_, p)| p)
}

fn outline(pm: &mut Pixmap, pb: PathBuilder, lw: f32, pen: Color, paper: Color) {
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(paper), None);
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
}

fn strokes(pm: &mut Pixmap, pb: PathBuilder, lw: f32, pen: Color) {
    if let Some(p) = pb.finish() {
        line(pm, &p, &paint(pen), &stroke(lw), None);
    }
}

/// Draw a landmark icon standing on (cx, base); `s` is the icon scale in px.
pub fn draw_landmark(pm: &mut Pixmap, kind: Landmark, cx: f32, base: f32, s: f32, lw: f32, pen: Color, paper: Color) {
    match kind {
        Landmark::BellTurret => {
            // square turret on the ridge, open belfry with a bell, pyramid roof, finial
            let w = s * 0.55;
            let h = s * 0.75;
            let mut body = PathBuilder::new();
            body.move_to(cx - w / 2.0, base);
            body.line_to(cx - w / 2.0, base - h);
            body.line_to(cx + w / 2.0, base - h);
            body.line_to(cx + w / 2.0, base);
            body.close();
            outline(pm, body, lw * 1.1, pen, paper);
            let mut roof = PathBuilder::new();
            roof.move_to(cx - w * 0.72, base - h);
            roof.line_to(cx, base - h - s * 0.8);
            roof.line_to(cx + w * 0.72, base - h);
            roof.close();
            outline(pm, roof, lw * 1.1, pen, paper);
            let mut d = PathBuilder::new();
            // belfry arch
            let (aw, ab, at) = (w * 0.26, base - h * 0.25, base - h * 0.62);
            d.move_to(cx - aw, ab);
            d.line_to(cx - aw, at);
            d.quad_to(cx, at - aw * 1.6, cx + aw, at);
            d.line_to(cx + aw, ab);
            // roof hatch on the right half
            let mut t = 0.25;
            while t < 0.95 {
                d.move_to(cx + w * 0.72 * (1.0 - t) * 0.15, base - h - s * 0.8 * (1.0 - t));
                d.line_to(cx + w * 0.72 * (1.0 - t), base - h - s * 0.8 * (1.0 - t) + s * 0.02);
                t += 0.18;
            }
            // finial
            d.move_to(cx, base - h - s * 0.8);
            d.line_to(cx, base - h - s * 1.05);
            strokes(pm, d, lw * 0.8, pen);
            // bell
            let mut bell = PathBuilder::new();
            bell.push_circle(cx, base - h * 0.4, aw * 0.45);
            if let Some(p) = bell.finish() {
                fill(pm, &p, &paint(pen), None);
            }
        }
        Landmark::ClockTower => {
            let w = s * 0.6;
            let h = s * 1.25;
            let mut body = PathBuilder::new();
            body.move_to(cx - w / 2.0, base);
            body.line_to(cx - w / 2.0, base - h);
            body.line_to(cx + w / 2.0, base - h);
            body.line_to(cx + w / 2.0, base);
            body.close();
            outline(pm, body, lw * 1.15, pen, paper);
            // dome
            let mut dome = PathBuilder::new();
            dome.move_to(cx - w * 0.58, base - h);
            dome.cubic_to(cx - w * 0.58, base - h - s * 0.62, cx + w * 0.58, base - h - s * 0.62, cx + w * 0.58, base - h);
            dome.close();
            outline(pm, dome, lw * 1.1, pen, paper);
            let mut d = PathBuilder::new();
            // clock face
            let cr = w * 0.28;
            let ccy = base - h * 0.72;
            d.push_circle(cx, ccy, cr);
            d.move_to(cx, ccy);
            d.line_to(cx, ccy - cr * 0.7);
            d.move_to(cx, ccy);
            d.line_to(cx + cr * 0.5, ccy + cr * 0.15);
            // door + shading on the right
            d.move_to(cx - w * 0.14, base);
            d.line_to(cx - w * 0.14, base - h * 0.22);
            d.quad_to(cx, base - h * 0.32, cx + w * 0.14, base - h * 0.22);
            d.line_to(cx + w * 0.14, base);
            let mut t = h * 0.05;
            while t < h * 0.5 {
                d.move_to(cx + w * 0.3, base - t);
                d.line_to(cx + w * 0.5, base - t);
                t += lw * 2.6;
            }
            // flag pole + pennant
            let top = base - h - s * 0.47;
            d.move_to(cx, top);
            d.line_to(cx, top - s * 0.55);
            strokes(pm, d, lw * 0.8, pen);
            let mut flag = PathBuilder::new();
            flag.move_to(cx, top - s * 0.55);
            flag.quad_to(cx + s * 0.2, top - s * 0.6, cx + s * 0.38, top - s * 0.45);
            flag.quad_to(cx + s * 0.2, top - s * 0.42, cx, top - s * 0.34);
            flag.close();
            outline(pm, flag, lw * 0.8, pen, pen);
        }
    }
}

// ---------------------------------------------------------------- street furniture

/// Furniture glyph kinds; the numbers are the `kind` codes in the uprights list of style_ink.
pub const LAMP: u8 = 20;
pub const DRINKING: u8 = 21;
pub const PUMP: u8 = 22;
pub const FOUNTAIN: u8 = 23;
pub const COLUMN: u8 = 24;
pub const MONUMENT: u8 = 25;
pub const CLOCK: u8 = 26;
pub const FLAG: u8 = 27;

/// Upright furniture nodes as (osm_id, kind, point). Water-related ones (`water` accent) are
/// returned from z17, everything else from z19.
pub fn furniture(ctx: &mut Ctx, water_accent: bool) -> Result<Vec<(i64, u8, (f32, f32))>> {
    let z = ctx.z;
    if z < 17 || (z < 19 && !water_accent) {
        return Ok(Vec::new());
    }
    let classes = if z >= 19 {
        "('street_lamp','drinking_water','water_well','fountain','advertising_column','memorial','artwork','clock','flagpole')"
    } else {
        "('drinking_water','water_well','fountain')"
    };
    let rows = ctx.points(
        "osm_id AS id, class, NULL::text AS sub, 0::float8 AS num",
        &format!("feature_node WHERE class IN {classes}"),
        "",
    )?;
    let mut out: Vec<(i64, u8, (f32, f32))> = rows
        .iter()
        .map(|r| {
            let k = match r.class.as_str() {
                "street_lamp" => LAMP,
                "drinking_water" => DRINKING,
                "water_well" => PUMP,
                "fountain" => FOUNTAIN,
                "advertising_column" => COLUMN,
                "clock" => CLOCK,
                "flagpole" => FLAG,
                _ => MONUMENT,
            };
            (r.id, k, ctx.px(r.geom.0))
        })
        .collect();
    // fountains mapped as areas: one glyph on the area
    let polys = ctx.polygons(
        "osm_id AS id, class, NULL::text AS sub, 0::float8 AS num",
        "feature_polygon WHERE class = 'fountain'",
        "",
    )?;
    for f in &polys {
        if let Some(ring) = poly_rings_px(ctx, &f.geom).into_iter().next() {
            if let Some(p) = inner_point(&ring, &f.geom, ctx) {
                out.push((f.id, FOUNTAIN, p));
            }
        }
    }
    Ok(out)
}

pub fn is_water(kind: u8) -> bool {
    matches!(kind, DRINKING | PUMP | FOUNTAIN)
}

fn rect(pb: &mut PathBuilder, x: f32, y: f32, w: f32, h: f32) {
    pb.move_to(x, y);
    pb.line_to(x + w, y);
    pb.line_to(x + w, y + h);
    pb.line_to(x, y + h);
    pb.close();
}

/// Small elevation glyph standing on (x, y). `s` ≈ one metre in px (clamped by the caller).
pub fn draw_furniture(pm: &mut Pixmap, kind: u8, x: f32, y: f32, s: f32, lw: f32, pen: Color, paper: Color) {
    let mut body = PathBuilder::new(); // paper-filled, outlined
    let mut d = PathBuilder::new(); // strokes only
    match kind {
        LAMP => {
            // slim post, lantern with a little cap
            let h = s * 2.6;
            d.move_to(x, y);
            d.line_to(x, y - h);
            d.move_to(x - s * 0.25, y);
            d.line_to(x + s * 0.25, y);
            body.move_to(x - s * 0.22, y - h);
            body.line_to(x - s * 0.32, y - h - s * 0.5);
            body.line_to(x + s * 0.32, y - h - s * 0.5);
            body.line_to(x + s * 0.22, y - h);
            body.close();
            d.move_to(x - s * 0.4, y - h - s * 0.5);
            d.line_to(x, y - h - s * 0.75);
            d.line_to(x + s * 0.4, y - h - s * 0.5);
        }
        DRINKING => {
            // pillar with a spout and a falling drop
            rect(&mut body, x - s * 0.25, y - s * 1.3, s * 0.5, s * 1.3);
            d.move_to(x + s * 0.25, y - s * 1.05);
            d.line_to(x + s * 0.55, y - s * 1.05);
            d.line_to(x + s * 0.55, y - s * 0.9);
            d.push_circle(x + s * 0.55, y - s * 0.55, s * 0.09);
        }
        PUMP => {
            // Berlin street pump: post with a domed top, a spout and a long lever
            let h = s * 1.9;
            body.move_to(x - s * 0.22, y);
            body.line_to(x - s * 0.22, y - h);
            body.quad_to(x, y - h - s * 0.45, x + s * 0.22, y - h);
            body.line_to(x + s * 0.22, y);
            body.close();
            d.move_to(x + s * 0.22, y - h * 0.62);
            d.line_to(x + s * 0.6, y - h * 0.55);
            d.line_to(x + s * 0.6, y - h * 0.45);
            d.move_to(x - s * 0.22, y - h * 0.85);
            d.line_to(x - s * 0.95, y - h * 0.55);
            d.move_to(x - s * 0.4, y);
            d.line_to(x + s * 0.4, y);
        }
        FOUNTAIN => {
            // basin with a jet falling in arcs
            let bw = s * 1.3;
            body.move_to(x - bw, y - s * 0.45);
            body.line_to(x - bw * 0.8, y);
            body.line_to(x + bw * 0.8, y);
            body.line_to(x + bw, y - s * 0.45);
            body.close();
            d.move_to(x, y - s * 0.45);
            d.line_to(x, y - s * 1.9);
            d.move_to(x, y - s * 1.9);
            d.quad_to(x - s * 0.7, y - s * 2.0, x - s * 0.85, y - s * 0.6);
            d.move_to(x, y - s * 1.9);
            d.quad_to(x + s * 0.7, y - s * 2.0, x + s * 0.85, y - s * 0.6);
            d.move_to(x, y - s * 1.5);
            d.quad_to(x - s * 0.35, y - s * 1.55, x - s * 0.45, y - s * 0.7);
            d.move_to(x, y - s * 1.5);
            d.quad_to(x + s * 0.35, y - s * 1.55, x + s * 0.45, y - s * 0.7);
        }
        COLUMN => {
            // advertising column (Litfaßsäule): cylinder, two bands, small dome
            let (w, h) = (s * 0.5, s * 2.2);
            body.move_to(x - w, y);
            body.line_to(x - w, y - h);
            body.quad_to(x, y - h - s * 0.55, x + w, y - h);
            body.line_to(x + w, y);
            body.close();
            for t in [0.2, 0.82] {
                d.move_to(x - w, y - h * t);
                d.quad_to(x, y - h * t + s * 0.18, x + w, y - h * t);
            }
            d.move_to(x + w * 0.45, y - h * 0.24);
            d.line_to(x + w * 0.45, y - h * 0.78);
            d.move_to(x + w * 0.75, y - h * 0.24);
            d.line_to(x + w * 0.75, y - h * 0.78);
        }
        MONUMENT => {
            // plinth with an obelisk
            rect(&mut body, x - s * 0.55, y - s * 0.45, s * 1.1, s * 0.45);
            body.move_to(x - s * 0.25, y - s * 0.45);
            body.line_to(x - s * 0.15, y - s * 2.1);
            body.line_to(x, y - s * 2.4);
            body.line_to(x + s * 0.15, y - s * 2.1);
            body.line_to(x + s * 0.25, y - s * 0.45);
            body.close();
            d.move_to(x + s * 0.08, y - s * 0.6);
            d.line_to(x + s * 0.05, y - s * 2.0);
        }
        CLOCK => {
            d.move_to(x, y);
            d.line_to(x, y - s * 1.8);
            body.push_circle(x, y - s * 2.2, s * 0.42);
            d.move_to(x, y - s * 2.2);
            d.line_to(x, y - s * 2.45);
            d.move_to(x, y - s * 2.2);
            d.line_to(x + s * 0.18, y - s * 2.15);
        }
        FLAG => {
            d.move_to(x, y);
            d.line_to(x, y - s * 3.2);
            body.move_to(x, y - s * 3.2);
            body.quad_to(x + s * 0.5, y - s * 3.3, x + s * 0.9, y - s * 2.95);
            body.quad_to(x + s * 0.5, y - s * 2.85, x, y - s * 2.65);
            body.close();
        }
        _ => {}
    }
    // paper halo, then ink
    let b = body.finish();
    let s_ = d.finish();
    for p in [&b, &s_].into_iter().flatten() {
        line(pm, p, &paint(paper), &stroke(lw * 2.6), None);
    }
    if let Some(p) = &b {
        fill(pm, p, &paint(paper), None);
        line(pm, p, &paint(pen), &stroke(lw * 0.9), None);
    }
    if let Some(p) = &s_ {
        line(pm, p, &paint(pen), &stroke(lw * 0.9), None);
    }
}

// ---------------------------------------------------------------- hatching

/// Like `hatch_path`, but every line is split into segments of a fixed length whose ends sit at
/// world-anchored positions. Lines as long as the render buffer rasterise slightly differently
/// when the buffer grows (metatiles), so only short world-anchored pieces are seam-safe.
pub fn hatch_world(ctx: &Ctx, spacing_px: f32, angle_deg: f32, x0: f32, y0: f32, x1: f32, y1: f32) -> Option<tiny_skia::Path> {
    const SEG: f64 = 128.0;
    let a = f64::from(angle_deg).to_radians();
    let (dx, dy) = (a.cos(), a.sin());
    let (nx, ny) = (-dy, dx);
    let sp = f64::from(spacing_px);
    let mpp = ctx.extent.metres_per_px();
    // world pixel = buffer pixel + origin (f64: world pixels are ~1e8 at z19)
    let (ox, oy) = (ctx.extent.bounds.minx / mpp, -ctx.extent.bounds.maxy / mpp);
    let offset = (-(ox * nx + oy * ny)).rem_euclid(sp);
    let (cx, cy) = (f64::from(x0 + x1) / 2.0, f64::from(y0 + y1) / 2.0);
    let r = f64::from(((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt() / 2.0 + spacing_px);
    let c = cx * nx + cy * ny;
    let k0 = ((c - r - offset) / sp).floor() as i64;
    let k1 = ((c + r - offset) / sp).ceil() as i64;
    let mut pb = PathBuilder::new();
    for k in k0..=k1 {
        let t = offset + k as f64 * sp;
        let (fx, fy) = (cx + nx * (t - c), cy + ny * (t - c));
        // position along the line in world pixels
        let sf = (fx + ox) * dx + (fy + oy) * dy;
        let m0 = ((sf - r) / SEG).floor() as i64;
        let m1 = ((sf + r) / SEG).ceil() as i64;
        for m in m0..m1 {
            let (u0, u1) = (m as f64 * SEG - sf, (m + 1) as f64 * SEG - sf);
            pb.move_to((fx + dx * u0) as f32, (fy + dy * u0) as f32);
            pb.line_to((fx + dx * u1) as f32, (fy + dy * u1) as f32);
        }
    }
    pb.finish()
}
