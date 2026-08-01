//! Minimal PostGIS → XYZ PNG renderer for the `highway_area` vertical slice.
//!
//! Tile math matches `render/xyz_tiles.py` (`ORIGIN_SHIFT`, 256 px, EPSG:3857,
//! background `#ededed`). No effects, labels, or SVG.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use clap::Parser;
use serde::Serialize;
use geo_types::{Coord, Geometry, LineString, MultiPolygon, Polygon};
use postgres::{Client, Config, NoTls};
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Transform};
use wkb::WKBReadExt;

/// Same constant as `render/xyz_tiles.py`.
const ORIGIN_SHIFT: f64 = 20_037_508.342_789_244;
const TILE_SIZE_PX: u32 = 256;
const DEFAULT_BACKGROUND: &str = "#ededed";

#[derive(Parser, Debug)]
#[command(name = "srk-render", about = "Rust XYZ tile renderer (highway_area slice)")]
struct Cli {
    /// Tile specs `z/x/y` (repeatable or comma-separated). Omit when using `--bbox`.
    #[arg(long = "tiles", value_delimiter = ',')]
    tiles: Option<Vec<String>>,

    /// WGS84 extent `xmin,ymin,xmax,ymax` — enumerate XYZ tiles for `--zmin`..`--zmax`.
    #[arg(long = "bbox")]
    bbox: Option<String>,

    /// Minimum zoom when using `--bbox` (inclusive).
    #[arg(long = "zmin", default_value_t = 15)]
    zmin: u32,

    /// Maximum zoom when using `--bbox` (inclusive).
    #[arg(long = "zmax", default_value_t = 18)]
    zmax: u32,

    /// Layer isolates (only `highway_area` supported in this slice).
    #[arg(long = "layers", default_value = "highway_area", value_delimiter = ',')]
    layers: Vec<String>,

    /// Output directory (writes `{z}/{x}/{y}.png`).
    #[arg(long, default_value = "/tmp/srk-one-tile-cand")]
    out: PathBuf,

    /// Image format (only `png` for now).
    #[arg(long, default_value = "png")]
    format: String,

    /// Suppress per-tile progress on stderr.
    #[arg(long)]
    quiet: bool,

    /// Write `timing.json` next to `--out` (default: on for `--bbox`).
    #[arg(long)]
    timing_json: bool,

    #[arg(long, env = "DB_HOST", default_value = "localhost")]
    db_host: String,
    #[arg(long, env = "DB_PORT", default_value = "5433")]
    db_port: u16,
    #[arg(long, env = "DB_USER", default_value = "postgres")]
    db_user: String,
    #[arg(long, env = "DB_NAME", default_value = "strassenraumkarte")]
    db_name: String,
    #[arg(long, env = "PGPASSWORD")]
    db_password: Option<String>,
    /// Full postgres URL overrides host/port/user/name when set.
    #[arg(long, env = "DATABASE_URL")]
    database_url: Option<String>,
}

#[derive(Serialize)]
struct TimingSummary {
    engine: &'static str,
    scope: String,
    bbox: Option<String>,
    zmin: Option<u32>,
    zmax: Option<u32>,
    tiles: usize,
    tiles_written: usize,
    wall_ms: u64,
    ms_per_tile: f64,
    format: String,
    layers: Vec<String>,
}

#[derive(Clone, Copy, Debug)]
struct TileRange {
    x0: u32,
    x1: u32,
    y0: u32,
    y1: u32,
}

#[derive(Clone, Copy, Debug)]
struct TileBounds {
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
}

fn clamp_lat(lat: f64) -> f64 {
    lat.clamp(-85.051_128_78, 85.051_128_78)
}

/// Port of `lon_to_tile_x` in `render/xyz_tiles.py`.
fn lon_to_tile_x(lon: f64, z: u32) -> u32 {
    let n = 2f64.powi(z as i32);
    let x = ((lon + 180.0) / 360.0 * n).floor() as i64;
    x.clamp(0, (n as i64) - 1) as u32
}

/// Port of `lat_to_tile_y` in `render/xyz_tiles.py`.
fn lat_to_tile_y(lat: f64, z: u32) -> u32 {
    let lat = clamp_lat(lat);
    let lat_rad = lat.to_radians();
    let n = 2f64.powi(z as i32);
    let y = ((1.0 - (lat_rad.tan().asinh() / std::f64::consts::PI)) / 2.0 * n).floor() as i64;
    y.clamp(0, (n as i64) - 1) as u32
}

