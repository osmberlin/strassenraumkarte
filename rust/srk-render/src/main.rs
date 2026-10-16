//! PostGIS → XYZ raster renderer for Straßenraumkarte evaluation.
//!
//! Presets:
//! - `highway_area` — isolate SimpleFill class rules (parity smoke)
//! - `full-approx` — landuse/water/roads/buildings(+drop-shadow)/trees stack (RasterFill v1; no labels/SVG)
//!
//! Default output is **WebP** (lossy q90). Use `--format jpg` for QGIS-like JPEG,
//! `--format png` only for regression harness pixelmatch. Tile math matches
//! `render/xyz_tiles.py` (ORIGIN_SHIFT, 256 px, EPSG:3857, background `#ededed`).

mod furniture_a;
mod furniture_batch_b;
mod layers;
mod paint;
mod palette;
mod pitch_markings;
mod profile;
mod roof_shapes;
mod sql_cache;
mod style_ink;
mod style_kit;
mod style_la;
mod svg_stamps;
mod textures;
mod tile;
mod tree_markers;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use anyhow::{bail, Context, Result};
use clap::Parser;
use postgres::{Client, Config, NoTls};
use serde::Serialize;

use layers::{render_full_approx, render_highway_area, render_style, LayerPreset, TableCache};
use pitch_markings::PitchMarkingCatalog;
use profile::{StageProfile, StageTimers};
use sql_cache::PreparedCache;
use svg_stamps::SvgStampCatalog;
use textures::TextureCatalog;
use tile::{
    enumerate_bbox_metatiles, meta_tile_core_count, metatile_for_single_tile, parse_bbox,
    parse_tile_spec, MetaTile,
};
use tree_markers::TreeMarkerCatalog;

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

    /// Output directory (writes `{z}/{x}/{y}.{webp|png}`).
    #[arg(long, default_value = "/tmp/srk-one-tile-cand")]
    out: PathBuf,

    /// Image format: `webp` (default, live), `jpg` (live, QGIS-like), or `png` (harness only).
    #[arg(long, default_value = "webp")]
    format: String,

    /// Lossy quality 0–100 for webp/jpg (ignored for PNG). Default 90.
    #[arg(long, default_value_t = 90.0)]
    quality: f32,

    /// Suppress per-tile progress on stderr.
    #[arg(long)]
    quiet: bool,

    /// Write `timing.json` next to `--out` (default: on for `--bbox`).
    #[arg(long)]
    timing_json: bool,

    /// Per-stage timing breakdown (sql/paint/shapeburst/shadow/encode) in timing.json + stderr.
    #[arg(long)]
    profile: bool,

    /// Parallel metatile workers (each opens its own DB connection). Default 1 for harness stability;
    /// use 4–8 for large bbox benches (`SRK_WORKERS` env override).
    #[arg(long, env = "SRK_WORKERS", default_value_t = 1)]
    workers: usize,

    /// Metatile core size (default 1 for harness; farm benches use 8).
    #[arg(long, default_value_t = 1)]
    metatile: u32,

    /// Extra tiles around each core tile for symbol/shadow bleed (QGIS gutter).
    /// Rendered then cropped. Default 0 for farm throughput; use `--gutter 1` to match QGIS edge bleed.
    #[arg(long, default_value_t = 0)]
    gutter: u32,

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
    quality: Option<f32>,
    layers: Vec<String>,
    workers: usize,
    metatile: u32,
    gutter: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    stages: Option<StageProfile>,
    /// Per-zoom breakdown (keys as decimal zoom strings for stable JSON).
    by_zoom: BTreeMap<String, ZoomTiming>,
}

struct MetaJob {
    mt: MetaTile,
}

struct MetaResult {
    z: u32,
    cores: usize,
    wall_ms: u64,
    stages: StageTimers,
}

