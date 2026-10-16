//! Shared building blocks for the design-research presets (`la`, `ink`).
//!
//! Everything that varies per feature or per pixel is seeded from **world coordinates**
//! (EPSG:3857 metres) or OSM ids, never from tile pixels, so neighbouring tiles agree.

use anyhow::Result;
use geo_types::{Coord, Geometry, LineString, Point, Polygon};
use postgres::Client;
use tiny_skia::{
    BlendMode, Color, FillRule, Mask, Paint, Path, PathBuilder, Pixmap, Stroke,
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
        let t0 = std::time::Instant::now();
        let rows = query_prep(self.client, self.prep, &mut timers, &sql, &[&a, &b, &c, &d])?;
        if kit_profile() {
            let what: String = from_where.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(70).collect();
            eprintln!("kit-sql z{} {:>6}ms {:>6} rows  {what}", self.z, t0.elapsed().as_millis(), rows.len());
        }
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
        self.extent.metres_to_px(metres * self.ref_scale())
    }

    /// 1/cos(φ) at the centre of the z10 tile that contains this extent. Using the extent's own
    /// centre would make sizes (and hatch spacing) differ slightly between metatile layouts.
    pub fn ref_scale(&self) -> f64 {
        let b = self.extent.bounds;
        let cy = (b.miny + b.maxy) / 2.0;
        let tile = 2.0 * crate::tile::ORIGIN_SHIFT / 1024.0;
        let y = ((cy + crate::tile::ORIGIN_SHIFT) / tile).floor() * tile + tile / 2.0 - crate::tile::ORIGIN_SHIFT;
        let lat = (2.0 * (y / 6_378_137.0).exp().atan() - std::f64::consts::FRAC_PI_2).to_degrees();
        1.0 / lat.to_radians().cos()
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

/// `SRK_KIT_PROFILE=1`: log every style-kit query (ms, rows) and paint stage to stderr.
pub fn kit_profile() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var("SRK_KIT_PROFILE").is_ok())
}