/// Port of `tile_range_for_bbox` in `render/xyz_tiles.py`.
fn tile_range_for_bbox(xmin: f64, ymin: f64, xmax: f64, ymax: f64, z: u32) -> TileRange {
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

fn parse_bbox(spec: &str) -> Result<(f64, f64, f64, f64)> {
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

fn enumerate_bbox_tiles(
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

fn parse_tile_spec(spec: &str) -> Result<(u32, u32, u32)> {
    let parts: Vec<_> = spec.trim().split('/').collect();
    if parts.len() != 3 {
        bail!("tile spec must be z/x/y, got {spec}");
    }
    Ok((parts[0].parse()?, parts[1].parse()?, parts[2].parse()?))
}

/// Port of `tile_bounds_3857` in `render/xyz_tiles.py`.
fn tile_bounds_3857(x: u32, y: u32, z: u32) -> TileBounds {
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

fn parse_hex_color(hex: &str) -> Result<Color> {
    let h = hex.trim().trim_start_matches('#');
    if h.len() != 6 {
        bail!("expected #RRGGBB, got {hex}");
    }
    let r = u8::from_str_radix(&h[0..2], 16)?;
    let g = u8::from_str_radix(&h[2..4], 16)?;
    let b = u8::from_str_radix(&h[4..6], 16)?;
    Ok(Color::from_rgba8(r, g, b, 255))
}

/// QGIS rule-based class fills for `highway_area` (SimpleFill only; no RasterFill textures).
///
/// Values mirror the checked rule filters in `style/strassenraumkarte.qgz` — see
/// `audit/tile-regression/HIGHWAY_AREA_RULES.md`. Classes outside this set are not painted
/// (no ELSE rule in QGIS). Outline width is 0 in QGIS, so we fill only.
fn fill_for_area_highway(area: Option<&str>) -> Option<Color> {
    let hex = match area? {
        "footway" | "path" | "steps" | "bridleway" => "#e1e3bd",
        "pedestrian" => "#d7d8c5",
        "cycleway" | "service" => "#cccccc",
        "living_street" => "#bbbbb2",
        // QGIS paints `parking` only — not `parking_space` / `traffic_island`.
        "parking" => "#a8a8a7",
        "motorway" | "trunk" | "motorway_link" | "trunk_link" | "primary" | "primary_link"
        | "secondary" | "secondary_link" | "tertiary" | "tertiary_link" | "residential"
        | "unclassified" | "road" | "bus_guideway" | "bus_bay" | "turning_circle"
        | "turning_loop" => "#a8a8a7",
        _ => return None,
    };
    Some(parse_hex_color(hex).expect("static palette hex"))
}

/// Union of QGIS class-fill `area:highway` filters (SQL `IN` list).
const AREA_HIGHWAY_PAINTED: &str = "(\
  'footway','path','steps','bridleway',\
  'pedestrian','cycleway','service','parking','living_street',\
  'primary','primary_link','secondary','secondary_link',\
  'tertiary','tertiary_link','residential','unclassified','road',\
  'bus_guideway','bus_bay','turning_circle','turning_loop',\
  'motorway','trunk','motorway_link','trunk_link'\
)";

fn connect(cli: &Cli) -> Result<Client> {
    if let Some(url) = &cli.database_url {
        return Client::connect(url, NoTls).context("connect via DATABASE_URL");
    }
    let password = cli
        .db_password
        .clone()
        .or_else(|| std::env::var("PGPASSWORD").ok())
        .unwrap_or_else(|| "postgres".into());
    Config::new()
        .host(&cli.db_host)
        .port(cli.db_port)
        .user(&cli.db_user)
        .dbname(&cli.db_name)
        .password(password)
        .connect(NoTls)
        .with_context(|| {
            format!(
                "connect to {}:{}/{}",
                cli.db_host, cli.db_port, cli.db_name
            )
        })
}

fn map_to_px(bounds: TileBounds, c: Coord<f64>) -> (f32, f32) {
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

fn polygon_to_path(bounds: TileBounds, poly: &Polygon<f64>) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    ring_to_path(&mut pb, bounds, poly.exterior(), true);
    for hole in poly.interiors() {
        ring_to_path(&mut pb, bounds, hole, true);
    }
    pb.finish()
}

fn geometry_polygons(geom: Geometry<f64>) -> Vec<Polygon<f64>> {
    match geom {
        Geometry::Polygon(p) => vec![p],
        Geometry::MultiPolygon(MultiPolygon(ps)) => ps,
        Geometry::GeometryCollection(gc) => gc
            .0
            .into_iter()
            .flat_map(geometry_polygons)
            .collect(),
        _ => Vec::new(),
    }
}

fn decode_wkb(bytes: &[u8]) -> Result<Geometry<f64>> {
    let mut cursor = std::io::Cursor::new(bytes);
    cursor
        .read_wkb()
        .map_err(|e| anyhow::anyhow!("WKB decode failed: {e:?}"))
}

fn render_highway_area(
    client: &mut Client,
    z: u32,
    x: u32,
    y: u32,
    out_path: &Path,
    quiet: bool,
) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX).context("pixmap alloc")?;
    pixmap.fill(parse_hex_color(DEFAULT_BACKGROUND)?);

    // Filter matches QGIS rule union — see HIGHWAY_AREA_RULES.md.
    let sql = format!(
        r#"
        SELECT
          "area:highway" AS area_highway,
          ST_AsBinary(
            ST_CollectionExtract(
              ST_MakeValid(
                ST_ClipByBox2D(
                  geom,
                  ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)
                )
              ),
              3
            )
          ) AS wkb
        FROM highway_area
        WHERE geom && ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)
          AND "area:highway" IN {AREA_HIGHWAY_PAINTED}
          AND NOT ST_IsEmpty(
            ST_ClipByBox2D(
              geom,
              ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)
            )
          )
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;

    let mut painted = 0usize;
    for row in &rows {
        let area: Option<String> = row.get("area_highway");
        let Some(fill_color) = fill_for_area_highway(area.as_deref()) else {
            continue;
        };
        let wkb: Option<Vec<u8>> = row.get("wkb");
        let Some(wkb) = wkb else { continue };
        if wkb.is_empty() {
            continue;
        }
        let geom = match decode_wkb(&wkb) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("warn: skip feature WKB: {e:?}");
                continue;
            }
        };

        let mut fill_paint = Paint::default();
        fill_paint.set_color(fill_color);
        fill_paint.anti_alias = true;

        for poly in geometry_polygons(geom) {
            let Some(path) = polygon_to_path(bounds, &poly) else {
                continue;
            };
            pixmap.fill_path(
                &path,
                &fill_paint,
                FillRule::EvenOdd,
                Transform::identity(),
                None,
            );
            painted += 1;
        }
    }

    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent)?;
    }
    pixmap.save_png(out_path)?;
    if !quiet {
        eprintln!(
            "rendered {z}/{x}/{y} → {} ({} polygon parts, {} features)",
            out_path.display(),
            painted,
            rows.len()
        );
    }
    Ok(())
}

