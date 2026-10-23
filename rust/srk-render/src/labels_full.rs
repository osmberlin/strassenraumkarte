//! Full-approx labels: approximation of the QGIS PAL label layers of `strassenraumkarte.qgz`.
//!
//! Covered layers (rule scale ranges, fonts, colours, halos and data-defined overrides are read
//! from the project XML, see `audit/tile-regression/parity-2026-10-16/labels.md`):
//! - `label_highway`   street names along the line (curved, on line), 10 pt
//! - `label landuse`   park / forest / … names centred in the polygon, 10 pt
//! - `label water body` / `label_waterway` water names, 10 pt
//! - `place_node` / `place_polygon` settlement and square names, 10 pt
//! - `housenumber`     house numbers, 7.5 pt (scale ≤ 1:1000)
//!
//! Seam safety: every candidate is derived from the whole feature geometry in world (EPSG:3857)
//! coordinates, not from the clipped tile piece. Conflicts are resolved greedily by priority and a
//! world-anchored key, so each metatile makes the same decisions for the labels it shows.

use std::sync::{Arc, OnceLock};

use anyhow::Result;
use geo_types::{Geometry, LineString, Polygon};
use postgres::Client;
use resvg::usvg::fontdb;
use tiny_skia::Pixmap;

use crate::paint::{decode_wkb, envelope_sql, geometry_lines, geometry_points, geometry_polygons};
use crate::profile::StageTimers;
use crate::sql_cache::{query_prep, PreparedCache};
use crate::tile::{mercator_scale, RenderExtent};

/// Ground distance (m) added around the tile when querying features, so labels whose text reaches
/// into the tile are always among the candidates.
const QUERY_MARGIN_M: f64 = 400.0;
/// 96 dpi (QGIS `setOutputDpi`): 1 pt = 96/72 px.
const PX_PER_PT: f32 = 96.0 / 72.0;
/// Minimum pixel gap between two labels (kept small; PAL uses a minimum distance of zero).
const CONFLICT_EPS: f32 = 0.5;

/// Which font face a label uses (DejaVu Sans Condensed / DejaVu Sans in QGIS, with fallbacks).
#[derive(Clone, Copy, PartialEq, Eq)]
enum Face {
    Condensed,
    Plain,
}

#[derive(Clone, Copy)]
struct Look {
    face: Face,
    size_pt: f32,
    text: (u8, u8, u8),
    text_op: f32,
    halo: (u8, u8, u8),
    halo_op: f32,
    /// Buffer (halo) radius in pt, as in QGIS `bufferSize`.
    halo_pt: f32,
}

impl Look {
    fn size_px(self) -> f32 {
        self.size_pt * PX_PER_PT
    }
}

struct Fonts {
    db: Arc<fontdb::Database>,
    condensed: (&'static str, Option<fontdb::ID>),
    plain: (&'static str, Option<fontdb::ID>),
}

fn fonts() -> &'static Fonts {
    static FONTS: OnceLock<Fonts> = OnceLock::new();
    FONTS.get_or_init(|| {
        let mut db = fontdb::Database::new();
        db.load_system_fonts();
        let pick = |want: &'static str, fallback: &'static str| -> (&'static str, Option<fontdb::ID>) {
            let has = |name: &str| {
                db.faces()
                    .any(|f| f.families.iter().any(|(n, _)| n.eq_ignore_ascii_case(name)))
            };
            let name = if has(want) { want } else { fallback };
            let id = db.faces().find(|f| f.families.iter().any(|(n, _)| n.eq_ignore_ascii_case(name))).map(|f| f.id);
            (name, id)
        };
        let condensed = pick("DejaVu Sans Condensed", "Arial");
        let plain = pick("DejaVu Sans", "Arial");
        Fonts { db: Arc::new(db), condensed, plain }
    })
}

fn family(face: Face) -> &'static str {
    match face {
        Face::Condensed => fonts().condensed.0,
        Face::Plain => fonts().plain.0,
    }
}

