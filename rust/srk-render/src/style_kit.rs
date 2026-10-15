//! Shared building blocks for the design-research presets (`la`, `ink`).
//!
//! Everything that varies per feature or per pixel is seeded from **world coordinates**
//! (EPSG:3857 metres) or OSM ids, never from tile pixels, so neighbouring tiles agree.

use anyhow::Result;
use geo_types::{Coord, Geometry, LineString, Point, Polygon};
use postgres::Client;
use tiny_skia::{
    BlendMode, Color, FillRule, Mask, Paint, Path, PathBuilder, Pixmap, Stroke, StrokeDash,
    Transform,
};

use crate::paint::{
    clip_line_wkb_sql_fast, clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb,
    envelope_sql, geometry_lines, geometry_points, geometry_polygons,
};
use crate::profile::StageTimers;
use crate::sql_cache::{query_prep, PreparedCache};
use crate::tile::RenderExtent;

// ---------------------------------------------------------------- data

pub struct Feature<G> {
    pub geom: G,
    pub id: i64,
    pub class: String,
    pub sub: String,
    pub num: f64,
    /// Optional second geometry from a `wkb2` column (e.g. a roof ridge).
    pub aux: Option<Geometry<f64>>,
}

pub struct Ctx<'a> {
    pub client: &'a mut Client,
    pub prep: &'a mut PreparedCache,
    pub extent: RenderExtent,
    pub z: u32,
    /// Query envelope grown by this many metres (symbols that bleed in from outside).
    pub margin_m: f64,
}

impl Ctx<'_> {
    fn bounds(&self) -> [f64; 4] {
        let b = self.extent.bounds;
        let m = self.margin_m;
        [b.minx - m, b.miny - m, b.maxx + m, b.maxy + m]
    }

    /// `select` must yield `id bigint, class text, sub text, num float8` plus `wkb` from `clip`.
    fn query(&mut self, select: &str, from_where: &str, order: &str, kind: u8) -> Result<Vec<(i64, String, String, f64, Geometry<f64>, Option<Geometry<f64>>)>> {
        let env = envelope_sql();
        let wkb = match kind {
            3 => clip_polygon_wkb_sql_fast("geom", self.z),
            2 => clip_line_wkb_sql_fast("geom", self.z),
            4 => "ST_AsBinary(geom)".to_string(),
            _ => clip_point_wkb_sql("geom"),
        };
        let sql = format!(
            "SELECT {select}, {wkb} AS wkb FROM {from_where} {and} geom && {env} {order}",
            and = if !from_where.trim_start().starts_with('(') && from_where.to_ascii_uppercase().contains(" WHERE ") { "AND" } else { "WHERE" }
        );
        let [a, b, c, d] = self.bounds();
        let mut timers: Option<&mut StageTimers> = None;
        let rows = query_prep(self.client, self.prep, &mut timers, &sql, &[&a, &b, &c, &d])?;
        let mut out = Vec::with_capacity(rows.len());
        for r in &rows {
            let wkb: Option<Vec<u8>> = r.get("wkb");
            let Some(wkb) = wkb.filter(|w| !w.is_empty()) else { continue };
            let Ok(g) = decode_wkb(&wkb) else { continue };
            let id: Option<i64> = r.try_get("id").ok().flatten();
            let class: Option<String> = r.try_get("class").ok().flatten();
            let sub: Option<String> = r.try_get("sub").ok().flatten();
            let num: Option<f64> = r.try_get("num").ok().flatten();
            let aux = r
                .try_get::<_, Option<Vec<u8>>>("wkb2")
                .ok()
                .flatten()
                .filter(|w| !w.is_empty())
                .and_then(|w| decode_wkb(&w).ok());
            out.push((id.unwrap_or(0), class.unwrap_or_default(), sub.unwrap_or_default(), num.unwrap_or(0.0), g, aux));
        }
        Ok(out)
    }

    pub fn polygons(&mut self, select: &str, from_where: &str, order: &str) -> Result<Vec<Feature<Polygon<f64>>>> {
        Ok(self
            .query(select, from_where, order, 3)?
            .into_iter()
            .flat_map(|(id, class, sub, num, g, aux)| {
                geometry_polygons(g).into_iter().map(move |p| Feature { geom: p, id, class: class.clone(), sub: sub.clone(), num, aux: aux.clone() })
            })
            .collect())
    }

    pub fn lines(&mut self, select: &str, from_where: &str, order: &str) -> Result<Vec<Feature<LineString<f64>>>> {
        Ok(self
            .query(select, from_where, order, 2)?
            .into_iter()
            .flat_map(|(id, class, sub, num, g, aux)| {
                geometry_lines(g).into_iter().map(move |p| Feature { geom: p, id, class: class.clone(), sub: sub.clone(), num, aux: aux.clone() })
            })
            .collect())
    }

    /// Lines **without** clipping (labels need the whole line for stable placement).
    pub fn lines_full(&mut self, select: &str, from_where: &str, order: &str) -> Result<Vec<Feature<LineString<f64>>>> {
        Ok(self
            .query(select, from_where, order, 4)?
            .into_iter()
            .flat_map(|(id, class, sub, num, g, aux)| {
                geometry_lines(g).into_iter().map(move |p| Feature { geom: p, id, class: class.clone(), sub: sub.clone(), num, aux: aux.clone() })
            })
            .collect())
    }

    pub fn points(&mut self, select: &str, from_where: &str, order: &str) -> Result<Vec<Feature<Point<f64>>>> {
        Ok(self
            .query(select, from_where, order, 1)?
            .into_iter()
            .flat_map(|(id, class, sub, num, g, aux)| {
                geometry_points(g).into_iter().map(move |p| Feature { geom: p, id, class: class.clone(), sub: sub.clone(), num, aux: aux.clone() })
            })
            .collect())
    }

    /// Ground metres → pixels at this zoom/latitude (Web Mercator stretch included).
    pub fn m(&self, metres: f64) -> f32 {
        let scale = crate::tile::mercator_scale(self.extent.bounds);
        self.extent.metres_to_px(metres * scale)
    }

    pub fn px(&self, c: Coord<f64>) -> (f32, f32) {
        self.extent.map_to_px(c.x, c.y)
    }

    /// Pixel → world (EPSG:3857).
    pub fn world(&self, px: f32, py: f32) -> (f64, f64) {
        let mpp = self.extent.metres_per_px();
        (self.extent.bounds.minx + f64::from(px) * mpp, self.extent.bounds.maxy - f64::from(py) * mpp)
    }
}

