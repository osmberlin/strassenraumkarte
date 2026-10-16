//! Geometry decode + tiny-skia paint helpers.

use anyhow::Result;
use geo_types::{Coord, Geometry, LineString, MultiLineString, MultiPoint, MultiPolygon, Point, Polygon};
use tiny_skia::{
    BlendMode, Color, FillRule, FilterQuality, Paint, PathBuilder, Pattern, Pixmap, PixmapPaint,
    SpreadMode, Stroke, StrokeDash, Transform,
};
use wkb::WKBReadExt;

use crate::profile::{StageSlot, StageTimers};
use crate::textures::Texture;
use crate::tile::{mercator_scale, RenderExtent};
use crate::tree_markers::TreeMarkerCatalog;

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

    /// Tree and shrub crown layer effect (`tree crown (> z17)` symbol-layer dropShadow):
    /// blur 2.5 m, offset 0.7 m @ -45°, black, opacity 1. Only drawn at scale < 1:2000.
    pub fn tree_crown() -> Self {
        Self {
            offset_m: 0.7,
            angle_deg: -45.0,
            blur_m: 2.5,
            color: Color::from_rgba8(0, 0, 0, 255),
            opacity: 1.0,
        }
    }

    /// `street parking (> z17)` layer effect: blur 0.8 m, offset 0.5 m @ 40°,
    /// colour #232323, opacity 0.5. Only drawn at scale < 1:2000.
    pub fn parked_car() -> Self {
        let mut color = Color::from_rgba8(0x23, 0x23, 0x23, 255);
        color.set_alpha(1.0);
        Self {
            offset_m: 0.5,
            angle_deg: 40.0,
            blur_m: 0.8,
            color,
            opacity: 0.5,
        }
    }

    /// QGIS: `(-dist*cos(angle+π/2), -dist*sin(angle+π/2))` in painter space (y down).
    pub fn offset_px(&self, extent: RenderExtent) -> (f32, f32) {
        let dist = extent.metres_to_px(self.offset_m);
        let angle = (self.angle_deg.to_radians() + std::f64::consts::FRAC_PI_2) as f32;
        let dx = -dist * angle.cos();
        let dy = -dist * angle.sin();
        (dx, dy)
    }
}

pub fn map_to_px(extent: RenderExtent, c: Coord<f64>) -> (f32, f32) {
    extent.map_to_px(c.x, c.y)
}

fn ring_to_path(pb: &mut PathBuilder, extent: RenderExtent, ring: &LineString<f64>, close: bool) {
    let mut coords = ring.coords();
    if let Some(first) = coords.next() {
        let (x, y) = map_to_px(extent, *first);
        pb.move_to(x, y);
        for c in coords {
            let (x, y) = map_to_px(extent, *c);
            pb.line_to(x, y);
        }
        if close {
            pb.close();
        }
    }
}

pub fn polygon_to_path(extent: RenderExtent, poly: &Polygon<f64>) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    ring_to_path(&mut pb, extent, poly.exterior(), true);
    for hole in poly.interiors() {
        ring_to_path(&mut pb, extent, hole, true);
    }
    pb.finish()
}

pub fn linestring_to_path(extent: RenderExtent, line: &LineString<f64>) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    ring_to_path(&mut pb, extent, line, false);
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
    // `POLYGON EMPTY` / `MULTI* EMPTY` (byte order + type + zero count): a clip of a
    // feature whose bbox, but not its area, touches the tile. The wkb reader rejects it.
    if bytes.len() == 9 && bytes[5..9] == [0, 0, 0, 0] {
        return Ok(Geometry::GeometryCollection(geo_types::GeometryCollection(Vec::new())));
    }
    let mut cursor = std::io::Cursor::new(bytes);
    cursor
        .read_wkb()
        .map_err(|e| anyhow::anyhow!("WKB decode failed: {e:?}"))
}

/// Solid fill + optional map-anchored RasterFill overlay (QGIS SimpleFill + RasterFill stack).
pub fn fill_polygons_textured(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    base: Color,
    texture: Option<(&Texture, f32)>,
) {
    fill_polygons(pixmap, extent, geom.clone(), base);
    if let Some((tex, opacity)) = texture {
        fill_polygons_pattern(pixmap, extent, geom, tex, opacity);
    }
}

/// Tile repeating texture clipped to polygons. Phase anchored to Web Mercator origin.
pub fn fill_polygons_pattern(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    texture: &Texture,
    opacity: f32,
) {
    if opacity <= 0.0 {
        return;
    }
    let mpp = extent.metres_per_px();
    let pw = texture.pixmap.width() as f32;
    let ph = texture.pixmap.height() as f32;
    if pw < 1.0 || ph < 1.0 {
        return;
    }

    let (tile_w_px, tile_h_px) = if let Some(wm) = texture.width_m {
        let gw = extent.metres_to_px(wm).max(1.0);
        let aspect = ph / pw;
        (gw, (gw * aspect).max(1.0))
    } else {
        (pw, ph)
    };

    // Map-anchored phase: aligns pattern across adjacent XYZ tiles (slippy-map safe).
    let phase_x = (extent.bounds.minx / mpp).rem_euclid(f64::from(tile_w_px)) as f32;
    let phase_y = (extent.bounds.maxy / mpp).rem_euclid(f64::from(tile_h_px)) as f32;

    let transform = Transform::from_row(
        tile_w_px / pw,
        0.0,
        0.0,
        -tile_h_px / ph,
        -phase_x,
        phase_y,
    );

    // Bilinear: Bicubic rings on high-contrast asphalt/sett → dark "Blitzer" speckles
    // on polygon AA edges. QGIS Qt smooth is closer to bilinear at these scales.
    let shader = Pattern::new(
        texture.pixmap.as_ref(),
        SpreadMode::Repeat,
        FilterQuality::Bilinear,
        opacity,
        transform,
    );

    let mut paint = Paint::default();
    paint.shader = shader;
    // No AA on the texture pass: base fill already AA'd the edge; texturing the
    // AA fringe re-samples dark asphalt texels → "Blitzer" sparkles.
    paint.anti_alias = false;
    paint.blend_mode = BlendMode::SourceOver;

    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(extent, &poly) else {
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
pub fn fill_polygons_shapeburst(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    base: Color,
    burst: ShapeburstFill,
    timers: &mut Option<&mut StageTimers>,
) {
    for poly in geometry_polygons(geom) {
        fill_polygon_shapeburst(pixmap, extent, &poly, base, burst, timers);
    }
}

/// Batch shapeburst: one shared mask → one blur → edge darken, then base fills.
pub fn fill_polygons_batch_shapeburst(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    fill: Color,
    burst: ShapeburstFill,
    timers: &mut Option<&mut StageTimers>,
) {
    if geoms.is_empty() {
        return;
    }
    for geom in geoms {
        fill_polygons(pixmap, extent, geom.clone(), fill);
    }
    let band_px = extent.metres_to_px(burst.band_m).round().max(1.0) as u32;
    if band_px <= 1 {
        return;
    }
    crate::profile::time_stage(timers, StageSlot::Shapeburst, || {
        apply_batch_shapeburst_edge(pixmap, extent, geoms, burst, band_px);
    });
}

fn apply_batch_shapeburst_edge(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    burst: ShapeburstFill,
    band_px: u32,
) {
    let Some((x0, y0, rw, rh)) = union_polygon_px_bbox(extent, geoms, band_px) else {
        return;
    };
    if (rw as u64) * (rh as u64) < 16 {
        return;
    }

    let Some(mut mask) = Pixmap::new(rw, rh) else {
        return;
    };
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    let offset = Transform::from_translate(-(x0 as f32), -(y0 as f32));
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            let Some(path) = polygon_to_path(extent, &poly) else {
                continue;
            };
            mask.fill_path(
                &path,
                &mask_paint,
                FillRule::EvenOdd,
                offset,
                None,
            );
        }
    }

    let mut blurred = mask.clone();
    box_blur_approx(&mut blurred, band_px);
    apply_shapeburst_edge_region(pixmap, &mask, &blurred, burst, x0, y0, rw, rh);
}

