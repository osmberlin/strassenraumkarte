//! Design research preset `bold`: bold-line print (docs/design-research/03-bold-line-print).
//!
//! A screen print drawn with ruler and compass: black ink on off-white paper, calm category inks
//! for trees, schools and playgrounds, dark blue water. No grey, no opacity, no blur. Pens: W
//! (main) and F = W/2 (detail), square caps, mitre joins. Areas carry textures, not outlines; street
//! fronts are folded onto their buildings (`style_bold_facade`). All randomness is world-anchored.

use anyhow::Result;
use geo_types::Polygon;
use postgres::Client;
use tiny_skia::{Color, LineCap, LineJoin, PathBuilder, Pixmap, Stroke};

use crate::sql_cache::PreparedCache;
use crate::style_bold_facade::Pens;
use crate::style_kit::*;
use crate::style_la::point_in_polygon;
use crate::tile::RenderExtent;

const PAPER: &str = "#F3F0E8";
const INK: &str = "#141414";
/// Category inks: about as dark as each other, none of them a signal colour.
const TREE_GREEN: &str = "#2F8F4E";
const SCHOOL_BORDEAUX: &str = "#7B2D3B";
const PLAY_OCHRE: &str = "#A8741C";
/// Water: dark blue ink (banks, waves).
const WATER_BLUE: &str = "#1F3A6B";

/// Main pen width in px: env `SRK_BOLD_W`, else by zoom.
fn main_pen(z: u32) -> f32 {
    if let Some(w) = std::env::var("SRK_BOLD_W").ok().and_then(|v| v.parse::<f32>().ok()).filter(|w| *w > 0.0) {
        return w;
    }
    match z {
        0..=15 => 1.0,
        16 => 1.25,
        17 => 1.5,
        18 => 2.0,
        19 => 3.0,
        _ => 4.0,
    }
}


// ---------------------------------------------------------------- octilinear experiment
// `SRK_BOLD_OCTI=on`, z <= 17: lines are simplified and snapped to 0/45/90/135 degrees in screen
// space. Vertices come from world geometry, directions are screen-anchored, so tiles stay seamless.

fn octi_on(z: u32) -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    z <= 17 && *V.get_or_init(|| std::env::var("SRK_BOLD_OCTI").map(|v| v == "on").unwrap_or(false))
}

fn dp_simplify(pts: &[(f32, f32)], tol: f32) -> Vec<(f32, f32)> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let (a, b) = (pts[0], pts[pts.len() - 1]);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let (mut imax, mut dmax) = (0, 0.0f32);
    for (i, p) in pts.iter().enumerate().take(pts.len() - 1).skip(1) {
        let d = if l2 < 1e-9 {
            ((p.0 - a.0).powi(2) + (p.1 - a.1).powi(2)).sqrt()
        } else {
            ((p.0 - a.0) * dy - (p.1 - a.1) * dx).abs() / l2.sqrt()
        };
        if d > dmax {
            dmax = d;
            imax = i;
        }
    }
    if dmax <= tol {
        return vec![a, b];
    }
    let mut l = dp_simplify(&pts[..=imax], tol);
    let r = dp_simplify(&pts[imax..], tol);
    l.pop();
    l.extend(r);
    l
}

/// Simplify (Douglas-Peucker, `tol` px), then replace every segment by at most two segments whose
/// directions are multiples of 45 degrees (diagonal part + axis part). Vertices stay fixed.
fn octi(pts: &[(f32, f32)], tol: f32) -> Vec<(f32, f32)> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let closed = pts.first() == pts.last();
    let simp = if closed {
        // split the ring at the vertex farthest from the start, simplify both halves
        let s = pts[0];
        let k = (1..pts.len() - 1)
            .max_by(|&i, &j| {
                let d = |q: (f32, f32)| (q.0 - s.0).powi(2) + (q.1 - s.1).powi(2);
                d(pts[i]).total_cmp(&d(pts[j]))
            })
            .unwrap_or(1);
        let mut a = dp_simplify(&pts[..=k], tol);
        let b = dp_simplify(&pts[k..], tol);
        a.pop();
        a.extend(b);
        if a.len() < 4 {
            return pts.to_vec(); // would collapse to a sliver
        }
        a
    } else {
        dp_simplify(pts, tol)
    };
    let mut out = vec![simp[0]];
    let mut prev_dir: Option<(f32, f32)> = None;
    for w in simp.windows(2) {
        elbow(w[0], w[1], 2.0 * tol, 0, &mut out, &mut prev_dir);
    }
    out
}

/// One octilinear elbow a -> b (diagonal leg + axis leg); a segment whose elbow strays more than
/// `maxdev` px from the straight chord is halved first (midpoint on the chord), so the line
/// becomes a fine staircase instead of one big bulge.
fn elbow(a: (f32, f32), b: (f32, f32), maxdev: f32, depth: u32, out: &mut Vec<(f32, f32)>, prev_dir: &mut Option<(f32, f32)>) {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (adx, ady) = (dx.abs(), dy.abs());
    let (sx, sy) = (dx.signum(), dy.signum());
    let eps = 0.25;
    let sgn = |v: f32| if v.abs() > eps { v.signum() } else { 0.0 };
    if adx < eps || ady < eps || (adx - ady).abs() < eps {
        out.push(b);
        *prev_dir = Some((sgn(dx), sgn(dy)));
        return;
    }
    let diag_len = adx.min(ady);
    let diag = (sx * diag_len, sy * diag_len);
    let axis = (dx - diag.0, dy - diag.1);
    let axis_dir = (sgn(axis.0), sgn(axis.1));
    let axis_first = *prev_dir == Some(axis_dir);
    let mid = if axis_first { (a.0 + axis.0, a.1 + axis.1) } else { (a.0 + diag.0, a.1 + diag.1) };
    let len = (dx * dx + dy * dy).sqrt();
    let dev = ((mid.0 - a.0) * dy - (mid.1 - a.1) * dx).abs() / len;
    if dev > maxdev && depth < 5 && len > 4.0 {
        let m = ((a.0 + b.0) * 0.5, (a.1 + b.1) * 0.5);
        elbow(a, m, maxdev, depth + 1, out, prev_dir);
        elbow(m, b, maxdev, depth + 1, out, prev_dir);
        return;
    }
    out.push(mid);
    out.push(b);
    *prev_dir = Some(if axis_first { (sgn(dx), sgn(dy)) } else { axis_dir });
}

fn octi_pts(ctx: &Ctx, pts: Vec<(f32, f32)>) -> Vec<(f32, f32)> {
    if !octi_on(ctx.z) {
        return pts;
    }
    // optional frame rotation (`SRK_BOLD_OCTI_ROT`, degrees): snap to a grid turned to the street grid
    static ROT: std::sync::OnceLock<f32> = std::sync::OnceLock::new();
    let rot = *ROT.get_or_init(|| std::env::var("SRK_BOLD_OCTI_ROT").ok().and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0));
    if rot == 0.0 {
        return octi(&pts, 1.5 * main_pen(ctx.z));
    }
    let (c, s) = (rot.to_radians().cos(), rot.to_radians().sin());
    let fwd: Vec<(f32, f32)> = pts.iter().map(|&(x, y)| (x * c + y * s, -x * s + y * c)).collect();
    octi(&fwd, 1.5 * main_pen(ctx.z)).into_iter().map(|(x, y)| (x * c - y * s, x * s + y * c)).collect()
}