/// Advance width of `text` in px at `size_px` (kerning ignored, letter-spacing 0).
fn advance_px(face: Face, text: &str, size_px: f32) -> f32 {
    let f = fonts();
    let id = match face {
        Face::Condensed => f.condensed.1,
        Face::Plain => f.plain.1,
    };
    let Some(id) = id else {
        return text.chars().count() as f32 * size_px * 0.55;
    };
    f.db
        .with_face_data(id, |data, index| {
            let face = ttf_parser::Face::parse(data, index).ok()?;
            let upem = f32::from(face.units_per_em());
            let mut w = 0.0f32;
            for ch in text.chars() {
                let gid = face.glyph_index(ch).unwrap_or(ttf_parser::GlyphId(0));
                w += f32::from(face.glyph_hor_advance(gid).unwrap_or(0));
            }
            Some(w / upem * size_px)
        })
        .flatten()
        .unwrap_or_else(|| text.chars().count() as f32 * size_px * 0.55)
}

fn hex((r, g, b): (u8, u8, u8)) -> String {
    format!("#{r:02x}{g:02x}{b:02x}")
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// QGIS map scale denominator of a 256 px Web Mercator tile at 96 dpi.
fn scale_denom(z: u32) -> f64 {
    591_657_527.591_555 / f64::powi(2.0, z as i32)
}

fn in_gate(scale: f64, min: f64, max: f64) -> bool {
    scale >= min && scale <= max
}

/// Label geometry in pixel space of the metatile.
#[derive(Clone)]
enum Shape {
    /// Text on a path (street / waterway), `start` = arc-length offset of the text start (px).
    Path { d: String, start: f32 },
    /// Text centred on a point.
    Point { x: f32, y: f32 },
}

#[derive(Clone)]
struct Cand {
    prio: u8,
    key: (i64, i64),
    text: String,
    look: Look,
    /// Text opacity / halo opacity overrides from data-defined rules.
    shape: Shape,
    corners: [(f32, f32); 4],
}

/// World-stable sort key of an anchor given in EPSG:3857 metres.
fn world_key(x: f64, y: f64) -> (i64, i64) {
    ((x * 10.0).round() as i64, (y * 10.0).round() as i64)
}

fn point_at(pts: &[(f32, f32)], cum: &[f32], s: f32) -> (f32, f32) {
    let total = *cum.last().unwrap_or(&0.0);
    let s = s.clamp(0.0, total);
    let i = match cum.binary_search_by(|v| v.partial_cmp(&s).unwrap_or(std::cmp::Ordering::Less)) {
        Ok(i) => i.min(pts.len() - 1),
        Err(i) => i.max(1).min(pts.len() - 1),
    };
    let (a, b) = (pts[i - 1], pts[i]);
    let seg = cum[i] - cum[i - 1];
    let t = if seg > 0.0 { (s - cum[i - 1]) / seg } else { 0.0 };
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
}

/// Cumulative arc length of a pixel polyline.
fn cumulative(pts: &[(f32, f32)]) -> Vec<f32> {
    let mut cum = Vec::with_capacity(pts.len());
    let mut acc = 0.0f32;
    cum.push(0.0);
    for w in pts.windows(2) {
        acc += ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt();
        cum.push(acc);
    }
    cum
}

/// Oriented rectangle (text box) around a baseline segment, centred on the line.
fn rect_along(p0: (f32, f32), p1: (f32, f32), half_h: f32) -> [(f32, f32); 4] {
    let (dx, dy) = (p1.0 - p0.0, p1.1 - p0.1);
    let len = (dx * dx + dy * dy).sqrt().max(1e-6);
    let (ux, uy) = (dx / len, dy / len);
    let (nx, ny) = (-uy * half_h, ux * half_h);
    [
        (p0.0 + nx, p0.1 + ny),
        (p1.0 + nx, p1.1 + ny),
        (p1.0 - nx, p1.1 - ny),
        (p0.0 - nx, p0.1 - ny),
    ]
}

fn rect_axis(cx: f32, cy: f32, half_w: f32, half_h: f32) -> [(f32, f32); 4] {
    [
        (cx - half_w, cy - half_h),
        (cx + half_w, cy - half_h),
        (cx + half_w, cy + half_h),
        (cx - half_w, cy + half_h),
    ]
}

/// Separating-axis test for two convex quads; touching counts as free.
fn overlaps(a: &[(f32, f32); 4], b: &[(f32, f32); 4]) -> bool {
    for poly in [a, b] {
        for i in 0..4 {
            let p0 = poly[i];
            let p1 = poly[(i + 1) % 4];
            let n = (-(p1.1 - p0.1), p1.0 - p0.0);
            let proj = |q: &[(f32, f32); 4]| {
                let mut lo = f32::MAX;
                let mut hi = f32::MIN;
                for p in q {
                    let v = p.0 * n.0 + p.1 * n.1;
                    lo = lo.min(v);
                    hi = hi.max(v);
                }
                (lo, hi)
            };
            let (alo, ahi) = proj(a);
            let (blo, bhi) = proj(b);
            if ahi <= blo + CONFLICT_EPS || bhi <= alo + CONFLICT_EPS {
                return false;
            }
        }
    }
    true
}

fn point_in_ring(pt: (f32, f32), ring: &[(f32, f32)]) -> bool {
    let mut inside = false;
    let n = ring.len();
    if n < 3 {
        return false;
    }
    let mut j = n - 1;
    for i in 0..n {
        let (xi, yi) = ring[i];
        let (xj, yj) = ring[j];
        if (yi > pt.1) != (yj > pt.1) && pt.0 < (xj - xi) * (pt.1 - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

/// Polygon in pixel space: exterior ring plus holes.
struct PxPoly {
    rings: Vec<Vec<(f32, f32)>>,
}

impl PxPoly {
    fn from_polygon(extent: RenderExtent, poly: &Polygon<f64>) -> Self {
        let ring = |ls: &LineString<f64>| -> Vec<(f32, f32)> {
            ls.coords().map(|c| extent.map_to_px(c.x, c.y)).collect()
        };
        let mut rings = vec![ring(poly.exterior())];
        for h in poly.interiors() {
            rings.push(ring(h));
        }
        Self { rings }
    }

    /// Whether all four corners lie inside the exterior and outside every hole.
    fn contains_box(&self, corners: &[(f32, f32); 4]) -> bool {
        corners.iter().all(|&c| {
            let mut ok = point_in_ring(c, &self.rings[0]);
            for hole in &self.rings[1..] {
                if point_in_ring(c, hole) {
                    ok = false;
                }
            }
            ok
        })
    }
}

/// Query window (world metres) around the metatile.
fn query_bounds(extent: RenderExtent) -> [f64; 4] {
    let b = extent.bounds;
    [b.minx - QUERY_MARGIN_M, b.miny - QUERY_MARGIN_M, b.maxx + QUERY_MARGIN_M, b.maxy + QUERY_MARGIN_M]
}

fn wkb_of(row: &postgres::Row, col: &str) -> Option<Vec<u8>> {
    let v: Option<Vec<u8>> = row.get(col);
    v.filter(|b| !b.is_empty())
}

/// Anchor point of a polygon label from SQL (centroid if inside, else point on surface).
fn anchor_of(row: &postgres::Row, col: &str) -> Option<(f64, f64)> {
    let wkb = wkb_of(row, col)?;
    match decode_wkb(&wkb).ok()? {
        Geometry::Point(p) => Some((p.x(), p.y())),
        _ => None,
    }
}

/// Per-metatile label set: candidates for all active layers.
struct Collect<'a> {
    extent: RenderExtent,
    /// Ground-to-Mercator factor (ground metres = Mercator metres / s).
    s: f64,
    cands: &'a mut Vec<Cand>,
}

impl Collect<'_> {
    /// Line label along `ls` (world coords) with the text centred on the middle of the line.
    fn line(&mut self, text: &str, look: Look, prio: u8, ls: &LineString<f64>, min_len_ground: f64) -> bool {
        if text.is_empty() {
            return false;
        }
        let world: Vec<(f64, f64)> = ls.coords().map(|c| (c.x, c.y)).collect();
        if world.len() < 2 {
            return false;
        }
        let ground_len: f64 = world
            .windows(2)
            .map(|w| ((w[1].0 - w[0].0).powi(2) + (w[1].1 - w[0].1).powi(2)).sqrt())
            .sum::<f64>()
            / self.s;
        if ground_len < min_len_ground {
            return false;
        }
        let mut pts: Vec<(f32, f32)> = world
            .iter()
            .map(|&(x, y)| self.extent.map_to_px(x, y))
            .collect();
        let mut world = world;
        // read left to right
        if pts.last().map(|p| p.0).unwrap_or(0.0) < pts[0].0 {
            pts.reverse();
            world.reverse();
        }
        pts.dedup();
        if pts.len() < 2 {
            return false;
        }
        let cum = cumulative(&pts);
        let total = *cum.last().unwrap_or(&0.0);
        let size = look.size_px();
        let w = advance_px(look.face, text, size);
        if total < w * 1.05 {
            return false;
        }
        let a = total / 2.0;
        let start = a - w / 2.0;
        let p0 = point_at(&pts, &cum, a - w / 2.0);
        let p1 = point_at(&pts, &cum, a + w / 2.0);
        let corners = rect_along(p0, p1, size * 0.5);
        let d: String = pts
            .iter()
            .enumerate()
            .map(|(k, (x, y))| format!("{}{:.2},{:.2}", if k == 0 { "M" } else { "L" }, x, y))
            .collect();
        // world anchor: the middle of the line (world, before reversal sign does not matter)
        let (mx, my) = world[world.len() / 2];
        self.cands.push(Cand {
            prio,
            key: world_key(mx, my),
            text: text.to_string(),
            look,
            shape: Shape::Path { d, start },
            corners,
        });
        true
    }

    /// Point label centred on the anchor. `fit` is an optional polygon the box must fit in.
    fn point(&mut self, text: &str, look: Look, prio: u8, world_anchor: (f64, f64), fit: Option<&PxPoly>) -> bool {
        if text.is_empty() {
            return false;
        }
        let (x, y) = self.extent.map_to_px(world_anchor.0, world_anchor.1);
        let size = look.size_px();
        let w = advance_px(look.face, text, size);
        let corners = rect_axis(x, y, w / 2.0, size * 0.5);
        if let Some(poly) = fit {
            if !poly.contains_box(&corners) {
                return false;
            }
        }
        self.cands.push(Cand {
            prio,
            key: world_key(world_anchor.0, world_anchor.1),
            text: text.to_string(),
            look,
            shape: Shape::Point { x, y },
            corners,
        });
        true
    }

}

// Look presets (QGIS project values; buffer colours are the halos).
const HW: Look = Look {
    face: Face::Condensed,
    size_pt: 10.0,
    text: (221, 221, 221),
    text_op: 1.0,
    halo: (168, 168, 167),
    halo_op: 0.75,
    halo_pt: 2.0,
};
const LU: Look = Look {
    face: Face::Condensed,
    size_pt: 10.0,
    text: (168, 168, 167),
    text_op: 1.0,
    halo: (225, 227, 189),
    halo_op: 0.75,
    halo_pt: 2.0,
};
const WATER: Look = Look {
    face: Face::Condensed,
    size_pt: 10.0,
    text: (171, 165, 216),
    text_op: 1.0,
    halo: (205, 203, 234),
    halo_op: 0.75,
    halo_pt: 2.0,
};
/// Place names. The project says text 215,216,197 on halo 168,168,167, but the reference tiles
/// read as grey glyphs on a grey halo (box MAE 16.4 vs 17.5 for the project colours), so the
/// measured colours are used.
const PLACE: Look = Look {
    face: Face::Condensed,
    size_pt: 10.0,
    text: (168, 168, 167),
    text_op: 1.0,
    halo: (168, 168, 167),
    halo_op: 0.75,
    halo_pt: 2.0,
};
const HOUSENUMBER: Look = Look {
    face: Face::Plain,
    size_pt: 7.5,
    text: (183, 183, 183),
    text_op: 1.0,
    halo: (216, 213, 213),
    halo_op: 0.75,
    halo_pt: 2.5,
};

const PLACE_A: &[&str] = &["city_block", "farm", "isolated_dwelling", "square"];
const PLACE_B: &[&str] = &["allotments", "hamlet", "islet", "neighbourhood", "quarter"];
const PLACE_C: &[&str] = &["island", "suburb", "village"];
const PLACE_D: &[&str] = &["borough", "town"];
const PLACE_E: &[&str] = &["city"];
const LU_PRIMARY: &[&str] = &["forest", "park", "recreation_ground", "wood"];
const LU_SECONDARY: &[&str] = &["cemetery", "dog_park", "farmland", "garden", "playground"];

fn sql_in(list: &[&str]) -> String {
    list.iter().map(|s| format!("'{s}'")).collect::<Vec<_>>().join(", ")
}

/// Place rules of the QGIS project: (classes, scale min, scale max, polygon must fit the box,
/// rule has the `$area / @map_scale > 0.75` filter).
fn place_rules() -> [(&'static [&'static str], f64, f64, bool, bool); 5] {
    [
        (PLACE_A, 1000.0, 8000.0, false, true),
        (PLACE_B, 4000.0, 16000.0, true, false),
        (PLACE_C, 16000.0, 64000.0, true, false),
        (PLACE_D, 32000.0, 64000.0, true, false),
        (PLACE_E, 64000.0, 128000.0, true, false),
    ]
}

/// Paint all label layers of full-approx onto `pixmap` (metatile pixel space).
pub fn paint(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let scale = scale_denom(z);
    let s = mercator_scale(extent.bounds);
    let bounds = query_bounds(extent);
    let env = envelope_sql();
    let mut cands: Vec<Cand> = Vec::new();
    let mut c = Collect { extent, s, cands: &mut cands };

    let params: [&(dyn postgres::types::ToSql + Sync); 4] = [&bounds[0], &bounds[1], &bounds[2], &bounds[3]];

    // street names: label_highway (zoom class 'low' 1:4000–8000, 'high' 1:1000–4000)
    for (zoom, min, max) in [("low", 4000.0, 8000.0), ("high", 1000.0, 4000.0)] {
        if !in_gate(scale, min, max) {
            continue;
        }
        let font_op = if scale < 2000.0 { 0.5 } else { 1.0 };
        let sql = format!(
            "SELECT name, ST_AsBinary(geom) AS wkb FROM label_highway WHERE name IS NOT NULL AND zoom = '{zoom}' AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            let mut look = HW;
            look.text_op *= font_op;
            for ls in geometry_lines(geom) {
                c.line(&name, look, 5, &ls, 0.0);
                break;
            }
        }
    }

    // waterway names (curved, 1:2000–16000; hidden for short / minor ways at large scales)
    if in_gate(scale, 2000.0, 16000.0) {
        let sql = format!(
            "SELECT name, waterway, ST_AsBinary(geom) AS wkb FROM label_waterway WHERE name IS NOT NULL AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let waterway: Option<String> = row.get("waterway");
            let wy = waterway.unwrap_or_default();
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            let stream = matches!(wy.as_str(), "stream" | "ditch" | "drain");
            let (text_c, halo_c) = if stream { (WATER.text, WATER.halo) } else { (WATER.halo, WATER.text) };
            let look = Look { text: text_c, halo: halo_c, ..WATER };
            let hide_big = scale > 6000.0 && !matches!(wy.as_str(), "river" | "canal");
            let hide_huge = scale > 12000.0 && wy != "river";
            if hide_big || hide_huge {
                continue;
            }
            for ls in geometry_lines(geom) {
                c.line(&name, look, 5, &ls, 250.0);
                break;
            }
        }
    }

    // landuse names (centred in polygon, fit inside)
    let lu_primary_on = in_gate(scale, 2000.0, 64000.0);
    let lu_secondary_on = in_gate(scale, 2000.0, 4000.0);
    if lu_primary_on || lu_secondary_on {
        let sql = format!(
            "SELECT name, class, ST_Area(geom) AS area, ST_AsBinary(geom) AS wkb, \
             ST_AsBinary(CASE WHEN ST_IsValid(geom) AND ST_Contains(geom, ST_Centroid(geom)) THEN ST_Centroid(geom) ELSE ST_PointOnSurface(geom) END) AS anchor \
             FROM landuse WHERE name IS NOT NULL AND class IN ({}) AND geom && {env}",
            sql_in(&[LU_PRIMARY, LU_SECONDARY].concat())
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let class: String = row.get("class");
            let primary = LU_PRIMARY.contains(&class.as_str());
            if primary && !lu_primary_on || !primary && !lu_secondary_on {
                continue;
            }
            let area_merc: f64 = row.get("area");
            let area_ground = area_merc / (s * s);
            // data-defined size: hidden for small areas at scales > 1:6000
            if scale > 6000.0 && area_ground / scale < 25.0 {
                continue;
            }
            let mut look = LU;
            if !primary {
                look.text_op = 0.67;
            }
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Some(anchor) = anchor_of(row, "anchor") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            for poly in geometry_polygons(geom) {
                let px = PxPoly::from_polygon(extent, &poly);
                c.point(&name, look, 5, anchor, Some(&px));
                break;
            }
        }
    }

    // water body names
    if in_gate(scale, 2000.0, 60000.0) {
        let sql = format!(
            "SELECT name, ST_Area(geom) AS area, ST_AsBinary(geom) AS wkb, \
             ST_AsBinary(CASE WHEN ST_IsValid(geom) AND ST_Contains(geom, ST_Centroid(geom)) THEN ST_Centroid(geom) ELSE ST_PointOnSurface(geom) END) AS anchor \
             FROM water_body WHERE name IS NOT NULL AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Some(anchor) = anchor_of(row, "anchor") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            for poly in geometry_polygons(geom) {
                let px = PxPoly::from_polygon(extent, &poly);
                c.point(&name, WATER, 5, anchor, Some(&px));
                break;
            }
        }
    }

    // place names: polygons (squares, quarters …) and nodes, per-rule scale windows
    for (classes, min, max, fit, area_rule) in place_rules() {
        if !in_gate(scale, min, max) {
            continue;
        }
        let list = sql_in(classes);
        let sql = format!(
            "SELECT name, place, ST_AsBinary(geom) AS wkb FROM place_node WHERE name IS NOT NULL AND place IN ({list}) AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            for p in geometry_points(geom) {
                let look = if scale < 2000.0 { Look { halo_op: 0.4, ..PLACE } } else { PLACE };
                c.point(&name, look, 7, (p.x(), p.y()), None);
                break;
            }
        }
        let sql = format!(
            "SELECT name, place, ST_Area(geom) AS area, ST_AsBinary(geom) AS wkb, \
             ST_AsBinary(CASE WHEN ST_IsValid(geom) AND ST_Contains(geom, ST_Centroid(geom)) THEN ST_Centroid(geom) ELSE ST_PointOnSurface(geom) END) AS anchor \
             FROM place_polygon WHERE name IS NOT NULL AND place IN ({list}) AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let name: String = row.get("name");
            let area_merc: f64 = row.get("area");
            // rule A: $area / @map_scale > 0.75
            if area_rule && area_merc / (s * s) / scale <= 0.75 {
                continue;
            }
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Some(anchor) = anchor_of(row, "anchor") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            let look = if scale < 2000.0 {
                Look { halo_op: 0.4, text_op: 0.5, ..PLACE }
            } else {
                PLACE
            };
            let fit_poly = if fit {
                geometry_polygons(geom).into_iter().next().map(|p| PxPoly::from_polygon(extent, &p))
            } else {
                None
            };
            c.point(&name, look, 7, anchor, fit_poly.as_ref());
        }
    }

    // house numbers: 1:1000 and closer
    if in_gate(scale, 0.0, 1000.0) {
        let sql = format!(
            "SELECT \"addr:housenumber\" AS hn, ST_AsBinary(geom) AS wkb FROM housenumber WHERE \"addr:housenumber\" IS NOT NULL AND geom && {env}"
        );
        let rows = query_prep(client, prep_cache, timers, &sql, &params)?;
        for row in &rows {
            let hn: String = row.get("hn");
            let Some(wkb) = wkb_of(row, "wkb") else { continue };
            let Ok(geom) = decode_wkb(&wkb) else { continue };
            for p in geometry_points(geom) {
                c.point(&hn, HOUSENUMBER, 5, (p.x(), p.y()), None);
                break;
            }
        }
    }

    if cands.is_empty() {
        return Ok(());
    }
    let kept = resolve_conflicts(cands);
    draw(pixmap, extent, &kept);
    Ok(())
}