fn fill_polygon_shapeburst(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    poly: &Polygon<f64>,
    base: Color,
    burst: ShapeburstFill,
    timers: &mut Option<&mut StageTimers>,
) {
    let Some(path) = polygon_to_path(extent, poly) else {
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

    let band_px = extent.metres_to_px(burst.band_m).round().max(1.0) as u32;
    if band_px <= 1 {
        return;
    }
    let Some((x0, y0, rw, rh)) = polygon_px_bbox(extent, poly, band_px) else {
        return;
    };
    if (rw as u64) * (rh as u64) < 16 {
        return;
    }

    crate::profile::time_stage(timers, StageSlot::Shapeburst, || {
        let Some(mut mask) = Pixmap::new(rw, rh) else {
            return;
        };
        let mut mask_paint = Paint::default();
        mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
        mask_paint.anti_alias = true;
        let offset = Transform::from_translate(-(x0 as f32), -(y0 as f32));
        mask.fill_path(
            &path,
            &mask_paint,
            FillRule::EvenOdd,
            offset,
            None,
        );

        let mut blurred = mask.clone();
        box_blur_approx(&mut blurred, band_px);
        apply_shapeburst_edge_region(pixmap, &mask, &blurred, burst, x0, y0, rw, rh);
    });
}

fn polygon_px_bbox(
    extent: RenderExtent,
    poly: &Polygon<f64>,
    pad: u32,
) -> Option<(u32, u32, u32, u32)> {
    let mut min_x = f32::MAX;
    let mut min_y = f32::MAX;
    let mut max_x = f32::MIN;
    let mut max_y = f32::MIN;
    for ring in std::iter::once(poly.exterior()).chain(poly.interiors()) {
        for c in ring.coords() {
            let (x, y) = map_to_px(extent, *c);
            min_x = min_x.min(x);
            min_y = min_y.min(y);
            max_x = max_x.max(x);
            max_y = max_y.max(y);
        }
    }
    if min_x > max_x || min_y > max_y {
        return None;
    }
    let tw = extent.width_px as f32;
    let th = extent.height_px as f32;
    let x0 = (min_x.floor() as i32 - pad as i32).clamp(0, tw as i32 - 1) as u32;
    let y0 = (min_y.floor() as i32 - pad as i32).clamp(0, th as i32 - 1) as u32;
    let x1 = (max_x.ceil() as i32 + pad as i32).clamp(0, tw as i32) as u32;
    let y1 = (max_y.ceil() as i32 + pad as i32).clamp(0, th as i32) as u32;
    let rw = x1.saturating_sub(x0).max(1);
    let rh = y1.saturating_sub(y0).max(1);
    Some((x0, y0, rw, rh))
}

fn union_polygon_px_bbox(
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    pad: u32,
) -> Option<(u32, u32, u32, u32)> {
    let mut min_x = f32::MAX;
    let mut min_y = f32::MAX;
    let mut max_x = f32::MIN;
    let mut max_y = f32::MIN;
    let mut any = false;
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            if let Some((x0, y0, rw, rh)) = polygon_px_bbox(extent, &poly, 0) {
                any = true;
                min_x = min_x.min(x0 as f32);
                min_y = min_y.min(y0 as f32);
                max_x = max_x.max((x0 + rw) as f32);
                max_y = max_y.max((y0 + rh) as f32);
            }
        }
    }
    if !any {
        return None;
    }
    let tw = extent.width_px as f32;
    let th = extent.height_px as f32;
    let x0 = (min_x.floor() as i32 - pad as i32).clamp(0, tw as i32 - 1) as u32;
    let y0 = (min_y.floor() as i32 - pad as i32).clamp(0, th as i32 - 1) as u32;
    let x1 = (max_x.ceil() as i32 + pad as i32).clamp(0, tw as i32) as u32;
    let y1 = (max_y.ceil() as i32 + pad as i32).clamp(0, th as i32) as u32;
    let rw = x1.saturating_sub(x0).max(1);
    let rh = y1.saturating_sub(y0).max(1);
    Some((x0, y0, rw, rh))
}