fn opoly(ctx: &Ctx, poly: &Polygon<f64>) -> Option<tiny_skia::Path> {
    if !octi_on(ctx.z) {
        return poly_path(ctx, poly);
    }
    let mut pb = PathBuilder::new();
    for ring in std::iter::once(poly.exterior()).chain(poly.interiors()) {
        let pts = octi_pts(ctx, ring.coords().map(|c| ctx.px(*c)).collect());
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

fn oline(ctx: &Ctx, l: &geo_types::LineString<f64>) -> Option<tiny_skia::Path> {
    if !octi_on(ctx.z) {
        return line_path(ctx, l);
    }
    pts_path(&octi_pts(ctx, l.coords().map(|c| ctx.px(*c)).collect()), false)
}

fn pen(width: f32) -> Stroke {
    Stroke { width, line_cap: LineCap::Square, line_join: LineJoin::Miter, miter_limit: 4.0, ..Default::default() }
}

/// Which categories are printed in the accent ink (`SRK_BOLD_ACCENT`, comma list or `none`).
struct Accents(Vec<String>);
impl Accents {
    fn from_env() -> Self {
        let v = std::env::var("SRK_BOLD_ACCENT").unwrap_or_else(|_| "tree,school,playground".into());
        if v.trim() == "none" {
            return Self(Vec::new());
        }
        Self(v.split(',').map(|s| s.trim().to_ascii_lowercase()).filter(|s| !s.is_empty()).collect())
    }
    fn col(&self, cat: &str, ink: Color) -> Color {
        if !self.0.iter().any(|c| c == cat) {
            return ink;
        }
        hex(match cat {
            "tree" => TREE_GREEN,
            "school" => SCHOOL_BORDEAUX,
            _ => PLAY_OCHRE,
        })
    }
}

/// Regular grid of points anchored to the world, `step_px` apart, over the extent.
fn grid_points(ctx: &Ctx, step_px: f32) -> Vec<(f32, f32)> {
    let mpp = ctx.extent.metres_per_px();
    let step = f64::from(step_px) * mpp;
    let b = ctx.extent.bounds;
    let (ix0, ix1) = ((b.minx / step).floor() as i64, (b.maxx / step).ceil() as i64);
    let (iy0, iy1) = ((b.miny / step).floor() as i64, (b.maxy / step).ceil() as i64);
    let mut out = Vec::new();
    for ix in ix0..=ix1 {
        for iy in iy0..=iy1 {
            out.push(ctx.extent.map_to_px(ix as f64 * step, iy as f64 * step));
        }
    }
    out
}

fn dots_in(ctx: &Ctx, pm: &mut Pixmap, polys: &[&Polygon<f64>], step_px: f32, r: f32, col: Color) {
    if polys.is_empty() {
        return;
    }
    let Some(mask) = mask_of(ctx, polys) else { return };
    let mut pb = PathBuilder::new();
    for (x, y) in grid_points(ctx, step_px) {
        pb.push_circle(x, y, r);
    }
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(col), Some(&mask));
    }
}

/// Replaces ink by `to` inside `mask`, keeping the ink/paper mix of anti-aliased pixels.
fn reink(pm: &mut Pixmap, mask: &tiny_skia::Mask, ink: Color, paper: Color, to: Color) {
    let lum = |c: Color| 0.3 * c.red() + 0.59 * c.green() + 0.11 * c.blue();
    let (li, lp) = (lum(ink), lum(paper));
    let m = mask.data();
    for (i, px) in pm.pixels_mut().iter_mut().enumerate() {
        if m[i] == 0 {
            continue;
        }
        let c = px.demultiply();
        let (r, g, b) = (c.red() as f32 / 255.0, c.green() as f32 / 255.0, c.blue() as f32 / 255.0);
        // only near-neutral pixels: leave the green trees and ochre play dots alone
        if (r - g).abs() > 0.08 || (g - b).abs() > 0.08 {
            continue;
        }
        let t = ((lp - lum(Color::from_rgba(r, g, b, 1.0).unwrap())) / (lp - li)).clamp(0.0, 1.0);
        if t < 0.05 {
            continue;
        }
        let mixc = |a: f32, b: f32| ((a + (b - a) * t) * 255.0).round() as u8;
        *px = tiny_skia::ColorU8::from_rgba(
            mixc(paper.red(), to.red()),
            mixc(paper.green(), to.green()),
            mixc(paper.blue(), to.blue()),
            255,
        )
        .premultiply();
    }
}

