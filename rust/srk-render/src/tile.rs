//! XYZ tile math matching `render/xyz_tiles.py` (ORIGIN_SHIFT, 256 px, EPSG:3857).

use anyhow::{bail, Result};
use tiny_skia::Color;

pub const ORIGIN_SHIFT: f64 = 20_037_508.342_789_244;
pub const TILE_SIZE_PX: u32 = 256;
pub const DEFAULT_BACKGROUND: &str = "#ededed";

#[derive(Clone, Copy, Debug)]
pub struct TileRange {
    pub x0: u32,
    pub x1: u32,
    pub y0: u32,
    pub y1: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct TileBounds {
    pub minx: f64,
    pub miny: f64,
    pub maxx: f64,
    pub maxy: f64,
}

fn clamp_lat(lat: f64) -> f64 {
    lat.clamp(-85.051_128_78, 85.051_128_78)
}

pub fn lon_to_tile_x(lon: f64, z: u32) -> u32 {
    let n = 2f64.powi(z as i32);
    let x = ((lon + 180.0) / 360.0 * n).floor() as i64;
    x.clamp(0, (n as i64) - 1) as u32
}

pub fn lat_to_tile_y(lat: f64, z: u32) -> u32 {
    let lat = clamp_lat(lat);
    let lat_rad = lat.to_radians();
    let n = 2f64.powi(z as i32);
    let y = ((1.0 - (lat_rad.tan().asinh() / std::f64::consts::PI)) / 2.0 * n).floor() as i64;
    y.clamp(0, (n as i64) - 1) as u32
}

pub fn tile_range_for_bbox(xmin: f64, ymin: f64, xmax: f64, ymax: f64, z: u32) -> TileRange {
    let mut x0 = lon_to_tile_x(xmin, z);
    let mut x1 = lon_to_tile_x(xmax, z);
    let mut y0 = lat_to_tile_y(ymax, z);
    let mut y1 = lat_to_tile_y(ymin, z);
    if x1 < x0 {
        std::mem::swap(&mut x0, &mut x1);
    }
    if y1 < y0 {
        std::mem::swap(&mut y0, &mut y1);
    }
    TileRange { x0, x1, y0, y1 }
}

pub fn parse_bbox(spec: &str) -> Result<(f64, f64, f64, f64)> {
    let parts: Vec<_> = spec.split(',').map(str::trim).collect();
    if parts.len() != 4 {
        bail!("--bbox must be xmin,ymin,xmax,ymax, got {spec}");
    }
    Ok((
        parts[0].parse()?,
        parts[1].parse()?,
        parts[2].parse()?,
        parts[3].parse()?,
    ))
}

pub fn enumerate_bbox_tiles(
    xmin: f64,
    ymin: f64,
    xmax: f64,
    ymax: f64,
    zmin: u32,
    zmax: u32,
) -> Vec<(u32, u32, u32)> {
    let mut tiles = Vec::new();
    for z in zmin..=zmax {
        let tr = tile_range_for_bbox(xmin, ymin, xmax, ymax, z);
        for x in tr.x0..=tr.x1 {
            for y in tr.y0..=tr.y1 {
                tiles.push((z, x, y));
            }
        }
    }
    tiles
}

pub fn parse_tile_spec(spec: &str) -> Result<(u32, u32, u32)> {
    let parts: Vec<_> = spec.trim().split('/').collect();
    if parts.len() != 3 {
        bail!("tile spec must be z/x/y, got {spec}");
    }
    Ok((parts[0].parse()?, parts[1].parse()?, parts[2].parse()?))
}

pub fn tile_bounds_3857(x: u32, y: u32, z: u32) -> TileBounds {
    let n = 2f64.powi(z as i32);
    let tile_m = (2.0 * ORIGIN_SHIFT) / n;
    let minx = -ORIGIN_SHIFT + f64::from(x) * tile_m;
    let maxx = -ORIGIN_SHIFT + f64::from(x + 1) * tile_m;
    let maxy = ORIGIN_SHIFT - f64::from(y) * tile_m;
    let miny = ORIGIN_SHIFT - f64::from(y + 1) * tile_m;
    TileBounds {
        minx,
        miny,
        maxx,
        maxy,
    }
}

/// Render extent matching QGIS metatile gutter: core tile ± `gutter` neighbour tiles.
///
/// Features (trees, shadows, AA rims) are painted into this larger buffer; the core
/// 256×256 is cropped afterward so adjacent tiles share the same edge pixels.
#[derive(Clone, Copy, Debug)]
pub struct RenderExtent {
    pub bounds: TileBounds,
    pub width_px: u32,
    pub height_px: u32,
    /// Pixel origin of the core tile inside the render buffer.
    pub core_ox: u32,
    pub core_oy: u32,
    pub gutter: u32,
}

impl RenderExtent {
    /// Same as QGIS `metatile_for_single_tile(z,x,y,gutter)` then `metatile_extent_3857`.
    pub fn for_tile(x: u32, y: u32, z: u32, gutter: u32) -> Self {
        let max_xy = (1u32 << z).saturating_sub(1);
        let rx0 = x.saturating_sub(gutter);
        let rx1 = (x + gutter).min(max_xy);
        let ry0 = y.saturating_sub(gutter);
        let ry1 = (y + gutter).min(max_xy);
        let nw = tile_bounds_3857(rx0, ry0, z);
        let se = tile_bounds_3857(rx1, ry1, z);
        Self {
            bounds: TileBounds {
                minx: nw.minx,
                maxx: se.maxx,
                maxy: nw.maxy,
                miny: se.miny,
            },
            width_px: (rx1 - rx0 + 1) * TILE_SIZE_PX,
            height_px: (ry1 - ry0 + 1) * TILE_SIZE_PX,
            core_ox: (x - rx0) * TILE_SIZE_PX,
            core_oy: (y - ry0) * TILE_SIZE_PX,
            gutter,
        }
    }