fn apply_shapeburst_edge_region(
    pixmap: &mut Pixmap,
    mask: &Pixmap,
    blurred: &Pixmap,
    burst: ShapeburstFill,
    x0: u32,
    y0: u32,
    rw: u32,
    rh: u32,
) {
    let edge_r = burst.edge_color.red();
    let edge_g = burst.edge_color.green();
    let edge_b = burst.edge_color.blue();
    let strength = burst.strength;

    let mask_data = mask.data();
    let blur_data = blurred.data();
    let tile_w = pixmap.width() as usize;
    let px_data = pixmap.data_mut();

    for ly in 0..rh {
        let ty = y0 + ly;
        for lx in 0..rw {
            let tx = x0 + lx;
            let tile_idx = (ty as usize * tile_w + tx as usize) * 4;
            let local_idx = (ly as usize * rw as usize + lx as usize) * 4;

            let ma = mask_data[local_idx + 3] as f32 / 255.0;
            if ma < 1.0 / 255.0 {
                continue;
            }
            let ba = blur_data[local_idx + 3] as f32 / 255.0;
            let edge = ((ma - ba) / ma).clamp(0.0, 1.0) * strength;
            if edge < 0.001 {
                continue;
            }

            let a = px_data[tile_idx + 3] as f32 / 255.0;
            if a < 0.001 {
                continue;
            }
            let mut r = px_data[tile_idx] as f32 / 255.0 / a;
            let mut g = px_data[tile_idx + 1] as f32 / 255.0 / a;
            let mut b = px_data[tile_idx + 2] as f32 / 255.0 / a;

            r = r * (1.0 - edge) + edge_r * edge;
            g = g * (1.0 - edge) + edge_g * edge;
            b = b * (1.0 - edge) + edge_b * edge;

            px_data[tile_idx] = (r * a * 255.0).round() as u8;
            px_data[tile_idx + 1] = (g * a * 255.0).round() as u8;
            px_data[tile_idx + 2] = (b * a * 255.0).round() as u8;
        }
    }
}

pub fn fill_polygons(pixmap: &mut Pixmap, extent: RenderExtent, geom: Geometry<f64>, color: Color) {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(extent, &poly) else {
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
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    fill: Color,
    shadow: DropShadow,
    timers: &mut Option<&mut StageTimers>,
) {
    if geoms.is_empty() {
        return;
    }
    fill_polygons_shadow_only(pixmap, extent, geoms, shadow, timers);
    for geom in geoms {
        fill_polygons(pixmap, extent, geom.clone(), fill);
    }
}

/// Drop-shadow only (QGIS `drawSource` disabled — e.g. `building_shade`).
///
/// Knocks the solid shape out of the blurred shadow so AA fill edges blend with
/// the map background instead of dark shadow (avoids "Blitzer" dark fringe pixels).
/// White coverage of the footprints (opaque inside, AA edges), used as the shadow source.
fn footprint_mask(extent: RenderExtent, geoms: &[Geometry<f64>]) -> Option<Pixmap> {
    let mut mask = Pixmap::new(extent.width_px, extent.height_px)?;
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            let Some(path) = polygon_to_path(extent, &poly) else {
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
    Some(mask)
}

/// Translucent fill with the QGIS dropShadow drawn underneath it, *including* the footprint
/// interior (no knockout). QGIS paints the effect under the source, so a semi-transparent
/// fill (e.g. symbol alpha 0.7) shows the shadow through the building.
pub fn fill_polygons_batch_shadow_under(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    fill: Color,
    shadow: DropShadow,
    timers: &mut Option<&mut StageTimers>,
) {
    if geoms.is_empty() {
        return;
    }
    crate::profile::time_stage(timers, StageSlot::Shadow, || {
        let Some(mut mask) = footprint_mask(extent, geoms) else {
            return;
        };
        tint_pixmap_rgb(&mut mask, shadow.color, shadow.opacity);
        let blur_px = extent.metres_to_px(shadow.blur_m).round().max(1.0) as u32;
        box_blur_approx(&mut mask, blur_px);
        let (dx, dy) = shadow.offset_px(extent);
        pixmap.draw_pixmap(
            dx.round() as i32,
            dy.round() as i32,
            mask.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );
    });
    for geom in geoms {
        fill_polygons(pixmap, extent, geom.clone(), fill);
    }
}

pub fn fill_polygons_shadow_only(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    shadow: DropShadow,
    timers: &mut Option<&mut StageTimers>,
) {
    if geoms.is_empty() {
        return;
    }
    crate::profile::time_stage(timers, StageSlot::Shadow, || {
        let Some(mut mask) = footprint_mask(extent, geoms) else {
            return;
        };

        // Keep an unblurred coverage mask for interior knockout.
        let mut solid = mask.clone();
        // Dilate ~1px so polygon AA fringes aren't composited over residual shadow
        // (that mix is the dark "Blitzer" sparkle on building edges).
        dilate_alpha_1px(&mut solid);

        tint_pixmap_rgb(&mut mask, shadow.color, shadow.opacity);
        let blur_px = extent.metres_to_px(shadow.blur_m).round().max(1.0) as u32;
        box_blur_approx(&mut mask, blur_px);

        // Punch the (dilated) footprint out of the shadow.
        knockout_premul_by_mask(&mut mask, &solid);

        let (dx, dy) = shadow.offset_px(extent);
        let paint = PixmapPaint::default();
        pixmap.draw_pixmap(
            dx.round() as i32,
            dy.round() as i32,
            mask.as_ref(),
            &paint,
            Transform::identity(),
            None,
        );
    });
}

/// `dst = dst * (1 - mask.alpha)` in premul space (mask RGB ignored; uses its alpha).
fn knockout_premul_by_mask(dst: &mut Pixmap, mask: &Pixmap) {
    let d = dst.data_mut();
    let m = mask.data();
    let n = d.len().min(m.len());
    let mut i = 0;
    while i + 3 < n {
        let ma = m[i + 3] as f32 / 255.0;
        if ma > 0.0 {
            let keep = 1.0 - ma;
            d[i] = (d[i] as f32 * keep).round() as u8;
            d[i + 1] = (d[i + 1] as f32 * keep).round() as u8;
            d[i + 2] = (d[i + 2] as f32 * keep).round() as u8;
            d[i + 3] = (d[i + 3] as f32 * keep).round() as u8;
        }
        i += 4;
    }
}

/// Max-filter on alpha (and copy RGB from the max neighbour) — 1px morphological dilate.
fn dilate_alpha_1px(pm: &mut Pixmap) {
    let w = pm.width() as usize;
    let h = pm.height() as usize;
    let src = pm.data().to_vec();
    let dst = pm.data_mut();
    for y in 0..h {
        for x in 0..w {
            let mut best_a = 0u8;
            let mut best_i = (y * w + x) * 4;
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    let xx = x as i32 + dx;
                    let yy = y as i32 + dy;
                    if xx < 0 || yy < 0 || xx as usize >= w || yy as usize >= h {
                        continue;
                    }
                    let i = (yy as usize * w + xx as usize) * 4;
                    if src[i + 3] > best_a {
                        best_a = src[i + 3];
                        best_i = i;
                    }
                }
            }
            let o = (y * w + x) * 4;
            dst[o] = src[best_i];
            dst[o + 1] = src[best_i + 1];
            dst[o + 2] = src[best_i + 2];
            dst[o + 3] = best_a;
        }
    }
}