// ---------------------------------------------------------------- hashing & noise

pub fn hash_u64(mut x: u64) -> u64 {
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51afd7ed558ccd);
    x ^= x >> 33;
    x = x.wrapping_mul(0xc4ceb9fe1a85ec53);
    x ^ (x >> 33)
}

/// Deterministic value in [0,1) for an id and a salt.
pub fn rand01(id: i64, salt: u64) -> f32 {
    (hash_u64(id as u64 ^ salt.wrapping_mul(0x9E3779B97F4A7C15)) >> 40) as f32 / (1u64 << 24) as f32
}

fn lattice(ix: i64, iy: i64, seed: u64) -> f32 {
    let h = hash_u64((ix as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ (iy as u64).wrapping_mul(0xC2B2AE3D27D4EB4F) ^ seed);
    (h >> 40) as f32 / (1u64 << 24) as f32
}

/// Smooth value noise in [0,1] on a world grid of `cell` metres.
pub fn value_noise(x: f64, y: f64, cell: f64, seed: u64) -> f32 {
    let gx = x / cell;
    let gy = y / cell;
    let ix = gx.floor() as i64;
    let iy = gy.floor() as i64;
    let fx = (gx - gx.floor()) as f32;
    let fy = (gy - gy.floor()) as f32;
    let sx = fx * fx * (3.0 - 2.0 * fx);
    let sy = fy * fy * (3.0 - 2.0 * fy);
    let a = lattice(ix, iy, seed);
    let b = lattice(ix + 1, iy, seed);
    let c = lattice(ix, iy + 1, seed);
    let d = lattice(ix + 1, iy + 1, seed);
    let top = a + (b - a) * sx;
    let bot = c + (d - c) * sx;
    top + (bot - top) * sy
}

/// Fractal noise in roughly [-1,1].
pub fn fbm(x: f64, y: f64, cell: f64, octaves: u32, seed: u64) -> f32 {
    let mut sum = 0.0;
    let mut amp = 1.0;
    let mut norm = 0.0;
    let mut c = cell;
    for o in 0..octaves {
        sum += (value_noise(x, y, c, seed.wrapping_add(o as u64 * 7919)) * 2.0 - 1.0) * amp;
        norm += amp;
        amp *= 0.5;
        c *= 0.5;
    }
    sum / norm
}

/// Jittered points on a world grid of `cell` metres inside the (margin-grown) extent.
/// Each cell contributes one point with probability `density`; returns (x, y, rand).
pub fn world_scatter(ctx: &Ctx, cell: f64, density: f32, seed: u64) -> Vec<(f64, f64, f32)> {
    let b = ctx.extent.bounds;
    let m = ctx.margin_m;
    let x0 = ((b.minx - m) / cell).floor() as i64;
    let x1 = ((b.maxx + m) / cell).ceil() as i64;
    let y0 = ((b.miny - m) / cell).floor() as i64;
    let y1 = ((b.maxy + m) / cell).ceil() as i64;
    let mut out = Vec::new();
    for ix in x0..=x1 {
        for iy in y0..=y1 {
            if lattice(ix, iy, seed ^ 0x51) >= density {
                continue;
            }
            let jx = lattice(ix, iy, seed ^ 0xA1);
            let jy = lattice(ix, iy, seed ^ 0xB2);
            out.push(((ix as f64 + f64::from(jx)) * cell, (iy as f64 + f64::from(jy)) * cell, lattice(ix, iy, seed ^ 0xC3)));
        }
    }
    out
}

// ---------------------------------------------------------------- colours & paint

pub fn hex(h: &str) -> Color {
    crate::tile::parse_hex_color(h).unwrap_or(Color::BLACK)
}

pub fn with_alpha(mut c: Color, a: f32) -> Color {
    c.set_alpha(a.clamp(0.0, 1.0));
    c
}

pub fn shade(c: Color, f: f32) -> Color {
    Color::from_rgba(
        (c.red() * f).clamp(0.0, 1.0),
        (c.green() * f).clamp(0.0, 1.0),
        (c.blue() * f).clamp(0.0, 1.0),
        c.alpha(),
    )
    .unwrap_or(c)
}

pub fn mix(a: Color, b: Color, t: f32) -> Color {
    Color::from_rgba(
        a.red() + (b.red() - a.red()) * t,
        a.green() + (b.green() - a.green()) * t,
        a.blue() + (b.blue() - a.blue()) * t,
        a.alpha() + (b.alpha() - a.alpha()) * t,
    )
    .unwrap_or(a)
}

pub fn paint(color: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(color);
    p.anti_alias = true;
    p
}

pub fn paint_blend(color: Color, mode: BlendMode) -> Paint<'static> {
    let mut p = paint(color);
    p.blend_mode = mode;
    p
}