/// Log the time since `t` under `label` (only with `SRK_KIT_PROFILE`), then reset `t`.
pub fn lap(t: &mut std::time::Instant, label: &str) {
    if kit_profile() {
        eprintln!("kit-lap {:>6}ms  {label}", t.elapsed().as_millis());
    }
    *t = std::time::Instant::now();
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

/// Parallel hatch lines covering the pixel box (x0,y0)-(x1,y1) at `angle_deg`.
/// Line positions are anchored to the world (f64), so every tile/metatile draws the same lines.
pub fn hatch_path(ctx: &Ctx, spacing_px: f32, angle_deg: f32, x0: f32, y0: f32, x1: f32, y1: f32) -> Option<Path> {
    let a = f64::from(angle_deg).to_radians();
    let (dx, dy) = (a.cos(), a.sin());
    let (nx, ny) = (-dy, dx);
    let sp = f64::from(spacing_px);
    let mpp = ctx.extent.metres_per_px();
    // pixel p belongs to a line when p·n ≡ offset (mod sp)
    let offset = (-(ctx.extent.bounds.minx * nx - ctx.extent.bounds.maxy * ny) / mpp).rem_euclid(sp);
    let (cx, cy) = (f64::from(x0 + x1) / 2.0, f64::from(y0 + y1) / 2.0);
    let r = f64::from(((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt() / 2.0 + spacing_px);
    let c = cx * nx + cy * ny;
    let k0 = ((c - r - offset) / sp).floor() as i64;
    let k1 = ((c + r - offset) / sp).ceil() as i64;
    let mut pb = PathBuilder::new();
    for k in k0..=k1 {
        let t = offset + k as f64 * sp;
        // foot point of the line closest to the box centre
        let (fx, fy) = (cx + nx * (t - c), cy + ny * (t - c));
        pb.move_to((fx - dx * r) as f32, (fy - dy * r) as f32);
        pb.line_to((fx + dx * r) as f32, (fy + dy * r) as f32);
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
    // Seam safety: the set of candidate labels and the de-duplication must not depend on the
    // render extent. So (1) query with a wide margin, so every candidate that can suppress a
    // visible one is known in every metatile layout, and (2) decide duplicates by a world-anchored
    // key instead of by query order.
    let margin = ctx.margin_m;
    ctx.margin_m = margin.max(250.0);
    let labels = ctx.lines_full(
        "0::bigint AS id, name AS class, class AS sub, 0::float8 AS num",
        "label_highway WHERE name IS NOT NULL",
        "ORDER BY name, ST_XMin(geom), ST_YMin(geom)",
    );
    ctx.margin_m = margin;
    let labels = labels?;
    let mut defs = String::new();
    let mut texts = String::new();
    // candidates: (name, line index, arc offset, pixel anchor, world key, text length)
    let mut cands: Vec<(String, usize, f32, (f32, f32), (i64, i64), f32)> = Vec::new();
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
            let (ax, ay) = point_at(&pts, a);
            let (wx, wy) = ctx.world(ax, ay);
            cands.push((name.clone(), i, a, (ax, ay), ((wx * 10.0).round() as i64, (wy * 10.0).round() as i64), est));
        }
    }
    // dual carriageways come as two parallel label lines: of all same-name candidates closer than
    // 1.2 text lengths, keep the one with the smallest world key — the same choice in every tile
    for (k, (name, i, a, (ax, ay), key, est)) in cands.iter().enumerate() {
        let beaten = cands.iter().enumerate().any(|(j, (n2, _, _, (x2, y2), key2, _))| {
            j != k && n2 == name && key2 < key && (x2 - ax).powi(2) + (y2 - ay).powi(2) < (est * 1.2).powi(2)
        });
        if beaten {
            continue;
        }
        texts.push_str(&format!(
            "<text><textPath href=\"#l{i}\" startOffset=\"{a:.1}\" text-anchor=\"middle\">{}</textPath></text>",
            xml_escape(name)
        ));
    }
    render_svg_text(ctx, pm, &defs, &texts, st);
    Ok(())
}

/// Names of large named areas (parks, cemeteries, recreation grounds …), horizontal, centred on
/// `ST_PointOnSurface` of the whole polygon (world-stable). `min_area_px`: smallest area that gets a name.
pub fn draw_area_labels(ctx: &mut Ctx, pm: &mut Pixmap, st: &LabelStyle, min_area_px: f64, max_size_px: f32) -> Result<()> {
    let mpp = ctx.extent.metres_per_px();
    // label point on the polygon, but never on top of a building (e.g. the church on Herrfurthplatz)
    let from = r#"(SELECT osm_id, name, class, a, geom FROM (
                    SELECT l.osm_id, l.name, l.class, ST_Area(l.geom) AS a, ST_PointOnSurface(l.geom) AS geom
                    FROM landuse l
                    WHERE l.name IS NOT NULL
                      AND l.class IN ('park', 'recreation_ground', 'cemetery', 'garden', 'village_green', 'allotments', 'meadow', 'forest', 'wood')
                      AND l.geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)) p
                  WHERE NOT EXISTS (SELECT 1 FROM building b WHERE ST_DWithin(b.geom, p.geom, 25))) q"#;
    let pts = ctx.points("osm_id AS id, name AS class, NULL::text AS sub, a::float8 AS num", from, "")?;
    let mut texts = String::new();
    for f in &pts {
        let area_px = f.num / (mpp * mpp);
        if area_px < min_area_px {
            continue;
        }
        let (x, y) = ctx.px(f.geom.0);
        let name = if st.uppercase { f.class.to_uppercase() } else { f.class.clone() };
        let size = (st.size_px * (area_px / min_area_px).powf(0.12) as f32).min(max_size_px);
        let est = name.chars().count() as f32 * size * (0.6 + st.letter_spacing_em);
        if f64::from(est) > area_px.sqrt() * 1.8 {
            continue;
        }
        texts.push_str(&format!(
            "<text x=\"{x:.1}\" y=\"{y:.1}\" font-size=\"{size:.1}\" letter-spacing=\"{ls:.2}\" text-anchor=\"middle\">{}</text>",
            xml_escape(&name),
            ls = st.letter_spacing_em * size
        ));
    }
    render_svg_text(ctx, pm, "", &texts, st);
    Ok(())
}

