//! Minimal PostGIS → XYZ PNG renderer for the `highway_area` vertical slice.
//!
//! Tile math matches `render/xyz_tiles.py` (`ORIGIN_SHIFT`, 256 px, EPSG:3857,
//! background `#ededed`). No effects, labels, or SVG.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::Parser;
use geo_types::{Coord, Geometry, LineString, MultiPolygon, Polygon};
use postgres::{Client, Config, NoTls};
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};
use wkb::WKBReadExt;

/// Same constant as `render/xyz_tiles.py`.
const ORIGIN_SHIFT: f64 = 20_037_508.342_789_244;
const TILE_SIZE_PX: u32 = 256;
const DEFAULT_BACKGROUND: &str = "#ededed";

#[derive(Parser, Debug)]
#[command(name = "srk-render", about = "Rust XYZ tile renderer (highway_area slice)")]
struct Cli {
    /// Tile specs `z/x/y` (repeatable or comma-separated).
    #[arg(long = "tiles", required = true, value_delimiter = ',')]
    tiles: Vec<String>,

    /// Layer isolates (only `highway_area` supported in this slice).
    #[arg(long = "layers", default_value = "highway_area", value_delimiter = ',')]
    layers: Vec<String>,

    /// Output directory (writes `{z}/{x}/{y}.png`).
    #[arg(long, default_value = "/tmp/srk-one-tile-cand")]
    out: PathBuf,

    /// Image format (only `png` for now).
    #[arg(long, default_value = "png")]
    format: String,

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

#[derive(Clone, Copy, Debug)]
struct TileBounds {
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
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

/// QGIS / MapLibre highway_area class fills (flat, no texture overlay).
fn fill_for_area_highway(area: Option<&str>) -> Color {
    let hex = match area.unwrap_or("") {
        "footway" | "path" | "steps" | "bridleway" => "#e1e3bd",
        "pedestrian" => "#d7d8c5",
        "cycleway" | "service" => "#cccccc",
        "living_street" => "#bbbbb2",
        "parking" | "parking_space" => "#a8a8a7",
        "motorway" | "trunk" | "motorway_link" | "trunk_link" | "primary" | "primary_link"
        | "secondary" | "secondary_link" | "tertiary" | "tertiary_link" | "residential"
        | "unclassified" | "road" | "bus_guideway" | "bus_bay" | "turning_circle"
        | "turning_loop" => "#a8a8a7",
        _ => "#a8a8a7",
    };
    parse_hex_color(hex).expect("static palette hex")
}

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

fn render_highway_area(client: &mut Client, z: u32, x: u32, y: u32, out_path: &Path) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX).context("pixmap alloc")?;
    pixmap.fill(parse_hex_color(DEFAULT_BACKGROUND)?);

    let rows = client.query(
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
          AND NOT ST_IsEmpty(
            ST_ClipByBox2D(
              geom,
              ST_MakeEnvelope($1::float8, $2::float8, $3::float8, $4::float8, 3857)
            )
          )
        ORDER BY COALESCE(layer, 0), osm_id
        "#,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;

    let mut painted = 0usize;
    for row in &rows {
        let area: Option<String> = row.get("area_highway");
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
        fill_paint.set_color(fill_for_area_highway(area.as_deref()));
        fill_paint.anti_alias = true;

        // Optional hairline outline (QGIS SimpleFill often has a dark outline colour).
        let mut stroke_paint = Paint::default();
        stroke_paint.set_color_rgba8(0x5a, 0x5a, 0x5a, 0xFF);
        stroke_paint.anti_alias = true;
        let stroke = Stroke {
            width: 0.5,
            ..Stroke::default()
        };

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
            pixmap.stroke_path(&path, &stroke_paint, &stroke, Transform::identity(), None);
            painted += 1;
        }
    }

    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent)?;
    }
    pixmap.save_png(out_path)?;
    eprintln!(
        "rendered {z}/{x}/{y} → {} ({} polygon parts, {} features)",
        out_path.display(),
        painted,
        rows.len()
    );
    Ok(())
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

    let mut tiles = Vec::new();
    for spec in &cli.tiles {
        for part in spec.split(',') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            tiles.push(parse_tile_spec(part)?);
        }
    }
    if tiles.is_empty() {
        bail!("no tiles given");
    }

    let mut client = connect(&cli)?;
    fs::create_dir_all(&cli.out)?;

    for (z, x, y) in tiles {
        let out_path = cli.out.join(format!("{z}/{x}/{y}.png"));
        render_highway_area(&mut client, z, x, y, &out_path)?;
    }
    Ok(())
}