/// Batch exterior shadow + batch shapeburst fill (buildings).
pub fn fill_polygons_batch_with_shadow_shapeburst(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    fill: Color,
    shadow: DropShadow,
    burst: ShapeburstFill,
    timers: &mut Option<&mut StageTimers>,
) {
    if geoms.is_empty() {
        return;
    }
    fill_polygons_shadow_only(pixmap, extent, geoms, shadow, timers);
    fill_polygons_batch_shapeburst(pixmap, extent, geoms, fill, burst, timers);
}

pub(crate) fn tint_pixmap_rgb(pixmap: &mut Pixmap, tint: Color, opacity: f32) {
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
pub(crate) fn box_blur_approx(pixmap: &mut Pixmap, radius: u32) {
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
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
) {
    stroke_lines_dashed(pixmap, extent, geom, color, width_m, None);
}

/// Stroke lines with optional dasharray in map metres (`"1;1"` → 1 m on / 1 m off).
pub fn stroke_lines_dashed(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
    dasharray_m: Option<&str>,
) {
    let width_px = extent.metres_to_px(width_m).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let dash = dasharray_m.and_then(|spec| parse_dasharray_px(extent, spec));
    let stroke = Stroke {
        width: width_px,
        dash,
        ..Stroke::default()
    };
    for line in geometry_lines(geom) {
        let Some(path) = linestring_to_path(extent, &line) else {
            continue;
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
    }
}

fn parse_dasharray_px(extent: RenderExtent, spec: &str) -> Option<StrokeDash> {
    let parts: Vec<f32> = spec
        .split([';', ' ', ','])
        .filter_map(|p| {
            let t = p.trim();
            if t.is_empty() {
                return None;
            }
            let metres: f64 = t.parse().ok()?;
            Some(extent.metres_to_px(metres).max(0.5) as f32)
        })
        .collect();
    if parts.is_empty() {
        return None;
    }
    // StrokeDash requires an even-length array.
    let mut arr = parts;
    if arr.len() % 2 == 1 {
        arr.push(arr[0]);
    }
    StrokeDash::new(arr, 0.0)
}

/// Böschung / cliff / embankment: brown spine + one-sided filled triangles (QGIS MarkerLine).
pub fn stroke_embankment(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    spine_width_m: f64,
    marker_spacing_m: f64,
    triangle_size_m: f64,
    perp_offset_m: f64,
) {
    stroke_lines(pixmap, extent, geom.clone(), color, spine_width_m);
    let spacing = marker_spacing_m.max(0.5);
    let tri_side = triangle_size_m.max(0.4);
    let perp_off = perp_offset_m.max(0.2);
    let tri_h = tri_side * 3.0_f64.sqrt() / 2.0;
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for line in geometry_lines(geom) {
        for (x, y, dx, dy) in sample_line_tangents(&line, spacing) {
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-9 {
                continue;
            }
            let tx = dx / len;
            let ty = dy / len;
            // Flipped vs earlier tick side: right-hand `(dy, -dx)` (QGIS + = left of travel).
            let px = ty;
            let py = -tx;
            let apex_x = x + px * perp_off;
            let apex_y = y + py * perp_off;
            // QGIS angle=180°: apex points backward along the line.
            let base_cx = apex_x + tx * tri_h;
            let base_cy = apex_y + ty * tri_h;
            let half = tri_side / 2.0;
            let mut pb = PathBuilder::new();
            let (ax, ay) = map_to_px(extent, Coord { x: apex_x, y: apex_y });
            let (b1x, b1y) = map_to_px(
                extent,
                Coord {
                    x: base_cx + px * half,
                    y: base_cy + py * half,
                },
            );
            let (b2x, b2y) = map_to_px(
                extent,
                Coord {
                    x: base_cx - px * half,
                    y: base_cy - py * half,
                },
            );
            pb.move_to(ax, ay);
            pb.line_to(b1x, b1y);
            pb.line_to(b2x, b2y);
            pb.close();
            if let Some(path) = pb.finish() {
                pixmap.fill_path(
                    &path,
                    &paint,
                    FillRule::Winding,
                    Transform::identity(),
                    None,
                );
            }
        }
    }
}

/// `highway=steps` HashLine: perpendicular hash segments every `interval_m`.
pub fn stroke_steps_hash(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
    interval_m: f64,
    hash_stroke_m: f64,
) {
    let hash_len = width_m.max(0.5);
    let spacing = interval_m.max(0.3);
    let stroke_w = hash_stroke_m.max(extent.metres_per_px());
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let stroke = Stroke {
        width: extent.metres_to_px(stroke_w).max(1.0),
        line_cap: tiny_skia::LineCap::Butt,
        ..Stroke::default()
    };
    for line in geometry_lines(geom) {
        for (x, y, dx, dy) in sample_line_tangents(&line, spacing) {
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-9 {
                continue;
            }
            let px = -dy / len * hash_len / 2.0;
            let py = dx / len * hash_len / 2.0;
            let mut pb = PathBuilder::new();
            let (x0, y0) = map_to_px(extent, Coord { x: x - px, y: y - py });
            let (x1, y1) = map_to_px(extent, Coord { x: x + px, y: y + py });
            pb.move_to(x0, y0);
            pb.line_to(x1, y1);
            if let Some(path) = pb.finish() {
                pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
            }
        }
    }
}

/// Stroke lines offset perpendicular to travel (negative = right-hand side, MapLibre convention).
pub fn stroke_lines_offset(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
    offset_m: f64,
) {
    if offset_m.abs() < 1e-6 {
        stroke_lines(pixmap, extent, geom, color, width_m);
        return;
    }
    stroke_lines(pixmap, extent, offset_geometry(geom, offset_m), color, width_m);
}

/// Offset dashed lines (used for path casing).
pub fn stroke_lines_offset_dashed(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
    offset_m: f64,
    dasharray_m: Option<&str>,
) {
    if offset_m.abs() < 1e-6 {
        stroke_lines_dashed(pixmap, extent, geom, color, width_m, dasharray_m);
        return;
    }
    stroke_lines_dashed(
        pixmap,
        extent,
        offset_geometry(geom, offset_m),
        color,
        width_m,
        dasharray_m,
    );
}

fn offset_geometry(geom: Geometry<f64>, offset_m: f64) -> Geometry<f64> {
    match geom {
        Geometry::LineString(ls) => Geometry::LineString(offset_linestring(&ls, offset_m)),
        Geometry::MultiLineString(mls) => Geometry::MultiLineString(
            mls.0
                .into_iter()
                .map(|ls| offset_linestring(&ls, offset_m))
                .collect(),
        ),
        other => other,
    }
}

fn offset_linestring(line: &LineString<f64>, offset_m: f64) -> LineString<f64> {
    let coords = &line.0;
    if coords.len() < 2 {
        return line.clone();
    }
    let mut out = Vec::with_capacity(coords.len());
    for i in 0..coords.len() {
        let (dx, dy) = tangent_at_index(coords, i);
        let len = (dx * dx + dy * dy).sqrt();
        if len < 1e-9 {
            out.push(coords[i]);
            continue;
        }
        let ox = dy / len * offset_m;
        let oy = -dx / len * offset_m;
        out.push(Coord {
            x: coords[i].x + ox,
            y: coords[i].y + oy,
        });
    }
    LineString(out)
}

fn tangent_at_index(coords: &[Coord<f64>], i: usize) -> (f64, f64) {
    if i == 0 {
        let a = coords[0];
        let b = coords[1];
        (b.x - a.x, b.y - a.y)
    } else if i + 1 == coords.len() {
        let a = coords[i - 1];
        let b = coords[i];
        (b.x - a.x, b.y - a.y)
    } else {
        let a = coords[i - 1];
        let b = coords[i + 1];
        (b.x - a.x, b.y - a.y)
    }
}

/// Sample (x,y) along a linestring every `spacing_m`, with segment tangent (dx,dy) in map metres.
fn sample_line_tangents(line: &LineString<f64>, spacing_m: f64) -> Vec<(f64, f64, f64, f64)> {
    let mut out = Vec::new();
    let coords = &line.0;
    if coords.len() < 2 {
        return out;
    }
    let mut dist_along = 0.0;
    let mut next_tick = 0.0;
    for w in coords.windows(2) {
        let (a, b) = (w[0], w[1]);
        let dx = b.x - a.x;
        let dy = b.y - a.y;
        let seg_len = (dx * dx + dy * dy).sqrt();
        if seg_len < 1e-9 {
            continue;
        }
        while next_tick <= dist_along + seg_len {
            let t = ((next_tick - dist_along) / seg_len).clamp(0.0, 1.0);
            out.push((a.x + dx * t, a.y + dy * t, dx, dy));
            next_tick += spacing_m;
        }
        dist_along += seg_len;
    }
    out
}

/// Stroke polygon exterior (+ hole) rings at a map-metre width.
pub fn stroke_polygons(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    width_m: f64,
) {
    let width_px = extent.metres_to_px(width_m).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let stroke = Stroke {
        width: width_px,
        ..Stroke::default()
    };
    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(extent, &poly) else {
            continue;
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
    }
}

/// Filled circles with stroke outline (map-metre radii).
pub fn fill_stroke_circles_m(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    fill: Color,
    stroke_color: Color,
    radius_m: f64,
    stroke_width_m: f64,
) {
    let radius_px = extent.metres_to_px(radius_m).max(0.5);
    let width_px = extent.metres_to_px(stroke_width_m).max(0.4);
    let mut fill_paint = Paint::default();
    fill_paint.set_color(fill);
    fill_paint.anti_alias = true;
    let mut stroke_paint = Paint::default();
    stroke_paint.set_color(stroke_color);
    stroke_paint.anti_alias = true;
    let stroke = Stroke {
        width: width_px,
        ..Stroke::default()
    };
    for pt in geometry_points(geom) {
        let (cx, cy) = map_to_px(extent, Coord { x: pt.x(), y: pt.y() });
        let mut pb = PathBuilder::new();
        pb.push_circle(cx, cy, radius_px);
        let Some(path) = pb.finish() else {
            continue;
        };
        pixmap.fill_path(
            &path,
            &fill_paint,
            FillRule::Winding,
            Transform::identity(),
            None,
        );
        pixmap.stroke_path(&path, &stroke_paint, &stroke, Transform::identity(), None);
    }
}

/// Hollow circles (stroke only).
pub fn stroke_circles_m(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    stroke_color: Color,
    radius_m: f64,
    stroke_width_m: f64,
) {
    let radius_px = extent.metres_to_px(radius_m).max(0.5);
    let width_px = extent.metres_to_px(stroke_width_m).max(0.4);
    let mut paint = Paint::default();
    paint.set_color(stroke_color);
    paint.anti_alias = true;
    let stroke = Stroke {
        width: width_px,
        ..Stroke::default()
    };
    for pt in geometry_points(geom) {
        let (cx, cy) = map_to_px(extent, Coord { x: pt.x(), y: pt.y() });
        let mut pb = PathBuilder::new();
        pb.push_circle(cx, cy, radius_px);
        let Some(path) = pb.finish() else {
            continue;
        };
        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
    }
}

/// MarkerLine: filled circles along linestrings (bollard / palisade).
pub fn marker_line_circles_m(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    diameter_m: f64,
    spacing_m: f64,
) {
    let radius_m = diameter_m / 2.0;
    let radius_px = extent.metres_to_px(radius_m).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for line in geometry_lines(geom) {
        for (x, y, _, _) in sample_line_tangents(&line, spacing_m) {
            let (cx, cy) = map_to_px(extent, Coord { x, y });
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
}

pub fn fill_circles_m(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    radius_m: f64,
) {
    let radius_px = extent.metres_to_px(radius_m).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    for pt in geometry_points(geom) {
        let (cx, cy) = map_to_px(extent, Coord { x: pt.x(), y: pt.y() });
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

/// Tree / shrub crown ≈ QGIS `tree crown` RasterMarker (layer opacity 0.25).
///
/// Per feature, in QGIS effect-stack order: the drop shadow (silhouette of the
/// crown PNG, blurred, offset, multiplied onto what is below) first, then the
/// crown image itself. Both inherit the layer opacity.
pub fn draw_tree_crown_marker(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    cx: f32,
    cy: f32,
    catalog: &TreeMarkerCatalog,
    leaf_type: Option<&str>,
    is_shrub: bool,
    variant: u64,
    diameter_map_m: f64,
    rotation_deg: f32,
    shadow: Option<DropShadow>,
    layer_opacity: f32,
) {
    let size_px = extent.metres_to_px(diameter_map_m).max(1.0);
    let op = layer_opacity.clamp(0.0, 1.0);
    let sprite = catalog.sprite_for(leaf_type, is_shrub, variant, size_px);

    if let Some(shadow) = shadow {
        draw_tree_crown_shadow(pixmap, extent, cx, cy, sprite, size_px, shadow, op);
    }

    // Uniform fit of the marker into the size_px square, rotated about its centre.
    let sw = sprite.width() as f32;
    let sh = sprite.height() as f32;
    let s = size_px / sw.max(sh);
    let (sin, cos) = rotation_deg.to_radians().sin_cos();
    let (a, b) = (s * cos, s * sin);
    let (c, d) = (-s * sin, s * cos);
    // Map sprite centre (sw/2, sh/2) onto (cx, cy).
    let hx = sw * 0.5;
    let hy = sh * 0.5;
    let e = cx - (a * hx + c * hy);
    let f = cy - (b * hx + d * hy);
    let transform = Transform::from_row(a, b, c, d, e, f);
    let paint = PixmapPaint {
        opacity: op,
        blend_mode: BlendMode::SourceOver,
        quality: FilterQuality::Bilinear,
    };
    pixmap.draw_pixmap(0, 0, sprite.as_ref(), &paint, transform, None);
}

/// Silhouette of the crown sprite → blur → offset → tint, multiplied onto `pixmap`.
#[allow(clippy::too_many_arguments)]
fn draw_tree_crown_shadow(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    cx: f32,
    cy: f32,
    sprite: &Pixmap,
    size_px: f32,
    shadow: DropShadow,
    layer_opacity: f32,
) {
    let (sdx, sdy) = shadow.offset_px(extent);
    let blur_px = extent.metres_to_px(shadow.blur_m).max(0.0);
    let pad = (blur_px * 1.5).ceil() as u32 + 2 + sdx.abs().max(sdy.abs()).ceil() as u32;
    let side = (size_px.ceil() as u32 + 2 * pad).max(4);
    let Some(mut canvas) = Pixmap::new(side, side) else {
        return;
    };
    let mid = side as f32 * 0.5;

    // Draw the sprite's alpha at the crown size, offset by the shadow vector.
    let sw = sprite.width() as f32;
    let sh = sprite.height() as f32;
    let s = size_px / sw.max(sh);
    let transform = Transform::from_row(
        s,
        0.0,
        0.0,
        s,
        mid + sdx - sw * s * 0.5,
        mid + sdy - sh * s * 0.5,
    );
    let paint = PixmapPaint {
        opacity: 1.0,
        blend_mode: BlendMode::SourceOver,
        quality: FilterQuality::Bilinear,
    };
    canvas.draw_pixmap(0, 0, sprite.as_ref(), &paint, transform, None);

    // Keep only alpha (silhouette), remembering the sharp crown mask.
    let mask: Vec<u8> = canvas.data().chunks_exact(4).map(|px| px[3]).collect();
    for px in canvas.data_mut().chunks_exact_mut(4) {
        px[0] = 0;
        px[1] = 0;
        px[2] = 0;
    }
    let radius = (blur_px * 0.5).round().max(1.0) as u32;
    box_blur_approx(&mut canvas, radius);
    tint_pixmap_rgb(&mut canvas, shadow.color, shadow.opacity);
    // QGIS shows no shadow inside the crown (the crown composite matches the
    // unshadowed colour), so the shadow is knocked out under the crown mask.
    for (px, m) in canvas.data_mut().chunks_exact_mut(4).zip(mask.iter()) {
        let keep = 1.0 - f32::from(*m) / 255.0;
        if keep < 1.0 {
            for c in px.iter_mut() {
                *c = (f32::from(*c) * keep).round() as u8;
            }
        }
    }

    let mult = PixmapPaint {
        opacity: layer_opacity,
        blend_mode: BlendMode::Multiply,
        quality: FilterQuality::Nearest,
    };
    let ox = (cx - mid).round() as i32;
    let oy = (cy - mid).round() as i32;
    pixmap.draw_pixmap(ox, oy, canvas.as_ref(), &mult, Transform::identity(), None);
}

/// Envelope SQL fragment params $1..$4 (minx,miny,maxx,maxy).
pub fn envelope_sql() -> &'static str {
    "ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)"
}

pub fn clip_polygon_wkb_sql(geom_col: &str) -> String {
    clip_polygon_wkb_sql_fast(geom_col, 0)
}

/// Polygon clip → WKB. Always `ST_MakeValid` (skipping it at z≥18 caused WKB EOF decode errors).
/// Speed comes from lighter WHERE (`geom && env` only) in callers, not from dropping MakeValid.
pub fn clip_polygon_wkb_sql_fast(geom_col: &str, _z: u32) -> String {
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


/// QGIS LinePatternFill stand-in: parallel hatch lines clipped to polygon interior.
pub fn fill_polygons_hatch(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    opacity: f32,
    direction_deg: Option<f64>,
    pattern: Option<&str>,
) {
    let direction = direction_deg.unwrap_or(0.0);
    let mut hatch_color = color;
    hatch_color.set_alpha(opacity);
    let stripes_angle = -direction + 90.0;
    let cross_angle = -direction;
    let is_crosshatch = pattern == Some("crosshatch") || pattern == Some("chessboard");
    if is_crosshatch {
        hatch_pass(pixmap, extent, geom.clone(), hatch_color, cross_angle, 0.25, 1.25);
        hatch_pass(pixmap, extent, geom, hatch_color, stripes_angle, 0.25, 1.25);
    } else {
        hatch_pass(pixmap, extent, geom, hatch_color, stripes_angle, 0.25, 0.75);
    }
}

fn hatch_pass(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    color: Color,
    angle_deg: f64,
    line_width_m: f64,
    spacing_m: f64,
) {
    let width_px = extent.metres_to_px(line_width_m).max(0.5);
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let stroke = Stroke { width: width_px, ..Stroke::default() };
    let angle_rad = angle_deg.to_radians();
    let dir_x = angle_rad.cos();
    let dir_y = angle_rad.sin();
    let perp_x = -dir_y;
    let perp_y = dir_x;
    for poly in geometry_polygons(geom) {
        let (min_x, min_y, max_x, max_y) = polygon_bbox(&poly);
        let diagonal = ((max_x - min_x).powi(2) + (max_y - min_y).powi(2)).sqrt().max(spacing_m);
        let mid_x = (min_x + max_x) * 0.5;
        let mid_y = (min_y + max_y) * 0.5;
        let half_len = diagonal * 0.75;
        let num_lines = (diagonal / spacing_m).ceil() as i32 + 2;
        for i in -num_lines / 2..=num_lines / 2 {
            let offset = f64::from(i) * spacing_m;
            let origin_x = mid_x + perp_x * offset;
            let origin_y = mid_y + perp_y * offset;
            let ax = origin_x - dir_x * half_len;
            let ay = origin_y - dir_y * half_len;
            let bx = origin_x + dir_x * half_len;
            let by = origin_y + dir_y * half_len;
            for (p0, p1) in clip_segment_to_polygon(ax, ay, bx, by, &poly) {
                let mut pb = PathBuilder::new();
                let (x0, y0) = map_to_px(extent, p0);
                let (x1, y1) = map_to_px(extent, p1);
                pb.move_to(x0, y0);
                pb.line_to(x1, y1);
                if let Some(path) = pb.finish() {
                    pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                }
            }
        }
    }
}

fn polygon_bbox(poly: &Polygon<f64>) -> (f64, f64, f64, f64) {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for c in poly.exterior().coords() {
        min_x = min_x.min(c.x);
        min_y = min_y.min(c.y);
        max_x = max_x.max(c.x);
        max_y = max_y.max(c.y);
    }
    (min_x, min_y, max_x, max_y)
}

pub(crate) fn clip_segment_to_polygon(ax: f64, ay: f64, bx: f64, by: f64, poly: &Polygon<f64>) -> Vec<(Coord<f64>, Coord<f64>)> {
    let mut ts = vec![0.0, 1.0];
    collect_edge_hits(ax, ay, bx, by, poly.exterior(), &mut ts);
    for hole in poly.interiors() {
        collect_edge_hits(ax, ay, bx, by, hole, &mut ts);
    }
    ts.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    ts.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
    let dx = bx - ax;
    let dy = by - ay;
    let mut out = Vec::new();
    for w in ts.windows(2) {
        let (t0, t1) = (w[0], w[1]);
        if t1 - t0 < 1e-9 { continue; }
        let mx = ax + dx * (t0 + t1) * 0.5;
        let my = ay + dy * (t0 + t1) * 0.5;
        if point_in_polygon(mx, my, poly) {
            out.push((Coord { x: ax + dx * t0, y: ay + dy * t0 }, Coord { x: ax + dx * t1, y: ay + dy * t1 }));
        }
    }
    out
}

fn collect_edge_hits(ax: f64, ay: f64, bx: f64, by: f64, ring: &LineString<f64>, ts: &mut Vec<f64>) {
    for w in ring.0.windows(2) {
        if let Some(t) = segment_intersection_t(ax, ay, bx, by, w[0].x, w[0].y, w[1].x, w[1].y) {
            ts.push(t);
        }
    }
}

fn segment_intersection_t(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, dx: f64, dy: f64) -> Option<f64> {
    let (r_x, r_y) = (bx - ax, by - ay);
    let (s_x, s_y) = (dx - cx, dy - cy);
    let denom = r_x * s_y - r_y * s_x;
    if denom.abs() < 1e-12 { return None; }
    let t = ((cx - ax) * s_y - (cy - ay) * s_x) / denom;
    let u = ((cx - ax) * r_y - (cy - ay) * r_x) / denom;
    if (0.0..=1.0).contains(&t) && (0.0..=1.0).contains(&u) { Some(t) } else { None }
}

fn point_in_polygon(x: f64, y: f64, poly: &Polygon<f64>) -> bool {
    if !point_in_ring(x, y, poly.exterior()) { return false; }
    for hole in poly.interiors() {
        if point_in_ring(x, y, hole) { return false; }
    }
    true
}

fn point_in_ring(x: f64, y: f64, ring: &LineString<f64>) -> bool {
    let coords = &ring.0;
    if coords.len() < 3 { return false; }
    let mut inside = false;
    let mut j = coords.len() - 1;
    for i in 0..coords.len() {
        let (xi, yi, xj, yj) = (coords[i].x, coords[i].y, coords[j].x, coords[j].y);
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi + f64::EPSILON) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}


pub fn clip_line_wkb_sql(geom_col: &str) -> String {
    clip_line_wkb_sql_fast(geom_col, 0)
}

pub fn clip_line_wkb_sql_fast(geom_col: &str, _z: u32) -> String {
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

/// One QGIS RasterFill as evaluated for a feature (see `palette::TextureRule`).
#[derive(Clone, Copy, Debug)]
pub struct RasterFillParams {
    pub alpha: f32,
    /// Ground metres per repeat (`MapUnit × @mercator_scale`); `None` → native texture pixels.
    pub width_m: Option<f64>,
    /// Pattern rotation in degrees (QGIS `angle`).
    pub angle_deg: f64,
    /// Multiply composite; `false` → Normal (source-over).
    pub multiply: bool,
}

/// RasterFill over `geom`: map-anchored (QGIS coordinate mode *Feature*), i.e. the pattern
/// origin is the Web Mercator origin, rotated by `angle_deg` about it. Texture width follows
/// the QGIS data-defined `width` (ground metres × `@mercator_scale`).
///
/// Anti-aliasing is off for the texture pass: the base fill already anti-aliases the edge.
pub fn fill_polygons_raster_fill(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: Geometry<f64>,
    texture: &Texture,
    params: RasterFillParams,
) {
    if params.alpha <= 0.0 {
        return;
    }
    let pw = f64::from(texture.pixmap.width());
    let ph = f64::from(texture.pixmap.height());
    if pw < 1.0 || ph < 1.0 {
        return;
    }
    // Texel → device pixels (square texels). Native (`None`) keeps 1 texel = 1 device px.
    let k = match params.width_m {
        Some(wm) => f64::from(extent.metres_to_px(wm * mercator_scale(extent.bounds))) / pw,
        None => 1.0,
    };
    if !(k.is_finite() && k > 0.0) {
        return;
    }
    let (s, c) = params.angle_deg.to_radians().sin_cos();
    // Texel (u, v) → device: X = O.x + m00·u + m01·v, Y = O.y + m10·u + m11·v.
    let (m00, m01, m10, m11) = (k * c, k * s, k * s, -k * c);
    let det = m00 * m11 - m01 * m10;
    // Device position of the world origin, in f64 (z20 coordinates overflow f32 precision).
    let mpp = extent.metres_per_px();
    let ox = -extent.bounds.minx / mpp;
    let oy = extent.bounds.maxy / mpp;
    // Pattern is periodic: shift the origin by whole texture periods before narrowing to f32.
    let tu = (m11 * ox - m01 * oy) / det;
    let tv = (-m10 * ox + m00 * oy) / det;
    let nu = (tu / pw).round() * pw;
    let nv = (tv / ph).round() * ph;
    let (tu, tv) = (tu - nu, tv - nv);
    let x0 = (m00 * tu + m01 * tv) as f32;
    let y0 = (m10 * tu + m11 * tv) as f32;

    let transform = Transform::from_row(m00 as f32, m10 as f32, m01 as f32, m11 as f32, x0, y0);
    let shader = Pattern::new(
        texture.pixmap.as_ref(),
        SpreadMode::Repeat,
        FilterQuality::Bilinear,
        params.alpha,
        transform,
    );
    let mut paint = Paint::default();
    paint.shader = shader;
    paint.anti_alias = false;
    paint.blend_mode = if params.multiply {
        BlendMode::Multiply
    } else {
        BlendMode::SourceOver
    };
    for poly in geometry_polygons(geom) {
        let Some(path) = polygon_to_path(extent, &poly) else {
            continue;
        };
        pixmap.fill_path(&path, &paint, FillRule::EvenOdd, Transform::identity(), None);
    }
}

/// QGIS layer-level innerShadow with zero offset (kerb / edge shading): over the union of
/// `geoms`, multiplies the existing pixels by `1 - opacity * S * (1 - shade)` where
/// `S = A * (1 - blur(A))` and `A` is polygon coverage. `sigma_px` is the Gaussian blur.
pub fn fill_polygons_inner_shadow_multiply(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geoms: &[Geometry<f64>],
    sigma_px: f32,
    shade: f32,
    opacity: f32,
) {
    if geoms.is_empty() || opacity <= 0.0 {
        return;
    }
    let w = pixmap.width() as usize;
    let h = pixmap.height() as usize;
    let Some(mut mask) = Pixmap::new(w as u32, h as u32) else {
        return;
    };
    let mut mask_paint = Paint::default();
    mask_paint.set_color(Color::from_rgba8(255, 255, 255, 255));
    mask_paint.anti_alias = true;
    for geom in geoms {
        for poly in geometry_polygons(geom.clone()) {
            let Some(path) = polygon_to_path(extent, &poly) else {
                continue;
            };
            mask.fill_path(&path, &mask_paint, FillRule::EvenOdd, Transform::identity(), None);
        }
    }
    let coverage: Vec<f32> = mask
        .data()
        .chunks_exact(4)
        .map(|px| f32::from(px[3]) / 255.0)
        .collect();
    let blurred = gaussian_blur_f32(&coverage, w, h, sigma_px);
    let k = opacity * (1.0 - shade);
    let data = pixmap.data_mut();
    for (i, (a, b)) in coverage.iter().zip(blurred.iter()).enumerate() {
        let s = a * (1.0 - b);
        if s <= 1e-4 {
            continue;
        }
        let f = 1.0 - k * s;
        let o = i * 4;
        for ch in 0..3 {
            data[o + ch] = (f32::from(data[o + ch]) * f).round().clamp(0.0, 255.0) as u8;
        }
    }
}

/// Separable Gaussian over a `w × h` float buffer (zero outside the buffer).
fn gaussian_blur_f32(src: &[f32], w: usize, h: usize, sigma: f32) -> Vec<f32> {
    if sigma < 0.05 {
        return src.to_vec();
    }
    let r = (sigma * 3.0).ceil() as i32;
    let mut kernel: Vec<f32> = (-r..=r)
        .map(|i| (-((i * i) as f32) / (2.0 * sigma * sigma)).exp())
        .collect();
    let sum: f32 = kernel.iter().sum();
    for kv in &mut kernel {
        *kv /= sum;
    }
    let mut tmp = vec![0f32; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut acc = 0f32;
            for (j, kv) in kernel.iter().enumerate() {
                let xx = x as i32 + j as i32 - r;
                if xx >= 0 && (xx as usize) < w {
                    acc += kv * src[y * w + xx as usize];
                }
            }
            tmp[y * w + x] = acc;
        }
    }
    let mut out = vec![0f32; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut acc = 0f32;
            for (j, kv) in kernel.iter().enumerate() {
                let yy = y as i32 + j as i32 - r;
                if yy >= 0 && (yy as usize) < h {
                    acc += kv * tmp[yy as usize * w + x];
                }
            }
            out[y * w + x] = acc;
        }
    }
    out
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