/// Long horizontal rules with a few breaks (the fields of the panorama prints): stroke `width`,
/// row spacing `period`, rows anchored to world metres, breaks from a world-anchored hash.
fn rules(ctx: &Ctx, pm: &mut Pixmap, polys: &[&Polygon<f64>], width: f32, period: f32, col: Color, seed: u64) {
    if polys.is_empty() {
        return;
    }
    let Some(mask) = mask_of(ctx, polys) else { return };
    let mpp = ctx.extent.metres_per_px();
    let b = ctx.extent.bounds;
    let period_m = f64::from(period) * mpp;
    let cell_px = 48.0 * period;
    let cell_m = f64::from(cell_px) * mpp;
    let (k0, k1) = ((b.miny / period_m).ceil() as i64, (b.maxy / period_m).floor() as i64);
    let (c0, c1) = ((b.minx / cell_m).floor() as i64, (b.maxx / cell_m).ceil() as i64);
    const LENS: [f32; 5] = [3.0, 6.0, 10.0, 16.0, 24.0];
    let mut pb = PathBuilder::new();
    for k in k0..=k1 {
        let py = ((b.maxy - k as f64 * period_m) / mpp) as f32;
        for c in c0..=c1 {
            let x0 = ((c as f64 * cell_m - b.minx) / mpp) as f32;
            let mut h = hash_u64((k as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (c as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F) ^ seed);
            let mut pos = 0.0;
            while pos < cell_px {
                h = hash_u64(h.wrapping_add(1));
                let len = (LENS[(h % 5) as usize] * period).min(cell_px - pos);
                pb.move_to(x0 + pos, py);
                pb.line_to(x0 + pos + len, py);
                h = hash_u64(h.wrapping_add(1));
                pos += len + if h % 3 == 0 { 2.5 * period } else { 0.8 * period };
            }
        }
    }
    if let Some(p) = pb.finish() {
        let st = Stroke { width, line_cap: LineCap::Butt, ..Default::default() };
        line(pm, &p, &paint(col), &st, Some(&mask));
    }
}

/// Horizontal broken stripes of width `w`, period 2w, rows anchored to world metres, dashes from
/// a hash of (row, world cell) so neighbouring tiles agree.
fn water_stripes(ctx: &Ctx, pm: &mut Pixmap, polys: &[&Polygon<f64>], w: f32, col: Color) {
    let Some(mask) = mask_of(ctx, polys) else { return };
    let mpp = ctx.extent.metres_per_px();
    let b = ctx.extent.bounds;
    let period_m = 2.0 * f64::from(w) * mpp;
    let cell_px = 96.0 * w;
    let cell_m = f64::from(cell_px) * mpp;
    let (k0, k1) = ((b.miny / period_m).ceil() as i64, (b.maxy / period_m).floor() as i64);
    let (c0, c1) = ((b.minx / cell_m).floor() as i64, (b.maxx / cell_m).ceil() as i64);
    const LENS: [f32; 6] = [4.0, 6.0, 10.0, 16.0, 25.0, 40.0];
    let mut pb = PathBuilder::new();
    for k in k0..=k1 {
        let py = ((b.maxy - k as f64 * period_m) / mpp) as f32;
        for c in c0..=c1 {
            let x0 = ((c as f64 * cell_m - b.minx) / mpp) as f32;
            let mut h = hash_u64((k as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (c as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F) ^ 0xB01D);
            let mut pos = (h >> 20) as f32 % (3.0 * w * 4.0);
            loop {
                h = hash_u64(h.wrapping_add(1));
                let len = LENS[(h % 6) as usize] * w;
                if pos + len > cell_px {
                    break;
                }
                pb.move_to(x0 + pos + 0.5 * w, py);
                pb.line_to(x0 + pos + len - 0.5 * w, py);
                h = hash_u64(h.wrapping_add(1));
                let gap = match h % 10 {
                    0..=4 => 1.0,
                    5..=8 => 2.0,
                    _ => 6.0,
                };
                pos += len + gap * w;
            }
        }
    }
    if let Some(p) = pb.finish() {
        line(pm, &p, &paint(col), &pen(w), Some(&mask));
    }
}

/// Rows of chained small semicircle arcs (waves), broken into runs of 3..12 arcs with gaps.
/// Rows are anchored to world y (period 3 w), arcs to world x (pitch 2 r), runs come from a hash
/// of (row, world cell), so neighbouring tiles agree. Odd rows are shifted by half an arc.
fn water_waves(ctx: &Ctx, pm: &mut Pixmap, polys: &[&Polygon<f64>], w: f32, col: Color) {
    let Some(mask) = mask_of(ctx, polys) else { return };
    let mpp = ctx.extent.metres_per_px();
    let b = ctx.extent.bounds;
    let r = 1.1 * w;
    let pitch = 2.0 * r;
    const CELL_ARCS: f32 = 48.0;
    let cell_px = CELL_ARCS * pitch;
    let cell_m = f64::from(cell_px) * mpp;
    let period_m = 3.0 * f64::from(w) * mpp;
    let (k0, k1) = ((b.miny / period_m).floor() as i64 - 2, (b.maxy / period_m).ceil() as i64 + 2);
    let (c0, c1) = ((b.minx / cell_m).floor() as i64, (b.maxx / cell_m).ceil() as i64);
    let mut pb = PathBuilder::new();
    for k in k0..=k1 {
        let py = ((b.maxy - k as f64 * period_m) / mpp) as f32;
        let shift = if k.rem_euclid(2) == 1 { 0.5 } else { 0.0 };
        for c in c0..=c1 {
            let x0 = ((c as f64 * cell_m - b.minx) / mpp) as f32;
            let mut h = hash_u64((k as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (c as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F) ^ 0xAA7E);
            let mut pos = (h % 7) as f32 + shift;
            loop {
                h = hash_u64(h.wrapping_add(1));
                let len = 3.0 + (h % 10) as f32;
                if pos + len > CELL_ARCS {
                    break;
                }
                for i in 0..len as u32 {
                    let cx = x0 + (pos + i as f32) * pitch + r;
                    for (j, (ax, ay)) in arc_pts(cx, py, r, 180.0, 360.0, 10).into_iter().enumerate() {
                        if i == 0 && j == 0 {
                            pb.move_to(ax, ay);
                        } else {
                            pb.line_to(ax, ay);
                        }
                    }
                }
                h = hash_u64(h.wrapping_add(1));
                let gap = match h % 10 {
                    0..=4 => 1.0,
                    5..=7 => 2.0,
                    8 => 3.0,
                    _ => 6.0,
                };
                pos += len + gap;
            }
        }
    }
    if let Some(p) = pb.finish() {
        let st = Stroke { width: 0.8 * w, line_cap: LineCap::Butt, line_join: LineJoin::Round, ..Default::default() };
        line(pm, &p, &paint(col), &st, Some(&mask));
    }
}

/// Points on a circle arc, screen angles in degrees (y down: 270 = up), `n` segments.
fn arc_pts(cx: f32, cy: f32, r: f32, a0: f32, a1: f32, n: u32) -> Vec<(f32, f32)> {
    (0..=n)
        .map(|i| {
            let a = (a0 + (a1 - a0) * i as f32 / n as f32).to_radians();
            (cx + r * a.cos(), cy + r * a.sin())
        })
        .collect()
}

/// Hedge: a row of semicircular bumps (radius 1.2 w) along the line, bulging to the north side
/// (or east on vertical runs), no baseline.
fn hedge(pm: &mut Pixmap, pts: &[(f32, f32)], w: f32, col: Color) {
    let r = 1.2 * w;
    let mut pb = PathBuilder::new();
    for (x, y, a) in along(pts, 2.0 * r, r) {
        let (mut nx, mut ny) = (-a.sin(), a.cos());
        if ny > 1e-3 || (ny.abs() <= 1e-3 && nx < 0.0) {
            nx = -nx;
            ny = -ny;
        }
        let (tx, ty) = (a.cos(), a.sin());
        for (j, i) in (0..=8).enumerate() {
            let phi = std::f32::consts::PI * i as f32 / 8.0;
            let (u, v) = (-phi.cos() * r, phi.sin() * r);
            let (px, py) = (x + tx * u + nx * v, y + ty * u + ny * v);
            if j == 0 {
                pb.move_to(px, py);
            } else {
                pb.line_to(px, py);
            }
        }
    }
    if let Some(p) = pb.finish() {
        let st = Stroke { width: 0.8 * w, line_cap: LineCap::Butt, line_join: LineJoin::Round, ..Default::default() };
        line(pm, &p, &paint(col), &st, None);
    }
}

pub fn render(client: &mut Client, prep: &mut PreparedCache, extent: RenderExtent, z: u32) -> Result<Pixmap> {
    let mut pm = Pixmap::new(extent.width_px, extent.height_px).expect("pixmap");
    let paper = hex(PAPER);
    let ink = hex(INK);
    let acc = Accents::from_env();
    let accent_c = acc.col("school", hex(INK));
    pm.fill(paper);
    let mut ctx = Ctx { client, prep, extent, z, margin_m: 40.0 };

    let w = main_pen(z);
    let f = w * 0.5;
    let pens = Pens { w, ink, accent: accent_c, paper };

    // ---- landuse
    let landuse = ctx.polygons(
        "osm_id AS id, class, NULL::text AS sub, ST_Area(geom)::float8 AS num",
        "landuse",
        "ORDER BY ST_Area(geom) DESC",
    )?;
    let mut lawns = Vec::new();
    let mut sands = Vec::new();
    let mut playgrounds = Vec::new();
    let mut woods = Vec::new();
    let mut pools = Vec::new();
    let mut cemeteries = Vec::new();
    let mut schools = Vec::new();
    for l in &landuse {
        match l.class.as_str() {
            "cemetery" => cemeteries.push(&l.geom),
            "grass" | "park" | "greenery" | "garden" | "recreation_ground" | "village_green" | "dog_park" | "allotments"
            | "meadow" => lawns.push(&l.geom),
            "sand" | "bare_ground" | "ground" | "woodchips" | "gravel" => sands.push(&l.geom),
            "playground" => playgrounds.push(&l.geom),
            "forest" | "wood" => woods.push(&l.geom),
            "swimming_pool" => pools.push(&l.geom),
            "school" | "kindergarten" => schools.push(&l.geom),
            _ => {}
        }
    }
    // areas carry a texture, not an outline: lines are kept for the content
    let green = acc.col("tree", ink);
    rules(&ctx, &mut pm, &lawns, f, 4.0 * w, green, 0x6EA5);
    // cemetery crosses on a grid
    if !cemeteries.is_empty() {
        if let Some(mask) = mask_of(&ctx, &cemeteries) {
            let s = 1.6 * w;
            let mut pb = PathBuilder::new();
            for (x, y) in grid_points(&ctx, 9.0 * w) {
                pb.move_to(x, y - s);
                pb.line_to(x, y + s * 1.2);
                pb.move_to(x - s * 0.7, y - s * 0.3);
                pb.line_to(x + s * 0.7, y - s * 0.3);
            }
            if let Some(p) = pb.finish() {
                line(&mut pm, &p, &paint(ink), &pen(f), Some(&mask));
            }
        }
    }
    dots_in(&ctx, &mut pm, &sands, 4.0 * w, 0.5 * w, ink);

    // ---- water: dark blue; bank in W, waves (chained arcs) inside, straight stripes when tiny
    let blue = hex(WATER_BLUE);
    let water = ctx.polygons("0::bigint AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "water_body_dissolved", "")?;
    let ws: Vec<&Polygon<f64>> = water.iter().map(|f| &f.geom).chain(pools.iter().copied()).collect();
    if !ws.is_empty() {
        for g in &ws {
            if let Some(p) = opoly(&ctx, g) {
                fill(&mut pm, &p, &paint(paper), None);
            }
        }
        if w >= 1.75 {
            water_waves(&ctx, &mut pm, &ws, w, blue);
        } else {
            water_stripes(&ctx, &mut pm, &ws, w, blue);
        }
        for g in &ws {
            if let Some(p) = opoly(&ctx, g) {
                line(&mut pm, &p, &paint(blue), &pen(w), None);
            }
        }
    }

    // ---- pitches
    let pitches = ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "pitch", "")?;
    for p in &pitches {
        if let Some(path) = opoly(&ctx, &p.geom) {
            line(&mut pm, &path, &paint(ink), &pen(f), None);
        }
    }
    if let Some(p) = pitch_marking_path(&mut ctx)? {
        line(&mut pm, &p, &paint(ink), &pen(f), None);
    }

    // ---- railways: two rails W, ties F (comb)
    for (pts, main) in railway_lines(&mut ctx)? {
        let gauge = if main { (3.0 * w).max(ctx.m(1.4)) } else { (2.2 * w).max(ctx.m(1.0)) };
        if let Some(p) = pts_path(&pts, false) {
            line(&mut pm, &p, &paint(ink), &pen(gauge + 2.0 * w), None);
            line(&mut pm, &p, &paint(paper), &pen(gauge), None);
        }
        let mut ties = PathBuilder::new();
        for (x, y, a) in along(&pts, (3.5 * w).max(ctx.m(if main { 1.6 } else { 2.4 })), 1.0) {
            let (nx, ny) = (-a.sin(), a.cos());
            let hh = gauge * 0.5 + w * 1.5;
            ties.move_to(x - nx * hh, y - ny * hh);
            ties.line_to(x + nx * hh, y + ny * hh);
        }
        if let Some(p) = ties.finish() {
            line(&mut pm, &p, &paint(ink), &pen(f), None);
        }
    }

    // ---- streets
    let areas = ctx.polygons(
        r#"osm_id AS id, "area:highway" AS class, class AS sub, 0::float8 AS num"#,
        "highway_area",
        "ORDER BY COALESCE(layer,0)",
    )?;
    let is_road = |c: &str| {
        matches!(
            c,
            "residential" | "secondary" | "tertiary" | "tertiary_link" | "primary" | "service" | "living_street" | "turning_circle"
                | "unclassified" | "cycleway"
        )
    };
    // Touching areas of one group read as one surface: stroke every outline at twice the pen,
    // then fill all areas with paper on top, so only the outer half survives and shared edges
    // vanish. Footways first; the carriageway group then keeps its kerb on top of them.
    let groups: [(Box<dyn Fn(&str) -> bool>, f32); 2] = [
        (Box::new(|c: &str| matches!(c, "pedestrian" | "footway" | "steps")), f),
        (Box::new(move |c: &str| is_road(c)), w),
    ];
    for (member, wd) in &groups {
        let mut pb = PathBuilder::new();
        for a in areas.iter().filter(|a| member(&a.class)) {
            if let Some(p) = opoly(&ctx, &a.geom) {
                pb.push_path(&p);
            }
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink), &pen(2.0 * wd), None);
            pm.fill_path(&p, &paint(paper), tiny_skia::FillRule::Winding, tiny_skia::Transform::identity(), None);
        }
    }
    if z >= 17 {
        let paths = ctx.lines(
            "osm_id AS id, highway AS class, class AS sub, 0::float8 AS num",
            "highway WHERE type = 'path'",
            "ORDER BY osm_id",
        )?;
        let mut pb = PathBuilder::new();
        for p in paths.iter().filter(|p| p.sub != "sidewalk" && p.sub != "crossing") {
            if let Some(path) = oline(&ctx, &p.geom) {
                pb.push_path(&path);
            }
        }
        // no path lines on pedestrian squares, runways and other highway areas
        let mut amask = mask_of(&ctx, &areas.iter().map(|a| &a.geom).collect::<Vec<_>>());
        if let Some(m) = amask.as_mut() {
            m.invert();
        }
        if let Some(p) = pb.finish() {
            line(&mut pm, &p, &paint(ink), &pen(f), amask.as_ref());
        }
    }

    // ---- playgrounds: dot grid (accent), no outline
    let pg_col = acc.col("playground", ink);
    let pg_poly = ctx.polygons("osm_id AS id, playground AS class, NULL::text AS sub, 0::float8 AS num", "playground_polygon", "")?;
    let mut pg_all: Vec<&Polygon<f64>> = playgrounds.clone();
    pg_all.extend(pg_poly.iter().map(|f| &f.geom));
    // paper first, so the lawn rules underneath do not mix with the play dots
    for g in &pg_all {
        if let Some(p) = opoly(&ctx, g) {
            fill(&mut pm, &p, &paint(paper), None);
        }
    }
    dots_in(&ctx, &mut pm, &pg_all, 4.0 * w, 0.6 * w, pg_col);

    // ---- school and kindergarten grounds: whole area in the school ink (dot field, no outline)
    let sc_col = acc.col("school", ink);
    for g in &schools {
        if let Some(p) = opoly(&ctx, g) {
            fill(&mut pm, &p, &paint(paper), None);
        }
    }
    dots_in(&ctx, &mut pm, &schools, 3.0 * w, 0.55 * w, sc_col);

    // ---- barriers: walls heavy, fences F
    let barriers = ctx.lines_full("osm_id AS id, barrier AS class, NULL::text AS sub, 0::float8 AS num", "barrier_way", "")?;
    if z >= 18 {
        for b in &barriers {
            let pts = line_pts(&ctx, &b.geom);
            let Some(p) = pts_path(&pts, false) else { continue };
            match b.class.as_str() {
                "wall" | "retaining_wall" => line(&mut pm, &p, &paint(ink), &pen(w), None),
                "fence" | "handrail" => line(&mut pm, &p, &paint(ink), &pen(f), None),
                "hedge" => hedge(&mut pm, &pts, w, acc.col("tree", ink)),
                _ => {}
            }
        }
    }

    // ---- buildings
    draw_buildings(&mut ctx, &mut pm, &pens)?;

    // ---- schools and kindergartens are printed whole in the school ink: every ink pixel inside
    // the grounds (buildings, roofs, facades) is re-inked, anti-aliased edges keep their weight
    if sc_col != ink {
        if let Some(mask) = mask_of(&ctx, &schools) {
            reink(&mut pm, &mask, ink, paper, sc_col);
        }
    }

    // ---- landmarks: upright church / town hall elevations, painted north -> south
    if z >= 18 {
        draw_landmarks(&mut ctx, &mut pm, &pens)?;
    }

    // ---- trees: upright lollipops where the crown has room, plan circles where it would hit a
    // building; painted north -> south so front crowns cut the ones behind (as in the panoramas)
    let tree_col = acc.col("tree", ink);
    let blds = ctx.polygons("osm_id AS id, NULL::text AS class, NULL::text AS sub, 0::float8 AS num", "building WHERE building IS NOT NULL", "")?;
    let bmask = mask_of(&ctx, &blds.iter().map(|b| &b.geom).collect::<Vec<_>>());
    let in_building = |x: f32, y: f32| -> bool {
        let Some(m) = &bmask else { return false };
        if x < 0.0 || y < 0.0 || x >= m.width() as f32 || y >= m.height() as f32 {
            return false;
        }
        m.data()[y as usize * m.width() as usize + x as usize] > 0
    };
    let trees = ctx.points(
        "osm_id AS id, COALESCE(leaf_type,'') AS class, NULL::text AS sub, COALESCE(diameter_crown, CASE WHEN leaf_type = 'needleleaved' THEN 11 ELSE 8 END)::float8 AS num",
        "tree",
        "",
    )?;
    let mut bases: Vec<TreeBase> = Vec::new();
    for t in &trees {
        if woods.iter().any(|p| point_in_polygon(t.geom.0, p)) {
            continue;
        }
        let (x, y) = ctx.px(t.geom.0);
        let h = hash_u64(t.id as u64 ^ 0x7EE5_0001);
        let r = (ctx.m(t.num.clamp(1.0, 30.0) / 2.0) * 0.8 * jitter(h)).max(1.5 * w);
        let crown = if t.class == "needleleaved" { Crown::Conifer } else { crown_of(h) };
        bases.push(TreeBase { x, y, r, crown });
    }
    let fk = 2f64.powf((19.0 - f64::from(z)).max(0.0) / 2.0);
    for (wx, wy, rr) in world_scatter(&ctx, 6.0 * fk, 0.8, 51) {
        let pt = geo_types::Coord { x: wx, y: wy };
        if woods.iter().any(|p| point_in_polygon(pt, p)) {
            let (x, y) = ctx.extent.map_to_px(wx, wy);
            let h = hash_u64(wx.to_bits() ^ wy.to_bits().rotate_left(21) ^ 0x7EE5_0002);
            let r = (if rr < 0.5 { 2.0 * w } else { 3.0 * w }) * jitter(h);
            bases.push(TreeBase { x, y, r, crown: crown_of(h) });
        }
    }
    bases.sort_by(|a, b| a.y.total_cmp(&b.y));
    for t in bases {
        let g = tree_glyph(&t, w);
        let (cx, cy) = (t.x, g.cy);
        let upright = z >= 18
            && ![(cx, cy), (cx - g.hw, cy), (cx + g.hw, cy), (cx, g.top), (cx - 0.7 * g.hw, g.top + 0.3 * (cy - g.top)), (cx + 0.7 * g.hw, g.top + 0.3 * (cy - g.top))]
                .iter()
                .any(|&(px, py)| in_building(px, py));
        draw_tree(&mut pm, &t, &g, upright, w, tree_col, paper);
    }

    // ---- street names: small caps
    if z >= 17 {
        draw_street_labels(
            &mut ctx,
            &mut pm,
            &LabelStyle {
                family: "Helvetica Neue",
                italic: false,
                weight: 700,
                size_px: match z { 20.. => 17.0, 19 => 14.0, 18 => 12.0, _ => 10.0 },
                letter_spacing_em: 0.18,
                uppercase: true,
                fill: INK,
                halo: PAPER,
                halo_px: 3.0,
                repeat_px: 600.0,
            },
        )?;
    }
    Ok(pm)
}

// ---------------------------------------------------------------- trees

#[derive(Clone, Copy, PartialEq)]
enum Crown {
    /// circle on a stem
    Lollipop,
    /// semicircle with a flat base on a T-stem
    Dome,
    /// two overlapping circles side by side
    Double,
    /// pointed teardrop on a short stem
    Conifer,
}

struct TreeBase {
    x: f32,
    y: f32,
    r: f32,
    crown: Crown,
}

/// Where the upright glyph sits: crown centre height, half width, top.
struct Glyph {
    cy: f32,
    hw: f32,
    top: f32,
}

/// Size jitter +-12 % from the hash.
fn jitter(h: u64) -> f32 {
    1.0 + 0.12 * (2.0 * ((h >> 24) & 0xFFFF) as f32 / 65535.0 - 1.0)
}

/// ~60 % lollipop, ~25 % dome, ~15 % double crown.
fn crown_of(h: u64) -> Crown {
    match h % 100 {
        0..=59 => Crown::Lollipop,
        60..=84 => Crown::Dome,
        _ => Crown::Double,
    }
}

fn tree_glyph(t: &TreeBase, w: f32) -> Glyph {
    let r = t.r;
    match t.crown {
        Crown::Lollipop => {
            let stem = (0.9 * r).max(1.5 * w);
            let cy = t.y - stem - r;
            Glyph { cy, hw: r, top: cy - r }
        }
        Crown::Dome => {
            let rr = 1.1 * r;
            let stem = (0.7 * rr).max(1.5 * w);
            let cy = t.y - stem; // flat base
            Glyph { cy, hw: rr, top: cy - rr }
        }
        Crown::Double => {
            let r2 = 0.75 * r;
            let stem = (0.9 * r).max(1.5 * w);
            let cy = t.y - stem - r2;
            Glyph { cy, hw: 0.55 * r + r2, top: cy - r2 }
        }
        Crown::Conifer => {
            let rc = 0.85 * r;
            let stem = (0.5 * rc).max(1.5 * w);
            let cy = t.y - stem - rc;
            Glyph { cy, hw: rc, top: cy - 2.0 * rc }
        }
    }
}

fn draw_tree(pm: &mut Pixmap, t: &TreeBase, g: &Glyph, upright: bool, w: f32, col: Color, paper: Color) {
    let (x, y, r) = (t.x, t.y, t.r);
    if !upright {
        // plan: circle; conifers carry a small triangle, the others a centre dot
        let rp = if t.crown == Crown::Conifer { 0.85 * r } else { r };
        let mut c = PathBuilder::new();
        c.push_circle(x, y, rp);
        if let Some(p) = c.finish() {
            fill(pm, &p, &paint(paper), None);
            line(pm, &p, &paint(col), &pen(w), None);
        }
        if t.crown == Crown::Conifer {
            let mut tri = PathBuilder::new();
            tri.move_to(x, y - 0.55 * rp);
            tri.line_to(x + 0.5 * rp, y + 0.35 * rp);
            tri.line_to(x - 0.5 * rp, y + 0.35 * rp);
            tri.close();
            if let Some(p) = tri.finish() {
                fill(pm, &p, &paint(col), None);
            }
        } else {
            let mut dot = PathBuilder::new();
            dot.push_circle(x, y, (0.5 * w).max(0.8));
            if let Some(p) = dot.finish() {
                fill(pm, &p, &paint(col), None);
            }
        }
        return;
    }
    // stem first (the crown paper hides its top end)
    let mut st = PathBuilder::new();
    st.move_to(x, y);
    st.line_to(x, g.cy);
    if let Some(p) = st.finish() {
        line(pm, &p, &paint(col), &pen(w), None);
    }
    let mut shapes: Vec<PathBuilder> = Vec::new();
    match t.crown {
        Crown::Lollipop => {
            let mut c = PathBuilder::new();
            c.push_circle(x, g.cy, r.min(g.hw));
            shapes.push(c);
        }
        Crown::Dome => {
            let mut d = PathBuilder::new();
            for (i, (px, py)) in arc_pts(x, g.cy, g.hw, 180.0, 360.0, 20).into_iter().enumerate() {
                if i == 0 {
                    d.move_to(px, py);
                } else {
                    d.line_to(px, py);
                }
            }
            d.close();
            shapes.push(d);
        }
        Crown::Double => {
            let r2 = 0.75 * r;
            for dx in [-0.55 * r, 0.55 * r] {
                let mut c = PathBuilder::new();
                c.push_circle(x + dx, g.cy, r2);
                shapes.push(c);
            }
        }
        Crown::Conifer => {
            // semicircle-ish bottom, flanks tangent to the circle meeting in a point 2 rc above the centre
            let rc = g.hw;
            let mut d = PathBuilder::new();
            d.move_to(x, g.top);
            let arc = arc_pts(x, g.cy, rc, 210.0, -30.0, 24);
            for (px, py) in arc {
                d.line_to(px, py);
            }
            d.close();
            shapes.push(d);
        }
    }
    for pb in shapes {
        if let Some(p) = pb.finish() {
            fill(pm, &p, &paint(paper), None);
            line(pm, &p, &paint(col), &pen(w), None);
        }
    }
}

fn draw_buildings(ctx: &mut Ctx, pm: &mut Pixmap, pens: &Pens) -> Result<()> {
    let (w, ink, paper) = (pens.w, pens.ink, pens.paper);
    let f = w * 0.5;
    let blds = ctx.polygons(
        r#"osm_id AS id, COALESCE(building, 'yes') AS class, COALESCE("building:part", '') AS sub, 0::float8 AS num"#,
        "building",
        "ORDER BY osm_id",
    )?;
    // paper under every mass: hides what lies below (landuse lines, road edges)
    for b in blds.iter().filter(|b| b.sub.is_empty()) {
        if let Some(p) = opoly(ctx, &b.geom) {
            fill(pm, &p, &paint(paper), None);
        }
    }
    // roofs: stripes by aspect
    if ctx.z >= 17 && !crate::roof_shapes::switched_off() {
        let roofs = load_roofs(ctx)?;
        let mut north = PathBuilder::new();
        let mut side = PathBuilder::new();
        for (rings, aspect, _ids) in &roofs.facets {
            let d = (aspect + 180.0).rem_euclid(360.0) - 180.0;
            let ridge = bearing_to_screen_deg(*aspect) + 90.0;
            let (period, target) = if d.abs() <= 45.0 {
                (2.0 * w, &mut north)
            } else if d.abs() >= 135.0 {
                continue; // south-facing: empty paper
            } else {
                (3.0 * w, &mut side)
            };
            if period < 3.0 {
                continue;
            }
            if let Some(p) = hatch_in_polygon(ctx, rings, period, ridge) {
                target.push_path(&p);
            }
        }
        for pb in [north, side] {
            if let Some(p) = pb.finish() {
                line(pm, &p, &paint(ink), &pen(w), None);
            }
        }
        let mut lines = PathBuilder::new();
        for (pts, class) in &roofs.lines {
            if matches!(class.as_str(), "ridge" | "hip") {
                if let Some(p) = pts_path(pts, false) {
                    lines.push_path(&p);
                }
            }
        }
        if let Some(p) = lines.finish() {
            line(pm, &p, &paint(ink), &pen(w), None);
        }
    }
    // outlines: masses H, parts F; school buildings in the school ink
    let sc_col = pens.accent;
    let mut heavy = PathBuilder::new();
    let mut school = PathBuilder::new();
    let mut parts = PathBuilder::new();
    for b in &blds {
        let Some(p) = opoly(ctx, &b.geom) else { continue };
        if !b.sub.is_empty() {
            parts.push_path(&p);
        } else if matches!(b.class.as_str(), "school" | "kindergarten") {
            school.push_path(&p);
        } else {
            heavy.push_path(&p);
        }
    }
    if let Some(p) = parts.finish() {
        line(pm, &p, &paint(ink), &pen(f), None);
    }
    // folded facades: their paper wipes the roof hatch, ridges and parts underneath
    crate::style_bold_facade::draw(ctx, pm, pens)?;
    if let Some(p) = heavy.finish() {
        line(pm, &p, &paint(ink), &pen(w), None);
    }
    if let Some(p) = school.finish() {
        line(pm, &p, &paint(sc_col), &pen(w), None);
    }
    Ok(())
}

// ---------------------------------------------------------------- upright landmark icons

#[derive(Clone, Copy, PartialEq)]
enum Mark {
    Church,
    Hall,
}


/// The real church tower: width and height in px, spire for pyramidal / cone / onion roofs.
#[derive(Clone, Copy)]
struct Tower {
    width: f32,
    height: f32,
    spire: bool,
}

/// One elevation icon per landmark building, standing on the footprint centre (base = centre,
/// rising up on screen), paper-filled so it hides what lies behind. Churches with a tall building
/// part (the tower) stand on the part's centroid and take its size and roof shape.
fn draw_landmarks(ctx: &mut Ctx, pm: &mut Pixmap, pens: &Pens) -> Result<()> {
    let blds = ctx.polygons(
        r#"osm_id AS id, building AS class, COALESCE("building:part", '') AS sub, ST_Area(geom)::float8 AS num,
           ST_AsBinary(ST_Centroid(geom)) AS wkb2"#,
        "building WHERE building IN ('church','chapel','cathedral','civic','public','townhall','government')",
        "ORDER BY osm_id",
    )?;
    // tallest small building part (< 400 m2 true area, >= 15 m) inside each church; centroid and
    // area are taken from the whole (unclipped) part, so every tile draws the same tower. The
    // church footprint is the row geometry, so a tile sees the tower exactly when it sees the church.
    let towers = ctx.polygons(
        r#"id, class, sub, num, wkb2"#,
        r#"(SELECT c.osm_id AS id, COALESCE(t."roof:shape", '') AS class, t.height::text AS sub, t.a AS num,
                   ST_AsBinary(ST_Centroid(t.geom)) AS wkb2, c.geom
            FROM building c
            JOIN LATERAL (
              SELECT p.height, p."roof:shape", p.geom, ST_Area(p.geom) AS a
              FROM building p
              WHERE p."building:part" IS NOT NULL AND p.height >= 15 AND ST_Intersects(p.geom, c.geom)
                AND ST_Area(p.geom) * power(cos(radians(ST_Y(ST_Transform(ST_Centroid(p.geom), 4326)))), 2) < 400
              ORDER BY p.height DESC, ST_Area(p.geom) DESC LIMIT 1
            ) t ON true
            WHERE c.building IN ('church','chapel','cathedral')) tw"#,
        "",
    )?;
    let k = ctx.ref_scale();
    let mut tower_of: std::collections::HashMap<i64, (f32, f32, Tower)> = std::collections::HashMap::new();
    for t in &towers {
        let Some(geo_types::Geometry::Point(c)) = &t.aux else { continue };
        let Ok(height_m) = t.sub.parse::<f64>() else { continue };
        let area_m2 = (t.num / (k * k)).max(1.0);
        let (x, y) = ctx.px(c.0);
        let tw = Tower {
            width: ctx.m(area_m2.sqrt()).max(ctx.m(5.0)),
            height: ctx.m(height_m) * 0.6,
            spire: matches!(t.class.as_str(), "pyramidal" | "cone" | "onion"),
        };
        tower_of.entry(t.id).or_insert((x, y, tw));
    }
    // largest polygon per id: (area, x, y, kind, tower)
    let mut best: std::collections::HashMap<i64, (f32, f32, f32, Mark, Option<Tower>)> = std::collections::HashMap::new();
    for b in blds.iter().filter(|b| b.sub.is_empty()) {
        let kind = match b.class.as_str() {
            "church" | "chapel" | "cathedral" => Mark::Church,
            _ => Mark::Hall,
        };
        // area and centre of the whole (unclipped) footprint, so every tile places the icon alike
        let a = (b.num / (k * k)) as f32;
        let Some(geo_types::Geometry::Point(c)) = &b.aux else { continue };
        if a < 25.0 {
            continue;
        }
        let (mut x, mut y) = ctx.px(c.0);
        let mut tw = None;
        if kind == Mark::Church {
            if let Some(&(tx, ty, t)) = tower_of.get(&b.id) {
                (x, y, tw) = (tx, ty, Some(t));
            }
        }
        let e = best.entry(b.id).or_insert((0.0, 0.0, 0.0, kind, None));
        if a > e.0 {
            *e = (a, x, y, kind, tw);
        }
    }
    // largest first; drop icons that would sit on top of a bigger one of the same complex
    let mut all: Vec<(f32, f32, f32, Mark, Option<Tower>)> = best.into_values().collect();
    all.sort_by(|a, b| b.0.total_cmp(&a.0));
    let near = ctx.m(14.0);
    let mut icons: Vec<(f32, f32, Mark, Option<Tower>)> = Vec::new();
    for (_, x, y, k, tw) in all {
        if icons.iter().any(|(ix, iy, ik, _)| *ik == k && (ix - x).hypot(iy - y) < near) {
            continue;
        }
        icons.push((x, y, k, tw));
    }
    icons.sort_by(|a, b| a.1.total_cmp(&b.1));
    for (x, y, k, tw) in icons {
        match (k, tw) {
            (Mark::Church, Some(t)) => draw_tower(pm, pens, x, y, &t),
            (Mark::Church, None) => draw_church(pm, pens, x, y, ctx.m(22.0).max(28.0)),
            (Mark::Hall, _) => draw_hall(pm, pens, x, y, ctx.m(17.0).max(24.0)),
        }
    }
    Ok(())
}

