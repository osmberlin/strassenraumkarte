//! Geometry decode + tiny-skia paint helpers.

use anyhow::Result;
use geo_types::{Coord, Geometry, LineString, MultiLineString, MultiPoint, MultiPolygon, Point, Polygon};
use tiny_skia::{
    BlendMode, Color, FillRule, FilterQuality, Paint, PathBuilder, Pattern, Pixmap, PixmapPaint,
    SpreadMode, Stroke, Transform,
};
use wkb::WKBReadExt;

use crate::profile::{StageSlot, StageTimers};
use crate::textures::Texture;
use crate::tile::{metres_per_px, metres_to_px, TileBounds, TILE_SIZE_PX};

/// Cheap QGIS-like exterior drop shadow (SE offset + box blur).
#[derive(Clone, Copy, Debug)]
pub struct DropShadow {
    /// Offset distance in map metres.
    pub offset_m: f64,
    /// QGIS offset angle in degrees (135 → SE with their convention).
    pub angle_deg: f64,
    /// Blur radius in map metres (approx stack/box blur).
    pub blur_m: f64,
    /// Shadow tint (RGB); alpha multiplied by `opacity`.
    pub color: Color,
    pub opacity: f32,
}

impl DropShadow {
    /// QGIS `building_parts_dissolved_height` dropShadow: blur 2 m, offset 1 m @ 40°, opacity 0.4.
    pub fn building() -> Self {
        let mut color = Color::from_rgba8(0x23, 0x23, 0x23, 255);
        color.set_alpha(1.0);
        Self {
            offset_m: 1.0,
            angle_deg: 40.0,
            blur_m: 2.0,
            color,
            opacity: 0.4,
        }
    }

    /// QGIS `building_shade` dropShadow: blur 1.6 m, offset 0.4 m @ 40°, opacity 0.138.
    pub fn building_shade() -> Self {
        let mut color = Color::from_rgba8(0x23, 0x23, 0x23, 255);
        color.set_alpha(1.0);
        Self {
            offset_m: 0.4,
            angle_deg: 40.0,
            blur_m: 1.6,
            color,
            opacity: 0.138,
        }
    }

    /// Tree crown dropShadow: blur 3 m, offset 0.4 m @ 45°, opacity 0.4.
    pub fn tree() -> Self {
        let mut color = Color::from_rgba8(0x23, 0x23, 0x23, 255);
        color.set_alpha(1.0);
        Self {
            offset_m: 0.4,
            angle_deg: 45.0,
            blur_m: 3.0,
            color,
            opacity: 0.4,
        }
    }

    /// Shrub crown shadow (QGIS blur 1.5 m).
    pub fn shrub() -> Self {
        let mut s = Self::tree();
        s.blur_m = 1.5;
        s
    }

    /// QGIS: `(-dist*cos(angle+π/2), -dist*sin(angle+π/2))` in painter space (y down).
    pub fn offset_px(&self, bounds: TileBounds) -> (f32, f32) {
        let dist = metres_to_px(self.offset_m, bounds);
        let angle = (self.angle_deg.to_radians() + std::f64::consts::FRAC_PI_2) as f32;
        let dx = -dist * angle.cos();
        let dy = -dist * angle.sin();
        (dx, dy)
    }
}

pub fn map_to_px(bounds: TileBounds, c: Coord<f64>) -> (f32, f32) {
    let w = bounds.maxx - bounds.minx;
    let h = bounds.maxy - bounds.miny;
    let px = ((c.x - bounds.minx) / w) * f64::from(TILE_SIZE_PX);
    // Screen Y grows downward; Web Mercator Y grows upward.
    let py = ((bounds.maxy - c.y) / h) * f64::from(TILE_SIZE_PX);
    (px as f32, py as f32)
}