fn render_svg_text(ctx: &Ctx, pm: &mut Pixmap, defs: &str, texts: &str, st: &LabelStyle) {
    if texts.is_empty() {
        return;
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
            return;
        }
    };
    let Some(mut layer) = resvg::tiny_skia::Pixmap::new(w, h) else { return };
    resvg::render(&tree, resvg::tiny_skia::Transform::identity(), &mut layer.as_mut());
    if let Some(ours) = tiny_skia::IntSize::from_wh(w, h).and_then(|sz| Pixmap::from_vec(layer.take(), sz)) {
        pm.draw_pixmap(0, 0, ours.as_ref(), &tiny_skia::PixmapPaint::default(), Transform::identity(), None);
    }
}

/// Approximate gaussian blur of a premultiplied layer: three box-blur passes per axis.
///
/// Only the bounding box of the non-transparent pixels, grown by the reach of the three passes,
/// is processed (everything outside stays zero, so the result is identical to a full-frame
/// blur). The vertical pass sweeps whole rows at once instead of walking columns (cache-friendly).
pub fn blur_layer(layer: &mut Pixmap, radius: usize) {
    if radius == 0 {
        return;
    }
    let (w, h) = (layer.width() as usize, layer.height() as usize);
    let data = layer.data_mut();
    let Some((bx0, by0, bx1, by1)) = opaque_bbox(data, w, h) else { return };
    let pad = 3 * radius + 2;
    let (x0, x1) = (bx0.saturating_sub(pad), (bx1 + pad).min(w - 1));
    let (y0, y1) = (by0.saturating_sub(pad), (by1 + pad).min(h - 1));
    let rw = x1 - x0 + 1;
    let rh = y1 - y0 + 1;
    let mut src = vec![0u8; rw * rh * 4];
    let mut acc = vec![0u32; rw * 4];
    for _ in 0..3 {
        for y in y0..=y1 {
            let row = &mut data[(y * w + x0) * 4..(y * w + x1 + 1) * 4];
            box_row(row, &mut src[..rw * 4], rw, radius);
        }
        box_cols(data, &mut src, &mut acc, w, x0, rw, y0, rh, radius);
    }
}

/// Bounding box (inclusive) of pixels with any non-zero byte.
fn opaque_bbox(data: &[u8], w: usize, h: usize) -> Option<(usize, usize, usize, usize)> {
    let mut b: Option<(usize, usize, usize, usize)> = None;
    for y in 0..h {
        let row = &data[y * w * 4..(y + 1) * w * 4];
        let nz = |p: &[u8]| u32::from_ne_bytes([p[0], p[1], p[2], p[3]]) != 0;
        let Some(first) = row.chunks_exact(4).position(nz) else { continue };
        let last = row.chunks_exact(4).rposition(nz).unwrap_or(first);
        b = Some(match b {
            None => (first, y, last, y),
            Some((a, by, c, _)) => (a.min(first), by, c.max(last), y),
        });
    }
    b
}

/// `sum / win` for the box blur, as a multiply-shift. With m = floor(2^32 / win) + 1 the result is
/// exact for every sum below 2^32 / win, which covers 255 · win for win < 4096 (the fallback
/// division handles larger windows).
#[derive(Clone, Copy)]
struct BoxDiv {
    win: u32,
    m: u64,
}

impl BoxDiv {
    fn new(win: u32) -> Self {
        let m = if win < 4096 { (1u64 << 32) / u64::from(win) + 1 } else { 0 };
        Self { win, m }
    }

    #[inline(always)]
    fn div(self, sum: u32) -> u8 {
        if self.m == 0 {
            (sum / self.win) as u8
        } else {
            ((u64::from(sum) * self.m) >> 32) as u8
        }
    }
}