/// Church tower from the real building part: box with belfry windows and door, a spire with a
/// cross (pyramidal, cone, onion) or a flat top with a parapet.
fn draw_tower(pm: &mut Pixmap, pens: &Pens, cx: f32, by: f32, t: &Tower) {
    let (w, f) = (pens.w, pens.w * 0.5);
    let hw = 0.5 * t.width;
    let total = t.height.max(2.0 * t.width * 0.8);
    let spire_h = if t.spire { 0.42 * total } else { 0.0 };
    let body_h = total - spire_h;
    let top = by - body_h;
    if t.spire {
        let eave = 0.08 * hw;
        let mut sp = PathBuilder::new();
        sp.move_to(cx - hw - eave, top);
        sp.line_to(cx, top - spire_h);
        sp.line_to(cx + hw + eave, top);
        sp.close();
        sheet(pm, sp, pens, w);
        let apex = top - spire_h;
        let cl = (0.12 * total).max(4.0 * w);
        let mut cr = PathBuilder::new();
        cr.move_to(cx, apex);
        cr.line_to(cx, apex - cl);
        cr.move_to(cx - 0.4 * cl, apex - 0.62 * cl);
        cr.line_to(cx + 0.4 * cl, apex - 0.62 * cl);
        if let Some(p) = cr.finish() {
            line(pm, &p, &paint(pens.ink), &pen(w), None);
        }
    }
    sheet(pm, rect_pb(cx - hw, top, cx + hw, by), pens, w);
    if !t.spire {
        // parapet: a slightly wider band under the top edge
        let e = 0.07 * hw;
        let band = (0.09 * total).max(2.0 * w);
        sheet(pm, rect_pb(cx - hw - e, top, cx + hw + e, top + band), pens, w);
    }
    // belfry windows: arched, two when there is room
    let ww = (0.15 * hw).max(1.2 * w);
    let spring = top + 0.40 * body_h;
    let wbase = top + 0.62 * body_h;
    if hw >= 6.0 * w {
        for dx in [-0.45 * hw, 0.45 * hw] {
            sheet(pm, arch_pb(cx + dx, wbase, ww, spring), pens, f);
        }
    } else {
        sheet(pm, arch_pb(cx, wbase, ww, spring), pens, f);
    }
    // door
    let dw = (0.26 * hw).max(1.5 * w);
    sheet(pm, arch_pb(cx, by, dw, by - 0.14 * body_h), pens, f);
}