fn ring_to_path(pb: &mut PathBuilder, bounds: TileBounds, ring: &LineString<f64>, close: bool) {
    let mut coords = ring.coords();
    if let Some(first) = coords.next() {
        let (x, y) = map_to_px(bounds, *first);
        pb.move_to(x, y);
        for c in coords {
            let (x, y) = map_to_px(bounds, *c);
            pb.line_to(x, y);
        }
        if close {
            pb.close();
        }
    }
}

pub fn polygon_to_path(bounds: TileBounds, poly: &Polygon<f64>) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    ring_to_path(&mut pb, bounds, poly.exterior(), true);
    for hole in poly.interiors() {
        ring_to_path(&mut pb, bounds, hole, true);
    }
    pb.finish()
}

pub fn linestring_to_path(bounds: TileBounds, line: &LineString<f64>) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    ring_to_path(&mut pb, bounds, line, false);
    pb.finish()
}

pub fn geometry_polygons(geom: Geometry<f64>) -> Vec<Polygon<f64>> {
    match geom {
        Geometry::Polygon(p) => vec![p],
        Geometry::MultiPolygon(MultiPolygon(ps)) => ps,
        Geometry::GeometryCollection(gc) => gc.0.into_iter().flat_map(geometry_polygons).collect(),
        _ => Vec::new(),
    }
}

pub fn geometry_lines(geom: Geometry<f64>) -> Vec<LineString<f64>> {
    match geom {
        Geometry::LineString(l) => vec![l],
        Geometry::MultiLineString(MultiLineString(ls)) => ls,
        Geometry::GeometryCollection(gc) => gc.0.into_iter().flat_map(geometry_lines).collect(),
        _ => Vec::new(),
    }
}

pub fn geometry_points(geom: Geometry<f64>) -> Vec<Point<f64>> {
    match geom {
        Geometry::Point(p) => vec![p],
        Geometry::MultiPoint(MultiPoint(ps)) => ps,
        Geometry::GeometryCollection(gc) => gc.0.into_iter().flat_map(geometry_points).collect(),
        _ => Vec::new(),
    }
}

pub fn decode_wkb(bytes: &[u8]) -> Result<Geometry<f64>> {
    let mut cursor = std::io::Cursor::new(bytes);
    cursor
        .read_wkb()
        .map_err(|e| anyhow::anyhow!("WKB decode failed: {e:?}"))
}

/// Solid fill + optional map-anchored RasterFill overlay (QGIS SimpleFill + RasterFill stack).
pub fn fill_polygons_textured(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    base: Color,
    texture: Option<(&Texture, f32)>,
) {
    fill_polygons(pixmap, bounds, geom.clone(), base);
    if let Some((tex, opacity)) = texture {
        fill_polygons_pattern(pixmap, bounds, geom, tex, opacity);
    }
}

/// Tile repeating texture clipped to polygons. Phase anchored to Web Mercator origin.
pub fn fill_polygons_pattern(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    texture: &Texture,
    opacity: f32,
) {
    if opacity <= 0.0 {
        return;
    }
    let mpp = metres_per_px(bounds);
    let pw = texture.pixmap.width() as f32;
    let ph = texture.pixmap.height() as f32;
    if pw < 1.0 || ph < 1.0 {
        return;
    }

    let (tile_w_px, tile_h_px) = if let Some(wm) = texture.width_m {
        let gw = metres_to_px(wm, bounds).max(1.0);
        let aspect = ph / pw;
        (gw, (gw * aspect).max(1.0))
    } else {
        (pw, ph)
    };

    // Map-anchored phase: aligns pattern across adjacent XYZ tiles (slippy-map safe).
    let phase_x = (bounds.minx / mpp).rem_euclid(f64::from(tile_w_px)) as f32;
    let phase_y = (bounds.maxy / mpp).rem_euclid(f64::from(tile_h_px)) as f32;

    let transform = Transform::from_row(
        tile_w_px / pw,
        0.0,
        0.0,
        -tile_h_px / ph,
        -phase_x,
        phase_y,
    );

    // Bicubic: QGIS Qt smooth sampling; Nearest made sett/asphalt look dithered.
    let shader = Pattern::new(
        texture.pixmap.as_ref(),
        SpreadMode::Repeat,
        FilterQuality::Bicubic,
        opacity,
        transform,
    );

    let mut paint = Paint::default();
    paint.shader = shader;
    paint.anti_alias = true;
    paint.blend_mode = BlendMode::SourceOver;

    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(bounds, &poly) else {
            continue;
        };
        pixmap.fill_path(
            &path,
            &paint,
            FillRule::EvenOdd,
            Transform::identity(),
            None,
        );
    }
}