pub fn stroke(width: f32) -> Stroke {
    Stroke { width, line_cap: tiny_skia::LineCap::Round, line_join: tiny_skia::LineJoin::Round, ..Default::default() }
}

pub fn dashed(width: f32, on: f32, off: f32) -> Stroke {
    let mut s = stroke(width);
    s.line_cap = tiny_skia::LineCap::Butt;
    s.dash = StrokeDash::new(vec![on, off], 0.0);
    s
}

pub fn fill(pm: &mut Pixmap, path: &Path, p: &Paint, mask: Option<&Mask>) {
    pm.fill_path(path, p, FillRule::EvenOdd, Transform::identity(), mask);
}

pub fn line(pm: &mut Pixmap, path: &Path, p: &Paint, s: &Stroke, mask: Option<&Mask>) {
    pm.stroke_path(path, p, s, Transform::identity(), mask);
}

// ---------------------------------------------------------------- geometry → paths

fn ring_pts(ctx: &Ctx, ring: &LineString<f64>) -> Vec<(f32, f32)> {
    ring.coords().map(|c| ctx.px(*c)).collect()
}

pub fn pts_path(pts: &[(f32, f32)], close: bool) -> Option<Path> {
    let mut pb = PathBuilder::new();
    let mut it = pts.iter();
    let (x, y) = it.next()?;
    pb.move_to(*x, *y);
    for (x, y) in it {
        pb.line_to(*x, *y);
    }
    if close {
        pb.close();
    }
    pb.finish()
}