/// Closed outline, paper fill under an ink stroke.
fn sheet(pm: &mut Pixmap, pb: PathBuilder, pens: &Pens, width: f32) {
    if let Some(p) = pb.finish() {
        fill(pm, &p, &paint(pens.paper), None);
        line(pm, &p, &paint(pens.ink), &pen(width), None);
    }
}

fn rect_pb(x0: f32, y0: f32, x1: f32, y1: f32) -> PathBuilder {
    let mut pb = PathBuilder::new();
    pb.move_to(x0, y0);
    pb.line_to(x1, y0);
    pb.line_to(x1, y1);
    pb.line_to(x0, y1);
    pb.close();
    pb
}

/// Arched opening: sides from y_base up to the spring line, semicircle on top.
fn arch_pb(cx: f32, y_base: f32, half_w: f32, spring_y: f32) -> PathBuilder {
    const K: f32 = 0.552_284_75;
    let r = half_w;
    let mut pb = PathBuilder::new();
    pb.move_to(cx - r, y_base);
    pb.line_to(cx - r, spring_y);
    pb.cubic_to(cx - r, spring_y - K * r, cx - K * r, spring_y - r, cx, spring_y - r);
    pb.cubic_to(cx + K * r, spring_y - r, cx + r, spring_y - K * r, cx + r, spring_y);
    pb.line_to(cx + r, y_base);
    pb.close();
    pb
}