/// QGIS ShapeburstFill v1: darken toward polygon boundary via mask − blur edge factor.
/// Kept for a later isolate; full-approx buildings use flat fill + dropShadow only.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug)]
pub struct ShapeburstFill {
    /// Inward falloff extent in map metres (~5 mm @ 1:1000 paper).
    pub band_m: f64,
    /// Edge tint colour (typically darker pink-brown).
    pub edge_color: Color,
    /// Peak edge-overlay strength (0..1).
    pub strength: f32,
}

#[allow(dead_code)]
impl ShapeburstFill {
    pub fn building() -> Self {
        let mut edge = Color::from_rgba8(0xa0, 0x70, 0x70, 255);
        edge.set_alpha(1.0);
        Self {
            band_m: 3.0,
            edge_color: edge,
            strength: 0.42,
        }
    }
}

/// Solid fill plus optional inner-edge darkening (shapeburst stand-in).
#[allow(dead_code)]
pub fn fill_polygons_shapeburst(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    base: Color,
    burst: ShapeburstFill,
) {
    for poly in geometry_polygons(geom) {
        fill_polygon_shapeburst(pixmap, bounds, &poly, base, burst);
    }
}

#[allow(dead_code)]
fn fill_polygon_shapeburst(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    poly: &Polygon<f64>,
    base: Color,
    burst: ShapeburstFill,
) {
    let Some(path) = polygon_to_path(bounds, poly) else {
        return;
    };

    let mut paint = Paint::default();
    paint.set_color(base);
    paint.anti_alias = true;
    pixmap.fill_path(
        &path,
        &paint,
        FillRule::EvenOdd,
        Transform::identity(),
        None,
    );

    let Some(mut mask) = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX) else {
        return;
    };
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    mask.fill_path(
        &path,
        &mask_paint,
        FillRule::EvenOdd,
        Transform::identity(),
        None,
    );

    let band_px = metres_to_px(burst.band_m, bounds).round().max(1.0) as u32;
    let mut blurred = mask.clone();
    box_blur_approx(&mut blurred, band_px);

    let edge_r = burst.edge_color.red();
    let edge_g = burst.edge_color.green();
    let edge_b = burst.edge_color.blue();
    let strength = burst.strength;

    let mask_data = mask.data();
    let blur_data = blurred.data();
    let px_data = pixmap.data_mut();
    let px_count = (TILE_SIZE_PX * TILE_SIZE_PX) as usize;

    for i in 0..px_count {
        let idx = i * 4;
        let ma = mask_data[idx + 3] as f32 / 255.0;
        if ma < 1.0 / 255.0 {
            continue;
        }
        let ba = blur_data[idx + 3] as f32 / 255.0;
        let edge = ((ma - ba) / ma).clamp(0.0, 1.0) * strength;
        if edge < 0.001 {
            continue;
        }

        let a = px_data[idx + 3] as f32 / 255.0;
        if a < 0.001 {
            continue;
        }
        let mut r = px_data[idx] as f32 / 255.0 / a;
        let mut g = px_data[idx + 1] as f32 / 255.0 / a;
        let mut b = px_data[idx + 2] as f32 / 255.0 / a;

        r = r * (1.0 - edge) + edge_r * edge;
        g = g * (1.0 - edge) + edge_g * edge;
        b = b * (1.0 - edge) + edge_b * edge;

        px_data[idx] = (r * a * 255.0).round() as u8;
        px_data[idx + 1] = (g * a * 255.0).round() as u8;
        px_data[idx + 2] = (b * a * 255.0).round() as u8;
    }
}