struct SharedState {
    preset: LayerPreset,
    table_cache: Option<Arc<TableCache>>,
    texture_catalog: Arc<TextureCatalog>,
    tree_markers: Arc<TreeMarkerCatalog>,
    pitch_markings: Arc<PitchMarkingCatalog>,
    svg_stamps: Arc<SvgStampCatalog>,
    webp_quality: f32,
    profile: bool,
    format_ext: String,
    out_dir: PathBuf,
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

fn collect_metatiles(cli: &Cli) -> Result<(Vec<MetaTile>, Option<String>)> {
    match (&cli.tiles, &cli.bbox) {
        (Some(_), Some(_)) => bail!("provide exactly one of --tiles or --bbox"),
        (None, None) => bail!("provide --tiles or --bbox"),
        (Some(specs), None) => {
            let mut metas = Vec::new();
            for spec in specs {
                for part in spec.split(',') {
                    let part = part.trim();
                    if part.is_empty() {
                        continue;
                    }
                    let (z, x, y) = parse_tile_spec(part)?;
                    metas.push(metatile_for_single_tile(z, x, y, cli.gutter));
                }
            }
            if metas.is_empty() {
                bail!("no tiles parsed from --tiles");
            }
            Ok((metas, None))
        }
        (None, Some(bbox_spec)) => {
            if cli.zmin > cli.zmax {
                bail!("--zmin must be <= --zmax");
            }
            let (xmin, ymin, xmax, ymax) = parse_bbox(bbox_spec)?;
            let metas = enumerate_bbox_metatiles(
                xmin,
                ymin,
                xmax,
                ymax,
                cli.zmin,
                cli.zmax,
                cli.metatile,
                cli.gutter,
            );
            if metas.is_empty() {
                bail!("--bbox produced no metatiles for z{}-{}", cli.zmin, cli.zmax);
            }
            Ok((metas, Some(bbox_spec.clone())))
        }
    }
}

fn normalize_format(raw: &str) -> Result<&'static str> {
    match raw.to_ascii_lowercase().as_str() {
        "webp" => Ok("webp"),
        "png" => Ok("png"),
        "jpg" | "jpeg" => Ok("jpg"),
        other => bail!("unsupported --format {other} (use webp, png, or jpg)"),
    }
}

fn render_one_metatile(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    shared: &SharedState,
    mt: MetaTile,
    quiet: bool,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    match shared.preset {
        LayerPreset::HighwayArea => render_highway_area(
            client,
            prep_cache,
            mt,
            &shared.out_dir,
            &shared.format_ext,
            quiet,
            shared.texture_catalog.as_ref(),
            shared.webp_quality,
            timers,
        ),
        LayerPreset::FullApprox => {
            let cache = shared
                .table_cache
                .as_ref()
                .expect("table cache for full-approx");
            render_full_approx(
                client,
                prep_cache,
                mt,
                &shared.out_dir,
                &shared.format_ext,
                quiet,
                cache.as_ref(),
                shared.texture_catalog.as_ref(),
                shared.tree_markers.as_ref(),
                shared.pitch_markings.as_ref(),
                shared.svg_stamps.as_ref(),
                shared.webp_quality,
                timers,
            )
        }
        LayerPreset::La | LayerPreset::Ink | LayerPreset::Roofs => render_style(
            client,
            prep_cache,
            mt,
            &shared.out_dir,
            &shared.format_ext,
            quiet,
            shared.preset,
            shared.webp_quality,
            timers,
        ),
    }
}

fn worker_loop(
    cli: Cli,
    rx: Arc<Mutex<Receiver<MetaJob>>>,
    shared: Arc<SharedState>,
    results: Sender<MetaResult>,
) {
    let mut client = match connect(&cli) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("worker connect failed: {e:#}");
            return;
        }
    };
    let mut prep_cache = PreparedCache::default();
    loop {
        let job = {
            let guard = rx.lock().expect("job queue mutex");
            match guard.recv() {
                Ok(j) => j,
                Err(_) => break,
            }
        };
        let started = Instant::now();
        let mut meta_timers = StageTimers::default();
        let mut timer_slot = if shared.profile {
            Some(&mut meta_timers)
        } else {
            None
        };
        let cores = render_one_metatile(
            &mut client,
            &mut prep_cache,
            shared.as_ref(),
            job.mt,
            true,
            &mut timer_slot,
        )
        .unwrap_or_else(|e| {
            eprintln!(
                "metatile z{} cores {}x{}-{}x{} failed: {e:#}",
                job.mt.z,
                job.mt.x0,
                job.mt.y0,
                job.mt.x1,
                job.mt.y1
            );
            0
        });
        let _ = results.send(MetaResult {
            z: job.mt.z,
            cores,
            wall_ms: started.elapsed().as_millis() as u64,
            stages: meta_timers,
        });
    }
}