/// Church: tower box with door and two arched windows, steep spire (base angle ~70 deg), cross.
fn draw_church(pm: &mut Pixmap, pens: &Pens, cx: f32, by: f32, h: f32) {
    let (w, f) = (pens.w, pens.w * 0.5);
    let hw = 0.15 * h;
    let bh = 0.40 * h;
    let eave = 0.02 * h;
    let top = by - bh;
    // spire (behind the cross, in front of nothing): base angle 70 deg
    let spire_h = (hw + eave) * 70f32.to_radians().tan();
    let mut sp = PathBuilder::new();
    sp.move_to(cx - hw - eave, top);
    sp.line_to(cx, top - spire_h);
    sp.line_to(cx + hw + eave, top);
    sp.close();
    sheet(pm, sp, pens, w);
    // cross on the apex
    let apex = top - spire_h;
    let mut cr = PathBuilder::new();
    cr.move_to(cx, apex);
    cr.line_to(cx, apex - 0.12 * h);
    cr.move_to(cx - 0.05 * h, apex - 0.075 * h);
    cr.line_to(cx + 0.05 * h, apex - 0.075 * h);
    if let Some(p) = cr.finish() {
        line(pm, &p, &paint(pens.ink), &pen(w), None);
    }
    // tower body
    sheet(pm, rect_pb(cx - hw, top, cx + hw, by), pens, w);
    // two arched windows
    let ww = 0.042 * h;
    for dx in [-0.068 * h, 0.068 * h] {
        sheet(pm, arch_pb(cx + dx, by - 0.17 * h, ww, by - 0.27 * h), pens, f);
    }
    // door
    sheet(pm, arch_pb(cx, by, 0.05 * h, by - 0.07 * h), pens, f);
}