pub fn fill_polygons(pixmap: &mut Pixmap, bounds: TileBounds, geom: Geometry<f64>, color: Color) {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(bounds, &poly) else {
            continue;
        };
        pixmap.fill_path(
            &path,
            &paint,
            FillRule::EvenOdd,
            Transform::identity(),
            None,
        );
    }
}

/// Paint many polygons with one shared drop shadow (single blur pass).
pub fn fill_polygons_batch_with_shadow(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geoms: &[Geometry<f64>],
    fill: Color,
    shadow: DropShadow,
) {
    if geoms.is_empty() {
        return;
    }
    fill_polygons_shadow_only(pixmap, bounds, geoms, shadow);
    for geom in geoms {
        fill_polygons(pixmap, bounds, geom.clone(), fill);
    }
}

/// Drop-shadow only (QGIS `drawSource` disabled — e.g. `building_shade`).
pub fn fill_polygons_shadow_only(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geoms: &[Geometry<f64>],
    shadow: DropShadow,
) {
    if geoms.is_empty() {
        return;
    }
    let Some(mut mask) = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX) else {
        return;
    };
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            let Some(path) = polygon_to_path(bounds, &poly) else {
                continue;
            };
            mask.fill_path(
                &path,
                &mask_paint,
                FillRule::EvenOdd,
                Transform::identity(),
                None,
            );
        }
    }

    tint_pixmap_rgb(&mut mask, shadow.color, shadow.opacity);
    let blur_px = metres_to_px(shadow.blur_m, bounds).round().max(1.0) as u32;
    box_blur_approx(&mut mask, blur_px);

    let (dx, dy) = shadow.offset_px(bounds);
    let paint = PixmapPaint::default();
    pixmap.draw_pixmap(
        dx.round() as i32,
        dy.round() as i32,
        mask.as_ref(),
        &paint,
        Transform::identity(),
        None,
    );
}

/// Batch exterior shadow + per-polygon shapeburst fill (buildings).
#[allow(dead_code)]
pub fn fill_polygons_batch_with_shadow_shapeburst(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geoms: &[Geometry<f64>],
    fill: Color,
    shadow: DropShadow,
    burst: ShapeburstFill,
) {
    if geoms.is_empty() {
        return;
    }
    let Some(mut mask) = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX) else {
        for geom in geoms {
            fill_polygons_shapeburst(pixmap, bounds, geom.clone(), fill, burst);
        }
        return;
    };
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            let Some(path) = polygon_to_path(bounds, &poly) else {
                continue;
            };
            mask.fill_path(
                &path,
                &mask_paint,
                FillRule::EvenOdd,
                Transform::identity(),
                None,
            );
        }
    }

    tint_pixmap_rgb(&mut mask, shadow.color, shadow.opacity);
    let blur_px = metres_to_px(shadow.blur_m, bounds).round().max(1.0) as u32;
    box_blur_approx(&mut mask, blur_px);

    let (dx, dy) = shadow.offset_px(bounds);
    let paint = PixmapPaint::default();
    pixmap.draw_pixmap(
        dx.round() as i32,
        dy.round() as i32,
        mask.as_ref(),
        &paint,
        Transform::identity(),
        None,
    );

    for geom in geoms {
        fill_polygons_shapeburst(pixmap, bounds, geom.clone(), fill, burst);
    }
}

fn tint_pixmap_rgb(pixmap: &mut Pixmap, tint: Color, opacity: f32) {
    // tiny-skia Pixmap stores premultiplied RGBA.
    let tr = tint.red();
    let tg = tint.green();
    let tb = tint.blue();
    let data = pixmap.data_mut();
    for px in data.chunks_exact_mut(4) {
        let a = px[3] as f32 / 255.0;
        if a <= 0.0 {
            continue;
        }
        let out_a = (a * opacity).clamp(0.0, 1.0);
        px[0] = (tr * out_a * 255.0).round() as u8;
        px[1] = (tg * out_a * 255.0).round() as u8;
        px[2] = (tb * out_a * 255.0).round() as u8;
        px[3] = (out_a * 255.0).round() as u8;
    }
}