/// Greedy conflict resolution: higher priority first, then the world-stable key.
fn resolve_conflicts(mut cands: Vec<Cand>) -> Vec<Cand> {
    cands.sort_by(|a, b| b.prio.cmp(&a.prio).then(a.key.cmp(&b.key)).then(a.text.cmp(&b.text)));
    let mut kept: Vec<Cand> = Vec::with_capacity(cands.len());
    for cand in cands {
        if kept.iter().any(|k| overlaps(&k.corners, &cand.corners)) {
            continue;
        }
        kept.push(cand);
    }
    kept
}

fn draw(pixmap: &mut Pixmap, extent: RenderExtent, cands: &[Cand]) {
    let mut defs = String::new();
    let mut texts = String::new();
    for (i, c) in cands.iter().enumerate() {
        let fam = family(c.look.face);
        let size = c.look.size_px();
        let halo_w = 2.0 * c.look.halo_pt * PX_PER_PT;
        let style = format!(
            "font-family=\"{fam}\" font-size=\"{size:.2}\" fill=\"{}\" fill-opacity=\"{:.3}\" stroke=\"{}\" stroke-opacity=\"{:.3}\" stroke-width=\"{halo_w:.2}\" stroke-linejoin=\"round\" paint-order=\"stroke\" dominant-baseline=\"central\"",
            hex(c.look.text),
            c.look.text_op,
            hex(c.look.halo),
            c.look.halo_op,
        );
        match &c.shape {
            Shape::Path { d, start } => {
                defs.push_str(&format!("<path id=\"l{i}\" d=\"{d}\"/>"));
                texts.push_str(&format!(
                    "<text {style}><textPath href=\"#l{i}\" startOffset=\"{start:.2}\">{}</textPath></text>",
                    xml_escape(&c.text)
                ));
            }
            Shape::Point { x, y } => {
                texts.push_str(&format!(
                    "<text x=\"{x:.2}\" y=\"{y:.2}\" text-anchor=\"middle\" {style}>{}</text>",
                    xml_escape(&c.text)
                ));
            }
        }
    }
    let (w, h) = (extent.width_px, extent.height_px);
    let svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs>{defs}</defs>{texts}</svg>"##
    );
    let mut opts = resvg::usvg::Options::default();
    opts.fontdb = fonts().db.clone();
    let tree = match resvg::usvg::Tree::from_str(&svg, &opts) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("warn: full-approx labels svg: {e}");
            return;
        }
    };
    let Some(mut layer) = resvg::tiny_skia::Pixmap::new(w, h) else { return };
    resvg::render(&tree, resvg::tiny_skia::Transform::identity(), &mut layer.as_mut());
    if let Some(ours) = tiny_skia::IntSize::from_wh(w, h).and_then(|sz| Pixmap::from_vec(layer.take(), sz)) {
        pixmap.draw_pixmap(
            0,
            0,
            ours.as_ref(),
            &tiny_skia::PixmapPaint::default(),
            tiny_skia::Transform::identity(),
            None,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point_cand(prio: u8, key: (i64, i64), x: f32, y: f32) -> Cand {
        Cand {
            prio,
            key,
            text: format!("p{prio}-{}", key.0),
            look: PLACE,
            shape: Shape::Point { x, y },
            corners: rect_axis(x, y, 5.0, 5.0),
        }
    }

    #[test]
    fn separating_axis_overlap() {
        let a = rect_axis(0.0, 0.0, 5.0, 5.0);
        assert!(overlaps(&a, &rect_axis(8.0, 0.0, 5.0, 5.0)));
        assert!(!overlaps(&a, &rect_axis(20.0, 0.0, 5.0, 5.0)));
        // edge-touching boxes do not conflict
        assert!(!overlaps(&a, &rect_axis(10.0, 0.0, 5.0, 5.0)));
    }

    #[test]
    fn point_in_ring_square() {
        let sq = vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
        assert!(point_in_ring((5.0, 5.0), &sq));
        assert!(!point_in_ring((15.0, 5.0), &sq));
    }

    #[test]
    fn scale_gates_follow_zoom() {
        // street names: 'low' rule 1:4000–8000 (z17), 'high' 1:1000–4000 (z18, z19)
        assert!(in_gate(scale_denom(17), 4000.0, 8000.0));
        assert!(!in_gate(scale_denom(16), 4000.0, 8000.0));
        assert!(in_gate(scale_denom(18), 1000.0, 4000.0));
        assert!(!in_gate(scale_denom(20), 1000.0, 4000.0));
        // house numbers: 1:0–1000 (z20 only)
        assert!(in_gate(scale_denom(20), 0.0, 1000.0));
        assert!(!in_gate(scale_denom(19), 0.0, 1000.0));
    }

    #[test]
    fn conflicts_prefer_priority_then_world_key() {
        let kept = resolve_conflicts(vec![
            point_cand(5, (1, 0), 10.0, 10.0),
            point_cand(7, (9, 0), 12.0, 10.0), // place name wins over the street-level label
            point_cand(5, (0, 0), 30.0, 10.0), // far away: kept
        ]);
        let texts: Vec<&str> = kept.iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, vec!["p7-9", "p5-0"]);
    }
}