fn collect_tiles(cli: &Cli) -> Result<(Vec<(u32, u32, u32)>, Option<String>)> {
    match (&cli.tiles, &cli.bbox) {
        (Some(_), Some(_)) => bail!("provide exactly one of --tiles or --bbox"),
        (None, None) => bail!("provide --tiles or --bbox"),
        (Some(specs), None) => {
            let mut tiles = Vec::new();
            for spec in specs {
                for part in spec.split(',') {
                    let part = part.trim();
                    if part.is_empty() {
                        continue;
                    }
                    tiles.push(parse_tile_spec(part)?);
                }
            }
            if tiles.is_empty() {
                bail!("no tiles parsed from --tiles");
            }
            Ok((tiles, None))
        }
        (None, Some(bbox_spec)) => {
            if cli.zmin > cli.zmax {
                bail!("--zmin must be <= --zmax");
            }
            let (xmin, ymin, xmax, ymax) = parse_bbox(bbox_spec)?;
            let tiles = enumerate_bbox_tiles(xmin, ymin, xmax, ymax, cli.zmin, cli.zmax);
            if tiles.is_empty() {
                bail!("--bbox produced no tiles for z{}-{}", cli.zmin, cli.zmax);
            }
            Ok((tiles, Some(bbox_spec.clone())))
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.format.to_ascii_lowercase() != "png" {
        bail!("only --format png is supported in this slice");
    }

    let mut layers: HashMap<String, ()> = HashMap::new();
    for l in &cli.layers {
        layers.insert(l.trim().to_string(), ());
    }
    if !layers.contains_key("highway_area") || layers.len() != 1 {
        bail!(
            "this vertical slice only supports --layers highway_area (got {:?})",
            cli.layers
        );
    }

    let (tiles, bbox) = collect_tiles(&cli)?;
    let tile_count = tiles.len();

    let mut client = connect(&cli)?;
    fs::create_dir_all(&cli.out)?;

    let started = Instant::now();
    let mut tiles_written = 0usize;
    for (z, x, y) in tiles {
        let out_path = cli.out.join(format!("{z}/{x}/{y}.png"));
        render_highway_area(&mut client, z, x, y, &out_path, cli.quiet)?;
        tiles_written += 1;
    }
    let wall_ms = started.elapsed().as_millis() as u64;
    let ms_per_tile = if tile_count > 0 {
        wall_ms as f64 / tile_count as f64
    } else {
        0.0
    };

    let scope = if bbox.is_some() {
        format!("bbox z{}-{}", cli.zmin, cli.zmax)
    } else {
        "tiles".into()
    };
    let summary = TimingSummary {
        engine: "srk-render",
        scope,
        bbox: bbox.clone(),
        zmin: bbox.as_ref().map(|_| cli.zmin),
        zmax: bbox.as_ref().map(|_| cli.zmax),
        tiles: tile_count,
        tiles_written,
        wall_ms,
        ms_per_tile,
        format: cli.format.clone(),
        layers: cli.layers.clone(),
    };

    eprintln!(
        "timing: engine=srk-render tiles={tile_count} wall_ms={wall_ms} ms_per_tile={ms_per_tile:.2}"
    );

    let write_timing = cli.timing_json || bbox.is_some();
    if write_timing {
        let timing_path = cli.out.join("timing.json");
        if let Some(parent) = timing_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(&summary)?;
        fs::write(&timing_path, format!("{json}\n"))?;
        if !cli.quiet {
            eprintln!("wrote {}", timing_path.display());
        }
    }

    Ok(())
}