/// Separable box blur, applied 3× ≈ stack blur (cheap QGIS `stackBlur` stand-in).
fn box_blur_approx(pixmap: &mut Pixmap, radius: u32) {
    if radius == 0 {
        return;
    }
    let w = pixmap.width() as usize;
    let h = pixmap.height() as usize;
    let mut buf = pixmap.data().to_vec();
    let mut tmp = vec![0u8; buf.len()];
    for _ in 0..3 {
        box_blur_h(&buf, &mut tmp, w, h, radius);
        box_blur_v(&tmp, &mut buf, w, h, radius);
    }
    pixmap.data_mut().copy_from_slice(&buf);
}

fn box_blur_h(src: &[u8], dst: &mut [u8], w: usize, h: usize, radius: u32) {
    let r = radius as i32;
    let diam = 2 * r + 1;
    for y in 0..h {
        let row = y * w;
        for c in 0..4 {
            let mut sum: i32 = 0;
            for kx in -r..=r {
                let x = kx.clamp(0, w as i32 - 1) as usize;
                sum += i32::from(src[(row + x) * 4 + c]);
            }
            for x in 0..w {
                dst[(row + x) * 4 + c] = ((sum + diam / 2) / diam) as u8;
                let leave = (x as i32 - r).clamp(0, w as i32 - 1) as usize;
                let enter = (x as i32 + r + 1).clamp(0, w as i32 - 1) as usize;
                sum += i32::from(src[(row + enter) * 4 + c]);
                sum -= i32::from(src[(row + leave) * 4 + c]);
            }
        }
    }
}

fn box_blur_v(src: &[u8], dst: &mut [u8], w: usize, h: usize, radius: u32) {
    let r = radius as i32;
    let diam = 2 * r + 1;
    for x in 0..w {
        for c in 0..4 {
            let mut sum: i32 = 0;
            for ky in -r..=r {
                let y = ky.clamp(0, h as i32 - 1) as usize;
                sum += i32::from(src[(y * w + x) * 4 + c]);
            }
            for y in 0..h {
                dst[(y * w + x) * 4 + c] = ((sum + diam / 2) / diam) as u8;
                let leave = (y as i32 - r).clamp(0, h as i32 - 1) as usize;
                let enter = (y as i32 + r + 1).clamp(0, h as i32 - 1) as usize;
                sum += i32::from(src[(enter * w + x) * 4 + c]);
                sum -= i32::from(src[(leave * w + x) * 4 + c]);
            }
        }
    }
}