/// One horizontal box pass over `n` RGBA pixels with clamp-to-edge (same arithmetic as before:
/// window sum / (2r+1), truncating).
fn box_row(row: &mut [u8], buf: &mut [u8], n: usize, r: usize) {
    buf.copy_from_slice(row);
    let dv = BoxDiv::new((2 * r + 1) as u32);
    let mut acc = [0u32; 4];
    for k in 0..=r.min(n - 1) {
        for c in 0..4 {
            acc[c] += u32::from(buf[k * 4 + c]);
        }
    }
    for c in 0..4 {
        acc[c] += u32::from(buf[c]) * r as u32; // clamp-to-edge on the left
    }
    for i in 0..n {
        let add = (i + r + 1).min(n - 1) * 4;
        let sub = i.saturating_sub(r) * 4;
        for c in 0..4 {
            row[i * 4 + c] = dv.div(acc[c]);
            acc[c] += u32::from(buf[add + c]);
            acc[c] -= u32::from(buf[sub + c]);
        }
    }
}

/// One vertical box pass over the region columns `x0..x0+rw`, rows `y0..y0+rh`, all columns
/// swept together row by row.
#[allow(clippy::too_many_arguments)]
fn box_cols(data: &mut [u8], src: &mut [u8], acc: &mut [u32], w: usize, x0: usize, rw: usize, y0: usize, rh: usize, r: usize) {
    let rb = rw * 4;
    let src = &mut src[..rh * rb];
    for i in 0..rh {
        let o = ((y0 + i) * w + x0) * 4;
        src[i * rb..(i + 1) * rb].copy_from_slice(&data[o..o + rb]);
    }
    let dv = BoxDiv::new((2 * r + 1) as u32);
    for (j, a) in acc.iter_mut().enumerate() {
        *a = u32::from(src[j]) * r as u32; // clamp-to-edge at the top
    }
    for k in 0..=r.min(rh - 1) {
        let s = &src[k * rb..(k + 1) * rb];
        for (a, &v) in acc.iter_mut().zip(s) {
            *a += u32::from(v);
        }
    }
    for i in 0..rh {
        let o = ((y0 + i) * w + x0) * 4;
        let add = (i + r + 1).min(rh - 1) * rb;
        let sub = i.saturating_sub(r) * rb;
        let out = &mut data[o..o + rb];
        for j in 0..rb {
            out[j] = dv.div(acc[j]);
            acc[j] += u32::from(src[add + j]);
            acc[j] -= u32::from(src[sub + j]);
        }
    }
}

pub fn draw_layer(pm: &mut Pixmap, layer: &Pixmap, opacity: f32, mode: BlendMode) {
    let mut pp = tiny_skia::PixmapPaint::default();
    pp.opacity = opacity;
    pp.blend_mode = mode;
    pm.draw_pixmap(0, 0, layer.as_ref(), &pp, Transform::identity(), None);
}

pub fn new_layer(ctx: &Ctx) -> Pixmap {
    Pixmap::new(ctx.extent.width_px, ctx.extent.height_px).expect("layer")
}

/// Procedural pitch line markings from `pitch_markings` (centre point, Mercator-metre extents,
/// direction like the SVG stamps: long axis rotated by direction + 90°).
pub fn pitch_marking_path(ctx: &mut Ctx) -> Result<Option<Path>> {
    let pts = ctx.points(
        "osm_id AS id, sport AS class, (dist_long::text || ';' || dist_short::text) AS sub, COALESCE(direction, 0)::float8 AS num",
        "pitch_markings",
        "",
    )?;
    let mut pb = PathBuilder::new();
    for f in &pts {
        let mut it = f.sub.split(';').map(|v| v.parse::<f64>().unwrap_or(0.0));
        let (l, s) = (it.next().unwrap_or(0.0), it.next().unwrap_or(0.0));
        if l <= 0.0 || s <= 0.0 {
            continue;
        }
        let (cx, cy) = ctx.px(f.geom.0);
        let hl = ctx.extent.metres_to_px(l) / 2.0 * 0.96;
        let hs = ctx.extent.metres_to_px(s) / 2.0 * 0.94;
        let a = (f.num as f32 + 90.0).to_radians();
        let (ca, sa) = (a.cos(), a.sin());
        let tr = |u: f32, v: f32| (cx + u * ca - v * sa, cy + u * sa + v * ca);
        let mut poly = |p: &[(f32, f32)], close: bool| {
            let q: Vec<(f32, f32)> = p.iter().map(|&(u, v)| tr(u, v)).collect();
            if let Some(path) = pts_path(&q, close) {
                pb.push_path(&path);
            }
        };
        poly(&[(-hl, -hs), (hl, -hs), (hl, hs), (-hl, hs)], true);
        poly(&[(0.0, -hs), (0.0, hs)], false);
        let r = hs * 0.28;
        let circle: Vec<(f32, f32)> = (0..32).map(|i| {
            let t = i as f32 / 32.0 * std::f32::consts::TAU;
            (r * t.cos(), r * t.sin())
        }).collect();
        poly(&circle, true);
        let (bd, bw) = if f.class == "basketball" { (hl * 0.28, hs * 0.3) } else { (hl * 0.18, hs * 0.5) };
        for sgn in [-1.0f32, 1.0] {
            let x0 = sgn * hl;
            let x1 = sgn * (hl - bd);
            poly(&[(x0, -bw), (x1, -bw), (x1, bw), (x0, bw)], false);
        }
    }
    Ok(pb.finish())
}