/// Town hall: wide box, clock with tick marks and hands, door, small pyramid roof and a flag mast.
fn draw_hall(pm: &mut Pixmap, pens: &Pens, cx: f32, by: f32, h: f32) {
    let (w, f) = (pens.w, pens.w * 0.5);
    let hw = 0.30 * h;
    let bh = 0.58 * h;
    let top = by - bh;
    let eave = 0.03 * h;
    let roof_h = 0.20 * h;
    // pyramid roof
    let mut rf = PathBuilder::new();
    rf.move_to(cx - hw - eave, top);
    rf.line_to(cx, top - roof_h);
    rf.line_to(cx + hw + eave, top);
    rf.close();
    sheet(pm, rf, pens, w);
    // mast
    let mut mast = PathBuilder::new();
    mast.move_to(cx, top - roof_h);
    mast.line_to(cx, top - roof_h - 0.14 * h);
    mast.move_to(cx, top - roof_h - 0.14 * h);
    mast.line_to(cx + 0.09 * h, top - roof_h - 0.115 * h);
    mast.line_to(cx, top - roof_h - 0.09 * h);
    if let Some(p) = mast.finish() {
        line(pm, &p, &paint(pens.ink), &pen(f), None);
    }
    sheet(pm, rect_pb(cx - hw, top, cx + hw, by), pens, w);
    // clock
    let r = 0.16 * h;
    let cy = top + 0.06 * h + r;
    let mut face = PathBuilder::new();
    face.push_circle(cx, cy, r);
    if let Some(p) = face.finish() {
        fill(pm, &p, &paint(pens.paper), None);
        line(pm, &p, &paint(pens.ink), &pen(w), None);
    }
    let mut ticks = PathBuilder::new();
    for i in 0..12 {
        let a = i as f32 * std::f32::consts::TAU / 12.0;
        let r0 = if i % 3 == 0 { 0.62 * r } else { 0.78 * r };
        ticks.move_to(cx + a.sin() * r0, cy - a.cos() * r0);
        ticks.line_to(cx + a.sin() * 0.92 * r, cy - a.cos() * 0.92 * r);
    }
    let mut hands = PathBuilder::new();
    hands.move_to(cx, cy);
    hands.line_to(cx, cy - 0.62 * r);
    hands.move_to(cx, cy);
    hands.line_to(cx + 0.42 * r, cy + 0.20 * r);
    if let Some(p) = ticks.finish() {
        line(pm, &p, &paint(pens.ink), &pen(f * 0.7), None);
    }
    if let Some(p) = hands.finish() {
        line(pm, &p, &paint(pens.ink), &pen(f), None);
    }
    // door
    sheet(pm, arch_pb(cx, by, 0.05 * h, by - 0.09 * h), pens, f);
}