pub fn stroke_lines(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
) {
    let width_px = metres_to_px(width_m, bounds).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let stroke = Stroke {
        width: width_px,
        ..Stroke::default()
    };
    for line in geometry_lines(geom) {
        let Some(path) = linestring_to_path(bounds, &line) else {
            continue;
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
    }
}

pub fn fill_circles_m(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    color: Color,
    radius_m: f64,
) {
    let radius_px = metres_to_px(radius_m, bounds).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for pt in geometry_points(geom) {
        let (cx, cy) = map_to_px(bounds, Coord { x: pt.x(), y: pt.y() });
        let mut pb = PathBuilder::new();
        pb.push_circle(cx, cy, radius_px);
        let Some(path) = pb.finish() else {
            continue;
        };
        pixmap.fill_path(
            &path,
            &paint,
            FillRule::Winding,
            Transform::identity(),
            None,
        );
    }
}

/// RasterMarker tree crown: blurred under-shadow + Bicubic-scaled PNG stamp.
///
/// `diameter_map_m` is already in EPSG:3857 MapUnits (ground_m × `@mercator_scale`).
pub fn draw_tree_crown_marker(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    cx: f32,
    cy: f32,
    marker: &Pixmap,
    diameter_map_m: f64,
    rotation_deg: f32,
    shadow: DropShadow,
    opacity: f32,
) {
    let size_px = metres_to_px(diameter_map_m, bounds).max(1.0);
    let native_max = marker.width().max(marker.height()) as f32;
    let scale = size_px / native_max;
    let mw = marker.width() as f32;
    let mh = marker.height() as f32;
    let radius_px = size_px * 0.5;

    // Soft dropShadow: disk → tint → box blur → offset (closer to QGIS than a hard under-disk).
    if let Some(mut mask) = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX) {
        let (sdx, sdy) = shadow.offset_px(bounds);
        let mut pb = PathBuilder::new();
        pb.push_circle(cx + sdx, cy + sdy, radius_px * 1.05);
        if let Some(path) = pb.finish() {
            let mut paint = Paint::default();
            paint.set_color(Color::from_rgba8(255, 255, 255, 255));
            paint.anti_alias = true;
            mask.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
            tint_pixmap_rgb(&mut mask, shadow.color, shadow.opacity);
            let blur_px = metres_to_px(shadow.blur_m, bounds).round().max(1.0) as u32;
            box_blur_approx(&mut mask, blur_px);
            pixmap.draw_pixmap(
                0,
                0,
                mask.as_ref(),
                &PixmapPaint::default(),
                Transform::identity(),
                None,
            );
        }
    }

    let marker_transform = Transform::from_translate(cx, cy)
        .post_rotate(rotation_deg)
        .post_scale(scale, scale)
        .post_translate(-mw / 2.0, -mh / 2.0);

    let mut crown_paint = PixmapPaint::default();
    crown_paint.opacity = opacity.clamp(0.0, 1.0);
    crown_paint.quality = FilterQuality::Bicubic;
    pixmap.draw_pixmap(
        0,
        0,
        marker.as_ref(),
        &crown_paint,
        marker_transform,
        None,
    );
}

/// Soft tree crown fallback: dark under-disk + translucent main crown.
pub fn fill_tree_crown_soft(
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    geom: Geometry<f64>,
    crown: Color,
    radius_m: f64,
) {
    // Slightly larger, darker under-circle (cheap soft edge / under-shadow).
    let mut under = Color::from_rgba8(0x23, 0x23, 0x23, 255);
    under.set_alpha(0.18);
    fill_circles_m(pixmap, bounds, geom.clone(), under, radius_m * 1.12);

    let mut soft = crown;
    // QGIS crowns are soft; keep fill semi-transparent.
    if soft.alpha() > 0.7 {
        soft.set_alpha(0.62);
    }
    fill_circles_m(pixmap, bounds, geom, soft, radius_m);
}

/// Envelope SQL fragment params $1..$4 (minx,miny,maxx,maxy).
pub fn envelope_sql() -> &'static str {
    "ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)"
}

pub fn clip_polygon_wkb_sql(geom_col: &str) -> String {
    let env = envelope_sql();
    format!(
        r#"ST_AsBinary(
            ST_CollectionExtract(
              ST_MakeValid(
                ST_ClipByBox2D({geom_col}, {env})
              ),
              3
            )
          )"#
    )
}

pub fn clip_line_wkb_sql(geom_col: &str) -> String {
    let env = envelope_sql();
    format!(
        r#"ST_AsBinary(
            ST_CollectionExtract(
              ST_MakeValid(
                ST_ClipByBox2D({geom_col}, {env})
              ),
              2
            )
          )"#
    )
}

pub fn clip_point_wkb_sql(geom_col: &str) -> String {
    let env = envelope_sql();
    // Points: keep those inside the envelope (ClipByBox2D works for points too).
    format!(
        r#"ST_AsBinary(
            ST_CollectionExtract(
              ST_ClipByBox2D({geom_col}, {env}),
              1
            )
          )"#
    )
}