fn run_sequential(
    cli: &Cli,
    shared: &SharedState,
    metas: &[MetaTile],
    core_tile_count: usize,
) -> Result<(usize, BTreeMap<u32, u64>, BTreeMap<u32, usize>, StageTimers)> {
    let mut client = connect(cli)?;
    let mut prep_cache = PreparedCache::default();
    let started = Instant::now();
    let mut tiles_written = 0usize;
    let mut zoom_wall_ms: BTreeMap<u32, u64> = BTreeMap::new();
    let mut zoom_tiles: BTreeMap<u32, usize> = BTreeMap::new();
    let mut total_stages = StageTimers::default();

    for mt in metas {
        let meta_started = Instant::now();
        let mut meta_timers = StageTimers::default();
        let mut timer_slot = if cli.profile {
            Some(&mut meta_timers)
        } else {
            None
        };
        let cores = render_one_metatile(
            &mut client,
            &mut prep_cache,
            shared,
            *mt,
            cli.quiet,
            &mut timer_slot,
        )?;
        if cli.profile {
            total_stages.merge(&meta_timers);
        }
        tiles_written += cores;
        *zoom_tiles.entry(mt.z).or_insert(0) += cores;
        *zoom_wall_ms.entry(mt.z).or_insert(0) += meta_started.elapsed().as_millis() as u64;

        if tiles_written % 500 == 0 {
            let elapsed = started.elapsed().as_millis() as u64;
            eprintln!(
                "progress: {tiles_written}/{core_tile_count} wall_ms={elapsed} (~{:.1} ms/tile)",
                elapsed as f64 / tiles_written as f64
            );
        }
    }

    if !cli.quiet {
        for (z, n) in &zoom_tiles {
            let ms = *zoom_wall_ms.get(z).unwrap_or(&0);
            eprintln!(
                "zoom done: z{z} tiles={n} wall_ms={ms} ms_per_tile={:.2}",
                if *n > 0 {
                    ms as f64 / *n as f64
                } else {
                    0.0
                }
            );
        }
    }

    Ok((tiles_written, zoom_wall_ms, zoom_tiles, total_stages))
}