/// Point at arc length `s` along a pixel polyline.
pub fn point_at(pts: &[(f32, f32)], s: f32) -> (f32, f32) {
    let mut acc = 0.0;
    for w in pts.windows(2) {
        let len = ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt();
        if acc + len >= s && len > 0.0 {
            let t = (s - acc) / len;
            return (w[0].0 + (w[1].0 - w[0].0) * t, w[0].1 + (w[1].1 - w[0].1) * t);
        }
        acc += len;
    }
    *pts.last().unwrap_or(&(0.0, 0.0))
}

/// Slope hachures along an embankment/cliff line: strokes towards the downhill side (OSM: right
/// of the way direction), alternating long and short like hand-drawn hachures.
pub fn hachures(pts: &[(f32, f32)], spacing: f32, len: f32) -> Option<Path> {
    let mut pb = PathBuilder::new();
    for (i, (x, y, a)) in along(pts, spacing, spacing * 0.5).into_iter().enumerate() {
        let (tx, ty) = (a.cos(), a.sin());
        // pixel space (y down): right-hand side of travel = (-ty, tx)
        let (nx, ny) = (-ty, tx);
        let l = if i % 2 == 0 { len } else { len * 0.55 };
        pb.move_to(x, y);
        pb.line_to(x + nx * l, y + ny * l);
    }
    pb.finish()
}

/// Railway lines (not tunnels/subways underground): returns (pixel polyline, is_main) pairs.
pub fn railway_lines(ctx: &mut Ctx) -> Result<Vec<(Vec<(f32, f32)>, bool)>> {
    // whole lines, not clipped: along()-based sleepers and ties then start at a world-stable point
    let lines = ctx.lines_full(
        "osm_id AS id, railway AS class, COALESCE(service, '') AS sub, 0::float8 AS num",
        "railway_way WHERE railway IN ('rail', 'light_rail', 'subway', 'disused', 'tram', 'narrow_gauge') AND COALESCE(tunnel, 'no') = 'no'",
        "ORDER BY COALESCE(layer, 0)",
    )?;
    Ok(lines
        .iter()
        .map(|f| (line_pts(ctx, &f.geom), f.sub.is_empty() && f.class != "disused"))
        .collect())
}

/// Screen angle (degrees, pixel space, y down) of a map bearing (0 = north, clockwise).
pub fn bearing_to_screen_deg(bearing_deg: f64) -> f32 {
    let a = bearing_deg.to_radians();
    (-(a.cos())).atan2(a.sin()).to_degrees() as f32
}