pub fn poly_path(ctx: &Ctx, poly: &Polygon<f64>) -> Option<Path> {
    let mut pb = PathBuilder::new();
    for ring in std::iter::once(poly.exterior()).chain(poly.interiors()) {
        let pts = ring_pts(ctx, ring);
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

pub fn line_path(ctx: &Ctx, l: &LineString<f64>) -> Option<Path> {
    pts_path(&ring_pts(ctx, l), false)
}

/// Polygon path shifted by (dx, dy) pixels.
pub fn poly_path_shifted(ctx: &Ctx, poly: &Polygon<f64>, dx: f32, dy: f32) -> Option<Path> {
    poly_path(ctx, poly)?.transform(Transform::from_translate(dx, dy))
}

/// Subdivide a pixel polyline and displace it with world-anchored noise (hand-drawn wobble).
pub fn wobble_pts(ctx: &Ctx, pts: &[(f32, f32)], amp_px: f32, step_px: f32, seed: u64) -> Vec<(f32, f32)> {
    let mut out = Vec::new();
    for w in pts.windows(2) {
        let (x0, y0) = w[0];
        let (x1, y1) = w[1];
        let len = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
        let n = (len / step_px).ceil().max(1.0) as usize;
        for i in 0..n {
            let t = i as f32 / n as f32;
            out.push((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t));
        }
    }
    if let Some(l) = pts.last() {
        out.push(*l);
    }
    let cell = f64::from(step_px * 6.0) * ctx.extent.metres_per_px();
    out.iter()
        .map(|&(x, y)| {
            let (wx, wy) = ctx.world(x, y);
            let dx = fbm(wx, wy, cell, 2, seed) * amp_px;
            let dy = fbm(wx, wy, cell, 2, seed ^ 0x77) * amp_px;
            (x + dx, y + dy)
        })
        .collect()
}

pub fn poly_rings_px(ctx: &Ctx, poly: &Polygon<f64>) -> Vec<Vec<(f32, f32)>> {
    std::iter::once(poly.exterior()).chain(poly.interiors()).map(|r| ring_pts(ctx, r)).collect()
}

/// Mask from polygons (anti-aliased).
pub fn mask_of(ctx: &Ctx, polys: &[&Polygon<f64>]) -> Option<Mask> {
    let mut mask = Mask::new(ctx.extent.width_px, ctx.extent.height_px)?;
    for p in polys {
        if let Some(path) = poly_path(ctx, p) {
            mask.fill_path(&path, FillRule::EvenOdd, true, Transform::identity());
        }
    }
    Some(mask)
}

/// Parallel hatch lines over the whole render buffer at `angle_deg`, phase anchored to the world.
pub fn hatch_path(ctx: &Ctx, spacing_px: f32, angle_deg: f32, x0: f32, y0: f32, x1: f32, y1: f32) -> Option<Path> {
    let a = angle_deg.to_radians();
    let (dx, dy) = (a.cos(), a.sin());
    let (nx, ny) = (-dy, dx);
    // world-anchored phase: project the world origin of the buffer onto the normal
    let mpp = ctx.extent.metres_per_px() as f32;
    let ox = (ctx.extent.bounds.minx as f32 / mpp).rem_euclid(spacing_px * 1000.0);
    let oy = (-(ctx.extent.bounds.maxy as f32) / mpp).rem_euclid(spacing_px * 1000.0);
    let phase = (ox * nx + oy * ny).rem_euclid(spacing_px);
    let cx = (x0 + x1) / 2.0;
    let cy = (y0 + y1) / 2.0;
    let r = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt() / 2.0 + spacing_px;
    let base = (cx * nx + cy * ny + phase) .rem_euclid(spacing_px);
    let mut pb = PathBuilder::new();
    let mut t = -r - base;
    while t <= r {
        let px = cx + nx * t;
        let py = cy + ny * t;
        pb.move_to(px - dx * r, py - dy * r);
        pb.line_to(px + dx * r, py + dy * r);
        t += spacing_px;
    }
    pb.finish()
}

pub fn bbox_px(pts: &[(f32, f32)]) -> (f32, f32, f32, f32) {
    let mut b = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for &(x, y) in pts {
        b.0 = b.0.min(x);
        b.1 = b.1.min(y);
        b.2 = b.2.max(x);
        b.3 = b.3.max(y);
    }
    b
}

/// Scalloped (cloud) outline around a circle.
pub fn scallop_pts(cx: f32, cy: f32, r: f32, bumps: u32, amp: f32, phase: f32) -> Vec<(f32, f32)> {
    let steps = (bumps * 8).max(24);
    (0..steps)
        .map(|i| {
            let t = i as f32 / steps as f32 * std::f32::consts::TAU;
            let rr = r * (1.0 + amp * ((bumps as f32 * t + phase).sin()).abs().powf(0.6) - amp * 0.5);
            (cx + rr * t.cos(), cy + rr * t.sin())
        })
        .collect()
}

/// Per-pixel multiply by `1 + strength * noise(world)` where `mask` (optional) is set.
pub fn apply_grain(ctx: &Ctx, pm: &mut Pixmap, mask: Option<&Mask>, cell_m: f64, octaves: u32, strength: f32, seed: u64) {
    let w = pm.width() as usize;
    let mdata = mask.map(|m| m.data());
    let data = pm.data_mut();
    let mpp = ctx.extent.metres_per_px();
    for (i, px) in data.chunks_exact_mut(4).enumerate() {
        let a = match mdata {
            Some(m) => f32::from(m[i]) / 255.0,
            None => 1.0,
        };
        if a <= 0.0 {
            continue;
        }
        let x = (i % w) as f64;
        let y = (i / w) as f64;
        let wx = ctx.extent.bounds.minx + x * mpp;
        let wy = ctx.extent.bounds.maxy - y * mpp;
        let n = fbm(wx, wy, cell_m, octaves, seed);
        let f = 1.0 + strength * n * a;
        for c in &mut px[..3] {
            *c = (f32::from(*c) * f).clamp(0.0, 255.0) as u8;
        }
    }
}

/// Points every `step_px` along a pixel polyline: (x, y, direction radians).
pub fn along(pts: &[(f32, f32)], step_px: f32, offset_px: f32) -> Vec<(f32, f32, f32)> {
    let mut out = Vec::new();
    let mut next = offset_px;
    let mut acc = 0.0f32;
    for w in pts.windows(2) {
        let (x0, y0) = w[0];
        let (x1, y1) = w[1];
        let len = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
        if len <= 0.0 {
            continue;
        }
        let a = (y1 - y0).atan2(x1 - x0);
        while next <= acc + len {
            let t = (next - acc) / len;
            out.push((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, a));
            next += step_px;
        }
        acc += len;
    }
    out
}

pub fn line_pts(ctx: &Ctx, l: &LineString<f64>) -> Vec<(f32, f32)> {
    l.coords().map(|c| ctx.px(*c)).collect()
}

/// Rotated rectangle path centred at (x, y).
pub fn rect_rot(x: f32, y: f32, w: f32, h: f32, angle: f32) -> Option<Path> {
    let (c, s) = (angle.cos(), angle.sin());
    let pts: Vec<(f32, f32)> = [(-w / 2.0, -h / 2.0), (w / 2.0, -h / 2.0), (w / 2.0, h / 2.0), (-w / 2.0, h / 2.0)]
        .iter()
        .map(|&(dx, dy)| (x + dx * c - dy * s, y + dx * s + dy * c))
        .collect();
    pts_path(&pts, true)
}

/// World cell size that keeps a constant on-screen density across zooms (tuned at z19).
pub fn zcell(z: u32, cell_m: f64) -> f64 {
    cell_m * 2f64.powi(19 - z as i32)
}

/// Draw `layer` onto `pm` after pulling its colours `amount` (0..1) towards their luminance.
pub fn draw_desaturated(pm: &mut Pixmap, layer: &mut Pixmap, amount: f32, opacity: f32) {
    for px in layer.data_mut().chunks_exact_mut(4) {
        if px[3] == 0 {
            continue;
        }
        let (r, g, b) = (f32::from(px[0]), f32::from(px[1]), f32::from(px[2]));
        let l = 0.3 * r + 0.59 * g + 0.11 * b;
        px[0] = (r + (l - r) * amount) as u8;
        px[1] = (g + (l - g) * amount) as u8;
        px[2] = (b + (l - b) * amount) as u8;
    }
    let mut pp = tiny_skia::PixmapPaint::default();
    pp.opacity = opacity;
    pm.draw_pixmap(0, 0, layer.as_ref(), &pp, Transform::identity(), None);
}


// ---------------------------------------------------------------- labels

pub struct LabelStyle {
    pub family: &'static str,
    pub italic: bool,
    pub weight: u32,
    pub size_px: f32,
    pub letter_spacing_em: f32,
    pub uppercase: bool,
    pub fill: &'static str,
    pub halo: &'static str,
    pub halo_px: f32,
    /// Distance between repeated labels along a street, in pixels.
    pub repeat_px: f32,
}

fn font_db() -> std::sync::Arc<resvg::usvg::fontdb::Database> {
    static DB: std::sync::OnceLock<std::sync::Arc<resvg::usvg::fontdb::Database>> = std::sync::OnceLock::new();
    DB.get_or_init(|| {
        let mut db = resvg::usvg::fontdb::Database::new();
        db.load_system_fonts();
        std::sync::Arc::new(db)
    })
    .clone()
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Street names along `label_highway`, placed at world-stable arc positions (seamless tiles).
pub fn draw_street_labels(ctx: &mut Ctx, pm: &mut Pixmap, st: &LabelStyle) -> Result<()> {
    let labels = ctx.lines_full("0::bigint AS id, name AS class, class AS sub, 0::float8 AS num", "label_highway WHERE name IS NOT NULL", "")?;
    let mut defs = String::new();
    let mut texts = String::new();
    for (i, f) in labels.iter().enumerate() {
        let mut pts = line_pts(ctx, &f.geom);
        if pts.len() < 2 {
            continue;
        }
        // keep text upright: run left → right
        if pts.last().unwrap().0 < pts[0].0 {
            pts.reverse();
        }
        let total: f32 = pts.windows(2).map(|w| ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt()).sum();
        let name = if st.uppercase { f.class.to_uppercase() } else { f.class.clone() };
        let est = name.chars().count() as f32 * st.size_px * (0.55 + st.letter_spacing_em);
        if total < est * 1.3 {
            continue;
        }
        let d: String = pts
            .iter()
            .enumerate()
            .map(|(k, (x, y))| format!("{}{:.1},{:.1}", if k == 0 { "M" } else { " L" }, x, y))
            .collect();
        defs.push_str(&format!("<path id=\"l{i}\" d=\"{d}\"/>"));
        // anchors at world-stable positions: middle of the line, then ± repeat
        let mid = total / 2.0;
        let mut anchors = vec![mid];
        let mut k = 1.0;
        while mid - k * st.repeat_px > est {
            anchors.push(mid - k * st.repeat_px);
            anchors.push(mid + k * st.repeat_px);
            k += 1.0;
        }
        for a in anchors {
            if a - est / 2.0 < 0.0 || a + est / 2.0 > total {
                continue;
            }
            texts.push_str(&format!(
                "<text><textPath href=\"#l{i}\" startOffset=\"{a:.1}\" text-anchor=\"middle\">{}</textPath></text>",
                xml_escape(&name)
            ));
        }
    }
    if texts.is_empty() {
        return Ok(());
    }
    let (w, h) = (ctx.extent.width_px, ctx.extent.height_px);
    let svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
<defs>{defs}</defs>
<g font-family="{fam}" font-size="{size}" font-style="{style}" font-weight="{weight}" letter-spacing="{ls}" fill="{fill}"
   stroke="{halo}" stroke-width="{hw}" stroke-linejoin="round" paint-order="stroke" dominant-baseline="central">{texts}</g></svg>"##,
        fam = st.family,
        size = st.size_px,
        style = if st.italic { "italic" } else { "normal" },
        weight = st.weight,
        ls = st.letter_spacing_em * st.size_px,
        fill = st.fill,
        halo = st.halo,
        hw = st.halo_px,
    );
    let mut opts = resvg::usvg::Options::default();
    opts.fontdb = font_db();
    let tree = match resvg::usvg::Tree::from_str(&svg, &opts) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("warn: label svg: {e}");
            return Ok(());
        }
    };
    let Some(mut layer) = resvg::tiny_skia::Pixmap::new(w, h) else { return Ok(()) };
    resvg::render(&tree, resvg::tiny_skia::Transform::identity(), &mut layer.as_mut());
    if let Some(ours) = tiny_skia::IntSize::from_wh(w, h).and_then(|sz| Pixmap::from_vec(layer.take(), sz)) {
        pm.draw_pixmap(0, 0, ours.as_ref(), &tiny_skia::PixmapPaint::default(), Transform::identity(), None);
    }
    Ok(())
}