fn run_parallel(
    cli: &Cli,
    shared: Arc<SharedState>,
    metas: &[MetaTile],
    workers: usize,
    core_tile_count: usize,
) -> Result<(usize, BTreeMap<u32, u64>, BTreeMap<u32, usize>, StageTimers)> {
    let (job_tx, job_rx) = mpsc::channel::<MetaJob>();
    let (result_tx, result_rx) = mpsc::channel::<MetaResult>();
    let job_rx = Arc::new(Mutex::new(job_rx));

    let mut handles = Vec::new();
    for _ in 0..workers {
        let rx = Arc::clone(&job_rx);
        let tx = result_tx.clone();
        let cli_clone = Cli {
            tiles: cli.tiles.clone(),
            bbox: cli.bbox.clone(),
            zmin: cli.zmin,
            zmax: cli.zmax,
            layers: cli.layers.clone(),
            out: cli.out.clone(),
            format: cli.format.clone(),
            quality: cli.quality,
            quiet: cli.quiet,
            timing_json: cli.timing_json,
            profile: cli.profile,
            workers: cli.workers,
            metatile: cli.metatile,
            gutter: cli.gutter,
            db_host: cli.db_host.clone(),
            db_port: cli.db_port,
            db_user: cli.db_user.clone(),
            db_name: cli.db_name.clone(),
            db_password: cli.db_password.clone(),
            database_url: cli.database_url.clone(),
        };
        let shared_clone = Arc::clone(&shared);
        handles.push(thread::spawn(move || {
            worker_loop(cli_clone, rx, shared_clone, tx);
        }));
    }
    drop(result_tx);

    for mt in metas {
        job_tx.send(MetaJob { mt: *mt })?;
    }
    drop(job_tx);

    let started = Instant::now();
    let mut zoom_wall_ms: BTreeMap<u32, u64> = BTreeMap::new();
    let mut zoom_tiles: BTreeMap<u32, usize> = BTreeMap::new();
    let mut total_stages = StageTimers::default();
    let mut tiles_written = 0usize;

    for _ in 0..metas.len() {
        let result = result_rx.recv().context("worker result channel closed")?;
        tiles_written += result.cores;
        *zoom_tiles.entry(result.z).or_insert(0) += result.cores;
        *zoom_wall_ms.entry(result.z).or_insert(0) += result.wall_ms;
        total_stages.merge(&result.stages);

        if tiles_written % 500 == 0 {
            let elapsed = started.elapsed().as_millis() as u64;
            eprintln!(
                "progress: {tiles_written}/{core_tile_count} wall_ms={elapsed} (~{:.1} ms/tile)",
                elapsed as f64 / tiles_written as f64
            );
        }
    }

    for handle in handles {
        let _ = handle.join();
    }

    Ok((tiles_written, zoom_wall_ms, zoom_tiles, total_stages))
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.metatile < 1 || cli.metatile > 16 {
        bail!("--metatile must be between 1 and 16 (got {})", cli.metatile);
    }
    if cli.gutter > 4 {
        bail!("--gutter {} is too large (max 4)", cli.gutter);
    }
    if cli.workers == 0 {
        bail!("--workers must be >= 1");
    }

    let format = normalize_format(&cli.format)?;
    if !(0.0..=100.0).contains(&cli.quality) {
        bail!("--quality must be between 0 and 100");
    }

    let preset = LayerPreset::parse(&cli.layers)?;
    let (metas, bbox) = collect_metatiles(&cli)?;
    let core_tile_count = meta_tile_core_count(&metas);
    let meta_count = metas.len();

    if cli.tiles.is_some() && cli.metatile != 1 && !cli.quiet {
        eprintln!(
            "note: --tiles uses one metatile per tile; --metatile {} is ignored",
            cli.metatile
        );
    }

    fs::create_dir_all(&cli.out)?;

    let table_cache = if preset == LayerPreset::FullApprox {
        let mut client = connect(&cli)?;
        Some(Arc::new(TableCache::probe(&mut client)?))
    } else {
        None
    };
    let texture_catalog = Arc::new(TextureCatalog::load()?);
    let tree_markers = Arc::new(
        TreeMarkerCatalog::load().unwrap_or_else(|e| {
            eprintln!("warn: {e:#}; using procedural tree crowns");
            TreeMarkerCatalog::fallback()
        }),
    );
    let pitch_markings = Arc::new(
        PitchMarkingCatalog::load().unwrap_or_else(|e| {
            eprintln!("warn: {e:#}; pitch markings disabled");
            PitchMarkingCatalog::fallback()
        }),
    );
    let svg_stamps = Arc::new(
        SvgStampCatalog::load().unwrap_or_else(|e| {
            eprintln!("warn: {e:#}; traffic-sign stamps disabled");
            SvgStampCatalog::fallback()
        }),
    );

    let shared = Arc::new(SharedState {
        preset,
        table_cache,
        texture_catalog,
        tree_markers,
        pitch_markings,
        svg_stamps,
        webp_quality: cli.quality,
        profile: cli.profile,
        format_ext: format.to_string(),
        out_dir: cli.out.clone(),
    });

    let started = Instant::now();
    let (tiles_written, zoom_wall_ms, zoom_tiles, total_stages) = if cli.workers > 1 {
        run_parallel(
            &cli,
            Arc::clone(&shared),
            &metas,
            cli.workers,
            core_tile_count,
        )?
    } else {
        run_sequential(&cli, shared.as_ref(), &metas, core_tile_count)?
    };
    let wall_ms = started.elapsed().as_millis() as u64;
    let ms_per_tile = if core_tile_count > 0 {
        wall_ms as f64 / core_tile_count as f64
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
    let stages = if cli.profile {
        Some(StageProfile::from(total_stages))
    } else {
        None
    };

    let summary = TimingSummary {
        engine: "srk-render",
        scope,
        bbox: bbox.clone(),
        zmin: bbox.as_ref().map(|_| cli.zmin),
        zmax: bbox.as_ref().map(|_| cli.zmax),
        tiles: core_tile_count,
        tiles_written,
        wall_ms,
        ms_per_tile,
        format: format.to_string(),
        quality: if format == "png" {
            None
        } else {
            Some(cli.quality)
        },
        layers: cli.layers.clone(),
        workers: cli.workers,
        metatile: cli.metatile,
        gutter: cli.gutter,
        stages: stages.clone(),
        by_zoom,
    };

    eprintln!(
        "timing: engine=srk-render preset={preset:?} metatiles={meta_count} core_tiles={core_tile_count} workers={} wall_ms={wall_ms} ms_per_tile={ms_per_tile:.2}",
        cli.workers
    );
    if let Some(ref s) = stages {
        eprintln!(
            "stages: sql_ms={} paint_ms={} shapeburst_ms={} shadow_ms={} encode_ms={}",
            s.sql_ms, s.paint_ms, s.shapeburst_ms, s.shadow_ms, s.encode_ms
        );
    }

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