/// Hatch lines clipped analytically to a polygon (pixel rings): no mask needed, so it is cheap
/// for hundreds of small roof facets. Line positions are world-anchored like `hatch_path`.
pub fn hatch_in_polygon(ctx: &Ctx, rings: &[Vec<(f32, f32)>], spacing_px: f32, angle_deg: f32) -> Option<Path> {
    let a = f64::from(angle_deg).to_radians();
    let (dx, dy) = (a.cos(), a.sin());
    let (nx, ny) = (-dy, dx);
    let sp = f64::from(spacing_px);
    let mpp = ctx.extent.metres_per_px();
    let offset = (-(ctx.extent.bounds.minx * nx - ctx.extent.bounds.maxy * ny) / mpp).rem_euclid(sp);
    let mut smin = f64::MAX;
    let mut smax = f64::MIN;
    for r in rings {
        for &(x, y) in r {
            let s = f64::from(x) * nx + f64::from(y) * ny;
            smin = smin.min(s);
            smax = smax.max(s);
        }
    }
    if smin > smax {
        return None;
    }
    let k0 = ((smin - offset) / sp).ceil() as i64;
    let k1 = ((smax - offset) / sp).floor() as i64;
    let mut pb = PathBuilder::new();
    let mut us: Vec<f64> = Vec::new();
    for k in k0..=k1 {
        let t = offset + k as f64 * sp;
        us.clear();
        for r in rings {
            let n = r.len();
            for i in 0..n {
                let (x0, y0) = (f64::from(r[i].0), f64::from(r[i].1));
                let (x1, y1) = (f64::from(r[(i + 1) % n].0), f64::from(r[(i + 1) % n].1));
                let s0 = x0 * nx + y0 * ny;
                let s1 = x1 * nx + y1 * ny;
                if (s0 <= t && t < s1) || (s1 <= t && t < s0) {
                    let u0 = x0 * dx + y0 * dy;
                    let u1 = x1 * dx + y1 * dy;
                    us.push(u0 + (t - s0) / (s1 - s0) * (u1 - u0));
                }
            }
        }
        us.sort_by(|a, b| a.total_cmp(b));
        for pair in us.chunks_exact(2) {
            let (ua, ub) = (pair[0], pair[1]);
            pb.move_to((t * nx + ua * dx) as f32, (t * ny + ua * dy) as f32);
            pb.line_to((t * nx + ub * dx) as f32, (t * ny + ub * dy) as f32);
        }
    }
    pb.finish()
}

/// Roof data from `roof_shape.sql` for the current extent (empty when the tables don't exist).
pub struct RoofData {
    /// (rings in px, aspect bearing, member osm ids)
    pub facets: Vec<(Vec<Vec<(f32, f32)>>, f64, Vec<i64>)>,
    /// (polyline px, class: ridge | hip | parapet)
    pub lines: Vec<(Vec<(f32, f32)>, String)>,
    /// osm ids of buildings that belong to a sloped (hipped/gabled) roof mass in view
    pub sloped: std::collections::HashSet<i64>,
}

pub fn load_roofs(ctx: &mut Ctx) -> Result<RoofData> {
    let mut out = RoofData { facets: Vec::new(), lines: Vec::new(), sloped: std::collections::HashSet::new() };
    let exists: bool = ctx
        .client
        .query_one("SELECT to_regclass('public.roof_facet') IS NOT NULL AND to_regclass('public.roof_mass') IS NOT NULL", &[])
        .map(|r| r.get(0))
        .unwrap_or(false);
    if !exists {
        return Ok(out);
    }
    let facets = ctx.polygons(
        "mass_id::bigint AS id, kind AS class, ids AS sub, aspect_deg::float8 AS num",
        r#"(SELECT f.mass_id, f.kind, f.aspect_deg, f.geom, array_to_string(m.osm_ids, ',') AS ids
            FROM roof_facet f JOIN roof_mass m USING (mass_id)
            WHERE f.geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)) q"#,
        "ORDER BY mass_id",
    )?;
    for f in &facets {
        let ids: Vec<i64> = f.sub.split(',').filter_map(|s| s.parse().ok()).collect();
        if f.class == "hipped" || f.class == "gabled" {
            out.sloped.extend(ids.iter().copied());
        }
        out.facets.push((poly_rings_px(ctx, &f.geom), f.num, ids));
    }
    let lines = ctx.lines("mass_id::bigint AS id, class, '' AS sub, 0::float8 AS num", "roof_shape_line", "")?;
    for l in &lines {
        out.lines.push((line_pts(ctx, &l.geom), l.class.clone()));
    }
    Ok(out)
}
