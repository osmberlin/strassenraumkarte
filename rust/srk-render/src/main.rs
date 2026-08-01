//! PostGIS → XYZ PNG renderer for Straßenraumkarte evaluation.
//!
//! Presets:
//! - `highway_area` — isolate SimpleFill class rules (parity smoke)
//! - `full-approx` — landuse/water/roads/buildings(+drop-shadow)/trees stack (RasterFill v1; no labels/SVG)
//!
//! Tile math matches `render/xyz_tiles.py` (ORIGIN_SHIFT, 256 px, EPSG:3857,
//! background `#ededed`).

mod layers;
mod paint;
mod palette;
mod textures;
mod tile;
mod tree_markers;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{bail, Context, Result};
use clap::Parser;
use postgres::{Client, Config, NoTls};
use serde::Serialize;

use layers::{render_full_approx, render_highway_area, LayerPreset, TableCache};
use textures::TextureCatalog;
use tree_markers::TreeMarkerCatalog;
use tile::{enumerate_bbox_tiles, parse_bbox, parse_tile_spec};

#[derive(Parser, Debug)]
#[command(
    name = "srk-render",
    about = "Rust XYZ tile renderer (highway_area isolate | full-approx)"
)]
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

    /// Layer preset: `full-approx` (default) or `highway_area` isolate.
    #[arg(long = "layers", default_value = "full-approx", value_delimiter = ',')]
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
struct ZoomTiming {
    tiles: usize,
    wall_ms: u64,
    ms_per_tile: f64,
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
    /// Per-zoom breakdown (keys as decimal zoom strings for stable JSON).
    by_zoom: BTreeMap<String, ZoomTiming>,
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
        bail!("only --format png is supported");
    }

    let preset = LayerPreset::parse(&cli.layers)?;
    let (tiles, bbox) = collect_tiles(&cli)?;
    let tile_count = tiles.len();

    let mut client = connect(&cli)?;
    fs::create_dir_all(&cli.out)?;

    let mut table_cache = if preset == LayerPreset::FullApprox {
        Some(TableCache::probe(&mut client)?)
    } else {
        None
    };
    let texture_catalog = TextureCatalog::load()?;
    let tree_markers = TreeMarkerCatalog::load().unwrap_or_else(|e| {
        eprintln!("warn: {e:#}; using procedural tree crowns");
        TreeMarkerCatalog::fallback()
    });

    let started = Instant::now();
    let mut tiles_written = 0usize;
    let mut zoom_wall_ms: BTreeMap<u32, u64> = BTreeMap::new();
    let mut zoom_tiles: BTreeMap<u32, usize> = BTreeMap::new();
    let mut zoom_started = Instant::now();
    let mut current_z: Option<u32> = None;
    for (z, x, y) in tiles {
        if current_z != Some(z) {
            if let Some(prev) = current_z {
                let elapsed = zoom_started.elapsed().as_millis() as u64;
                *zoom_wall_ms.entry(prev).or_insert(0) += elapsed;
                if !cli.quiet {
                    let n = *zoom_tiles.get(&prev).unwrap_or(&0);
                    let ms = *zoom_wall_ms.get(&prev).unwrap_or(&0);
                    eprintln!(
                        "zoom done: z{prev} tiles={n} wall_ms={ms} ms_per_tile={:.2}",
                        if n > 0 {
                            ms as f64 / n as f64
                        } else {
                            0.0
                        }
                    );
                }
            }
            current_z = Some(z);
            zoom_started = Instant::now();
        }
        let out_path = cli.out.join(format!("{z}/{x}/{y}.png"));
        match preset {
            LayerPreset::HighwayArea => {
                render_highway_area(
                    &mut client,
                    z,
                    x,
                    y,
                    &out_path,
                    cli.quiet,
                    &texture_catalog,
                )?;
            }
            LayerPreset::FullApprox => {
                let cache = table_cache.as_mut().expect("table cache");
                render_full_approx(
                    &mut client,
                    z,
                    x,
                    y,
                    &out_path,
                    cli.quiet,
                    cache,
                    &texture_catalog,
                    &tree_markers,
                )?;
            }
        }
        tiles_written += 1;
        *zoom_tiles.entry(z).or_insert(0) += 1;
        // Progress every 500 tiles even when quiet (large bbox benches).
        if tiles_written % 500 == 0 {
            let elapsed = started.elapsed().as_millis() as u64;
            eprintln!(
                "progress: {tiles_written}/{tile_count} wall_ms={elapsed} (~{:.1} ms/tile)",
                elapsed as f64 / tiles_written as f64
            );
        }
    }
    if let Some(prev) = current_z {
        let elapsed = zoom_started.elapsed().as_millis() as u64;
        *zoom_wall_ms.entry(prev).or_insert(0) += elapsed;
        if !cli.quiet {
            let n = *zoom_tiles.get(&prev).unwrap_or(&0);
            let ms = *zoom_wall_ms.get(&prev).unwrap_or(&0);
            eprintln!(
                "zoom done: z{prev} tiles={n} wall_ms={ms} ms_per_tile={:.2}",
                if n > 0 {
                    ms as f64 / n as f64
                } else {
                    0.0
                }
            );
        }
    }
    let wall_ms = started.elapsed().as_millis() as u64;
    let ms_per_tile = if tile_count > 0 {
        wall_ms as f64 / tile_count as f64
    } else {
        0.0
    };

    let mut by_zoom = BTreeMap::new();
    for (z, n) in &zoom_tiles {
        let ms = *zoom_wall_ms.get(z).unwrap_or(&0);
        by_zoom.insert(
            z.to_string(),
            ZoomTiming {
                tiles: *n,
                wall_ms: ms,
                ms_per_tile: if *n > 0 {
                    ms as f64 / *n as f64
                } else {
                    0.0
                },
            },
        );
    }

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
        by_zoom,
    };

    eprintln!(
        "timing: engine=srk-render preset={preset:?} tiles={tile_count} wall_ms={wall_ms} ms_per_tile={ms_per_tile:.2}"
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