    pub fn map_to_px(self, x: f64, y: f64) -> (f32, f32) {
        let w = self.bounds.maxx - self.bounds.minx;
        let h = self.bounds.maxy - self.bounds.miny;
        let px = ((x - self.bounds.minx) / w) * f64::from(self.width_px);
        let py = ((self.bounds.maxy - y) / h) * f64::from(self.height_px);
        (px as f32, py as f32)
    }

    pub fn metres_per_px(self) -> f64 {
        (self.bounds.maxx - self.bounds.minx) / f64::from(self.width_px)
    }

    pub fn metres_to_px(self, metres: f64) -> f32 {
        (metres / self.metres_per_px()) as f32
    }
}

/// Crop the core XYZ tile out of a guttered render buffer (QGIS `image.copy(px,py,256,256)`).
pub fn crop_core_tile(src: &tiny_skia::Pixmap, extent: RenderExtent) -> tiny_skia::Pixmap {
    let mut dst =
        tiny_skia::Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX).expect("core tile pixmap alloc");
    let sw = src.width() as usize;
    let ox = extent.core_ox as usize;
    let oy = extent.core_oy as usize;
    let tw = TILE_SIZE_PX as usize;
    debug_assert!(ox + tw <= src.width() as usize);
    debug_assert!(oy + tw <= src.height() as usize);
    let src_data = src.data();
    let dst_data = dst.data_mut();
    for row in 0..tw {
        let s = ((oy + row) * sw + ox) * 4;
        let d = row * tw * 4;
        dst_data[d..d + tw * 4].copy_from_slice(&src_data[s..s + tw * 4]);
    }
    dst
}

pub fn parse_hex_color(hex: &str) -> Result<Color> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() != 6 {
        bail!("expected #RRGGBB, got {hex}");
    }
    let r = u8::from_str_radix(&h[0..2], 16)?;
    let g = u8::from_str_radix(&h[2..4], 16)?;
    let b = u8::from_str_radix(&h[4..6], 16)?;
    Ok(Color::from_rgba8(r, g, b, 255))
}

pub fn metres_per_px(bounds: TileBounds) -> f64 {
    (bounds.maxx - bounds.minx) / f64::from(TILE_SIZE_PX)
}

/// Convert EPSG:3857 map metres → pixels for a single 256 px tile extent.
pub fn metres_to_px(metres: f64, bounds: TileBounds) -> f32 {
    (metres / metres_per_px(bounds)) as f32
}

/// QGIS `@mercator_scale` = 1/cos(φ) from tile mid-latitude (Web Mercator).
pub fn mercator_scale(bounds: TileBounds) -> f64 {
    let mid_y = (bounds.miny + bounds.maxy) * 0.5;
    // Inverse Web Mercator: φ = atan(sinh(y / R)), R = ORIGIN_SHIFT / π
    let lat_rad = (mid_y / (ORIGIN_SHIFT / std::f64::consts::PI)).sinh().atan();
    1.0 / lat_rad.cos()
}

/// Ground metres (OSM attributes) → pixels, matching QGIS `MapUnit * @mercator_scale`.
#[allow(dead_code)]
pub fn ground_metres_to_px(ground_m: f64, bounds: TileBounds) -> f32 {
    metres_to_px(ground_m * mercator_scale(bounds), bounds)
}
