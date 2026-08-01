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

pub fn metres_to_px(metres: f64, bounds: TileBounds) -> f32 {
    (metres / metres_per_px(bounds)) as f32
}
