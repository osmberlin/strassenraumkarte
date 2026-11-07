//! Unit tests for the design-research style kit (`style_kit.rs`).
//!
//! The presets `la` and `ink` must render identical pixels whatever the metatile layout:
//! every random choice is seeded from world coordinates (EPSG:3857) or OSM ids. These tests
//! pin that contract for the shared helpers without a database.
//!
//! `Ctx` holds a `&mut postgres::Client`, which the geometry helpers never use. The tests
//! build one against a tiny fake server on 127.0.0.1 that answers the startup handshake
//! and nothing else, so no PostGIS is needed.

use std::io::{Read, Write};
use std::net::TcpListener;

use postgres::{Client, NoTls};
use tiny_skia::{Color, Path, PathSegment, Pixmap};

use crate::sql_cache::PreparedCache;
use crate::style_kit::*;
use crate::tile::{crop_core_tile, iter_metatiles, RenderExtent, TileRange, TILE_SIZE_PX};

// ---------------------------------------------------------------- harness

/// A `postgres::Client` connected to a fake server that only completes the handshake.
fn fake_client() -> Client {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind fake pg");
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let Ok((mut s, _)) = listener.accept() else { return };
        let mut len = [0u8; 4];
        if s.read_exact(&mut len).is_err() {
            return;
        }
        let mut body = vec![0u8; (u32::from_be_bytes(len) as usize).saturating_sub(4)];
        if s.read_exact(&mut body).is_err() {
            return;
        }
        // AuthenticationOk, ReadyForQuery(idle)
        let _ = s.write_all(&[b'R', 0, 0, 0, 8, 0, 0, 0, 0, b'Z', 0, 0, 0, 5, b'I']);
        // hold the socket until the client hangs up
        let mut sink = [0u8; 256];
        while matches!(s.read(&mut sink), Ok(n) if n > 0) {}
    });
    Client::connect(&format!("host=127.0.0.1 port={port} user=test dbname=test sslmode=disable"), NoTls)
        .expect("connect to fake pg")
}

struct Harness {
    client: Client,
    prep: PreparedCache,
}

impl Harness {
    fn new() -> Self {
        Self { client: fake_client(), prep: PreparedCache::default() }
    }

    /// Same margin as `style_la::render` / `style_ink::render`.
    fn ctx(&mut self, extent: RenderExtent, z: u32) -> Ctx<'_> {
        Ctx { client: &mut self.client, prep: &mut self.prep, extent, z, margin_m: 40.0 }
    }
}

/// The two layouts `seam_check.sh` compares for tile z/x/y: `--metatile 1` and `--metatile 4`,
/// both with `--gutter 1`. Returns (single-tile extent, metatile extent).
fn layouts(z: u32, x: u32, y: u32) -> (RenderExtent, RenderExtent) {
    let single = RenderExtent::for_tile(x, y, z, 1);
    let tr = TileRange { x0: x / 4 * 4, x1: x / 4 * 4 + 3, y0: y / 4 * 4, y1: y / 4 * 4 + 3 };
    let mt = iter_metatiles(tr, z, 4, 1)[0];
    assert!((mt.x0..=mt.x1).contains(&x) && (mt.y0..=mt.y1).contains(&y));
    let mut meta = RenderExtent::for_metatile(&mt);
    meta.core_ox = (x - mt.rx0) * TILE_SIZE_PX;
    meta.core_oy = (y - mt.ry0) * TILE_SIZE_PX;
    (single, meta)
}

/// Tiles from the design-research scenes (z19), incl. ones on the right/bottom edge of a
/// metatile (x % 4 == 3, y % 4 == 3) where the two layouts disagree most about the gutter.
const SCENE_TILES: [(u32, u32); 4] = [(281690, 172044), (281691, 172047), (281683, 172040), (281704, 172044)];

fn scene_tiles(z: u32) -> impl Iterator<Item = (u32, u32, u32)> {
    let d = 1 << (19 - z);
    SCENE_TILES.iter().map(move |&(x, y)| (z, x / d, y / d))
}

/// Line segments (move_to → line_to) of a path.
fn segments(path: &Path) -> Vec<((f32, f32), (f32, f32))> {
    let mut out = Vec::new();
    let mut cur = (0.0, 0.0);
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => cur = (p.x, p.y),
            PathSegment::LineTo(p) => {
                out.push((cur, (p.x, p.y)));
                cur = (p.x, p.y);
            }
            _ => panic!("unexpected curve segment"),
        }
    }
    out
}

fn dist(a: (f32, f32), b: (f32, f32)) -> f32 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

/// Share of pixels whose max channel difference exceeds `tol` (same metric as seam_check.sh).
fn diff_share(a: &Pixmap, b: &Pixmap, tol: u8) -> f64 {
    let n = a.data().chunks_exact(4).zip(b.data().chunks_exact(4)).filter(|(p, q)| p.iter().zip(q.iter()).any(|(u, v)| u.abs_diff(*v) > tol)).count();
    n as f64 / f64::from(a.width() * a.height())
}

// ---------------------------------------------------------------- hashing & noise

#[test]
fn hash_and_noise_golden_values() {
    // Pinned outputs: changing the hash or the noise changes every rendered tile. If that is
    // intended, update these numbers *and* the regress.sh baselines together.
    assert_eq!(hash_u64(0), 0);
    assert_eq!(hash_u64(1), 0xb456_bcfc_34c2_cb2c);
    assert_eq!(rand01(123_456_789, 7), 0.4883862);
    assert_eq!(value_noise(1_494_000.25, 6_888_000.75, 2.0, 21), 0.909_637_45);
    assert_eq!(fbm(1_494_000.25, 6_888_000.75, 8.0, 3, 21), -0.162_299_41);
}

#[test]
fn rand01_in_unit_interval() {
    for id in -500..500i64 {
        for salt in [0u64, 1, 7, 0xdead_beef] {
            let v = rand01(id * 7919, salt);
            assert!((0.0..1.0).contains(&v), "rand01({id}, {salt}) = {v}");
        }
    }
}

#[test]
fn value_noise_deterministic_and_bounded() {
    for i in 0..2000 {
        let x = 1_490_000.0 + f64::from(i) * 3.17;
        let y = 6_885_000.0 + f64::from(i % 97) * 5.31;
        let v = value_noise(x, y, 4.0, 33);
        assert!((0.0..=1.0).contains(&v));
        assert_eq!(v.to_bits(), value_noise(x, y, 4.0, 33).to_bits());
    }
}

#[test]
fn value_noise_continuous_across_cell_edges() {
    // At Berlin's world coordinates (~1.5e6 / 6.9e6 m) the lattice corners must line up, so
    // the value just left/right (below/above) of a cell edge is (almost) the same.
    for cell in [0.8, 2.0, 5.5, zcell(17, 3.6)] {
        for k in 0..200 {
            let ex = (1_494_000.0 / cell).floor() * cell + f64::from(k) * cell;
            let ey = (6_888_000.0 / cell).floor() * cell + f64::from(k) * cell;
            let y = ey + cell * 0.37;
            let x = ex + cell * 0.61;
            let eps = cell * 1e-7;
            let dx = (value_noise(ex - eps, y, cell, 5) - value_noise(ex + eps, y, cell, 5)).abs();
            let dy = (value_noise(x, ey - eps, cell, 5) - value_noise(x, ey + eps, cell, 5)).abs();
            assert!(dx < 1e-4 && dy < 1e-4, "cell {cell} edge {k}: jump {dx} / {dy}");
        }
    }
}

#[test]
fn fbm_bounded_and_continuous() {
    let cell = 8.0;
    let mut prev = fbm(1_494_000.0, 6_888_000.0, cell, 4, 9);
    // walk in steps of 1 cm across many octave cell edges: no jumps
    for i in 1..20_000 {
        let x = 1_494_000.0 + f64::from(i) * 0.01;
        let v = fbm(x, 6_888_000.0, cell, 4, 9);
        assert!((-1.0..=1.0).contains(&v));
        assert!((v - prev).abs() < 0.02, "fbm jump {prev} → {v} at x = {x}");
        prev = v;
    }
}

#[test]
fn zcell_doubles_per_zoom_out() {
    assert_eq!(zcell(19, 1.6), 1.6);
    assert_eq!(zcell(18, 1.6), 3.2);
    assert_eq!(zcell(16, 1.6), 12.8);
}

// ---------------------------------------------------------------- world anchoring

#[test]
fn ctx_world_matches_across_layouts() {
    let mut h = Harness::new();
    for z in [17, 18, 19] {
        for (z, x, y) in scene_tiles(z) {
            let (a, b) = layouts(z, x, y);
            let probe = [(0.0, 0.0), (128.5, 17.25), (255.0, 255.0)];
            let wa = probe.map(|(px, py)| h.ctx(a, z).world(a.core_ox as f32 + px, a.core_oy as f32 + py));
            let wb = probe.map(|(px, py)| h.ctx(b, z).world(b.core_ox as f32 + px, b.core_oy as f32 + py));
            for (p, q) in wa.iter().zip(wb.iter()) {
                assert!((p.0 - q.0).abs() < 1e-6 && (p.1 - q.1).abs() < 1e-6, "{z}/{x}/{y}: {p:?} vs {q:?}");
            }
        }
    }
}

#[test]
fn world_scatter_identical_for_overlapping_layouts() {
    let mut h = Harness::new();
    // (cell at z19, density, seed) as used by style_la / style_ink
    let uses: [(f64, f32, u64, bool); 6] = [(1.6, 0.9, 21, true), (5.5, 0.92, 33, false), (3.6, 0.38, 41, true), (2.0, 0.6, 43, true), (4.0, 0.55, 61, true), (5.0, 0.9, 51, false)];
    for z in [17, 18, 19] {
        for (z, x, y) in scene_tiles(z) {
            let (ea, eb) = layouts(z, x, y);
            for &(cell, density, seed, zoomed) in &uses {
                let cell = if zoomed { zcell(z, cell) } else { cell };
                let pa = world_scatter(&h.ctx(ea, z), cell, density, seed);
                let pb = world_scatter(&h.ctx(eb, z), cell, density, seed);
                // the single-tile extent (+ margin) lies inside the metatile extent (+ margin)
                let (b, m) = (ea.bounds, 40.0);
                let inside = |p: &&(f64, f64, f32)| p.0 >= b.minx - m && p.0 <= b.maxx + m && p.1 >= b.miny - m && p.1 <= b.maxy + m;
                let mut qa: Vec<_> = pa.iter().filter(inside).map(|p| (p.0.to_bits(), p.1.to_bits(), p.2.to_bits())).collect();
                let mut qb: Vec<_> = pb.iter().filter(inside).map(|p| (p.0.to_bits(), p.1.to_bits(), p.2.to_bits())).collect();
                qa.sort_unstable();
                qb.sort_unstable();
                assert!(!qa.is_empty());
                assert_eq!(qa, qb, "{z}/{x}/{y} cell {cell} seed {seed}");
            }
        }
    }
}

#[test]
fn world_scatter_density_roughly_matches() {
    let mut h = Harness::new();
    let (e, _) = layouts(19, 281690, 172044);
    let ctx = h.ctx(e, 19);
    for density in [0.2f32, 0.55, 0.9] {
        let cell = 2.0;
        let pts = world_scatter(&ctx, cell, density, 77);
        let b = e.bounds;
        let cells = ((b.maxx - b.minx + 80.0) / cell) * ((b.maxy - b.miny + 80.0) / cell);
        let share = pts.len() as f64 / cells;
        assert!((share - f64::from(density)).abs() < 0.05, "density {density}: got {share}");
        // every point carries a value in [0,1) and sits inside its own cell
        assert!(pts.iter().all(|p| (0.0..1.0).contains(&p.2)));
    }
}

#[test]
fn ref_scale_constant_within_z10_tile() {
    let mut h = Harness::new();
    // z10 tile containing the scenes (550/336, Neukölln)
    let (x10, y10) = (281690u32 >> 9, 172044u32 >> 9);
    let reference = h.ctx(RenderExtent::for_tile(x10, y10, 10, 0), 10).ref_scale();
    for z in 12..=19u32 {
        let n = 1u32 << (z - 10);
        // corners and centre of the z10 tile, both layouts
        for (fx, fy) in [(0, 0), (n - 1, 0), (0, n - 1), (n - 1, n - 1), (n / 2, n / 2)] {
            let (a, b) = layouts(z, x10 * n + fx, y10 * n + fy);
            let sa = h.ctx(a, z).ref_scale();
            let sb = h.ctx(b, z).ref_scale();
            assert_eq!(sa.to_bits(), reference.to_bits(), "z{z} +{fx}/+{fy} single tile");
            assert_eq!(sb.to_bits(), reference.to_bits(), "z{z} +{fx}/+{fy} metatile");
        }
    }
    // …and it is a real Mercator stretch for Berlin (~52.5° N)
    assert!((reference - 1.0 / 52.5f64.to_radians().cos()).abs() < 0.01, "{reference}");
    // the next z10 row is a different band
    let next = h.ctx(RenderExtent::for_tile(x10, y10 + 1, 10, 0), 10).ref_scale();
    assert!(next < reference);
}

#[test]
#[ignore = "known limitation: at z<=11 a 4-metatile spans several z10 tiles, ref_scale picks one of them (see TESTING.md)"]
fn ref_scale_layouts_agree_at_low_zoom() {
    let mut h = Harness::new();
    for z in [10, 11] {
        for (z, x, y) in scene_tiles(z) {
            let (a, b) = layouts(z, x, y);
            assert_eq!(h.ctx(a, z).ref_scale(), h.ctx(b, z).ref_scale(), "{z}/{x}/{y}");
        }
    }
}

#[test]
fn ctx_m_identical_across_layouts() {
    let mut h = Harness::new();
    for z in [16, 17, 18, 19] {
        for (z, x, y) in scene_tiles(z) {
            let (a, b) = layouts(z, x, y);
            for metres in [0.6, 1.1, 2.4, 40.0] {
                let ma = h.ctx(a, z).m(metres);
                let mb = h.ctx(b, z).m(metres);
                assert_eq!(ma.to_bits(), mb.to_bits(), "{z}/{x}/{y} m({metres})");
            }
        }
    }
}

// ---------------------------------------------------------------- hatching

/// World offset of a hatch line along the line normal, in pixels: must be a multiple of `sp`.
fn hatch_offsets(ctx: &Ctx, path: &Path, angle_deg: f32, sp: f64) -> Vec<(i64, f64)> {
    let a = f64::from(angle_deg).to_radians();
    let (nx, ny) = (-a.sin(), a.cos());
    let mpp = ctx.extent.metres_per_px();
    segments(path)
        .into_iter()
        .map(|(p, q)| {
            let (wx, wy) = ctx.world((p.0 + q.0) / 2.0, (p.1 + q.1) / 2.0);
            // pixel y points down, world y up
            let w = (wx * nx - wy * ny) / mpp;
            let k = (w / sp).round();
            (k as i64, w - k * sp)
        })
        .collect()
}

#[test]
fn hatch_lines_world_anchored_across_layouts() {
    let mut h = Harness::new();
    for z in [17, 18, 19] {
        for (z, x, y) in scene_tiles(z) {
            let (ea, eb) = layouts(z, x, y);
            for angle in [45.0f32, 30.0, 90.0, 117.5, -12.0] {
                let mut ks = Vec::new();
                for e in [ea, eb] {
                    let ctx = h.ctx(e, z);
                    let sp = ctx.m(1.1).max(4.0);
                    // hatch the core tile only, so both layouts cover the same world box
                    let (x0, y0) = (e.core_ox as f32, e.core_oy as f32);
                    let path = hatch_path(&ctx, sp, angle, x0, y0, x0 + 256.0, y0 + 256.0).expect("hatch path");
                    let offs = hatch_offsets(&ctx, &path, angle, f64::from(sp));
                    for &(k, r) in &offs {
                        assert!(r.abs() < 2e-3, "{z}/{x}/{y} angle {angle}: line {k} off grid by {r} px");
                    }
                    let mut k: Vec<i64> = offs.iter().map(|o| o.0).collect();
                    k.sort_unstable();
                    ks.push(k);
                }
                assert_eq!(ks[0], ks[1], "{z}/{x}/{y} angle {angle}: different line sets");
            }
        }
    }
}

/// Hatch a box with `hatch_path` + `line()` in both layouts and return the share of core-tile
/// pixels that differ. `whole_buffer`: hatch (0,0)-(w,h) like the presets do, else the core tile.
fn hatch_raster_diff(h: &mut Harness, (z, x, y): (u32, u32, u32), angle: f32, width: f32, whole_buffer: bool) -> f64 {
    let (ea, eb) = layouts(z, x, y);
    let mut tiles = Vec::new();
    for e in [ea, eb] {
        let ctx = h.ctx(e, z);
        let mut pm = Pixmap::new(e.width_px, e.height_px).unwrap();
        pm.fill(Color::WHITE);
        let sp = ctx.m(1.1).max(4.0);
        let (x0, y0, x1, y1) = if whole_buffer {
            (0.0, 0.0, e.width_px as f32, e.height_px as f32)
        } else {
            (e.core_ox as f32, e.core_oy as f32, e.core_ox as f32 + 256.0, e.core_oy as f32 + 256.0)
        };
        let path = hatch_path(&ctx, sp, angle, x0, y0, x1, y1).unwrap();
        line(&mut pm, &path, &paint(Color::BLACK), &stroke(width), None);
        tiles.push(crop_core_tile(&pm, e));
    }
    diff_share(&tiles[0], &tiles[1], 8)
}

#[test]
fn hatch_raster_identical_when_hatching_the_core_box() {
    let mut h = Harness::new();
    for t in scene_tiles(19).chain(scene_tiles(18)) {
        for angle in [0.0f32, 30.0, 45.0, 90.0] {
            for width in [0.5f32, 1.0, 1.5] {
                let share = hatch_raster_diff(&mut h, t, angle, width, false);
                // a few AA edge pixels may differ by more than 8/255, no whole lines
                assert!(share < 5e-4, "{t:?} angle {angle} width {width}: {:.3} % pixels differ", share * 100.0);
            }
        }
    }
}

#[test]
fn hatch_raster_whole_buffer_axis_aligned() {
    // style_la: pedestrian areas, 0°/90° hairlines (stroke 0.5) over the whole buffer
    let mut h = Harness::new();
    for t in scene_tiles(19).chain(scene_tiles(18)) {
        for angle in [0.0f32, 90.0] {
            let share = hatch_raster_diff(&mut h, t, angle, 0.5, true);
            assert!(share < 2e-3, "{t:?} angle {angle}: {:.3} % pixels differ", share * 100.0);
        }
    }
}

#[test]
#[ignore = "known seam bug: diagonal hatch over the whole render buffer rasterises differently per layout (see TESTING.md)"]
fn hatch_raster_whole_buffer_diagonal() {
    // style_ink: playgrounds, 45° thin strokes over the whole buffer. The lines are the same in
    // world space, but tiny-skia rasterises the ~2x longer lines of the metatile buffer with
    // sub-pixel shifts: 4–8 % of the core-tile pixels differ at z19.
    let mut h = Harness::new();
    for t in scene_tiles(19) {
        for width in [0.5f32, 1.0] {
            let share = hatch_raster_diff(&mut h, t, 45.0, width, true);
            assert!(share < 2e-3, "{t:?} width {width}: {:.3} % pixels differ", share * 100.0);
        }
    }
}

#[test]
fn grain_identical_in_core_tile() {
    let mut h = Harness::new();
    for z in [17, 19] {
        for (z, x, y) in scene_tiles(z) {
            let (ea, eb) = layouts(z, x, y);
            let mut tiles = Vec::new();
            for e in [ea, eb] {
                let ctx = h.ctx(e, z);
                let mut pm = Pixmap::new(e.width_px, e.height_px).unwrap();
                pm.fill(Color::from_rgba8(180, 170, 140, 255));
                apply_grain(&ctx, &mut pm, None, zcell(z, 2.0), 3, 0.25, 7);
                tiles.push(crop_core_tile(&pm, e));
            }
            let share = diff_share(&tiles[0], &tiles[1], 1);
            assert!(share < 1e-3, "{z}/{x}/{y}: {:.3} % pixels differ", share * 100.0);
        }
    }
}

// ---------------------------------------------------------------- pixel-space helpers

#[test]
fn scallop_pts_shape() {
    let (cx, cy, r, amp) = (100.0f32, 50.0f32, 20.0f32, 0.16f32);
    for bumps in [2u32, 5, 9, 13] {
        let pts = scallop_pts(cx, cy, r, bumps, amp, 1.3);
        assert_eq!(pts.len() as u32, (bumps * 8).max(24));
        for &p in &pts {
            let d = dist(p, (cx, cy));
            assert!(d >= r * (1.0 - amp * 0.5) - 1e-3 && d <= r * (1.0 + amp * 0.5) + 1e-3, "bumps {bumps}: radius {d}");
        }
        // deterministic, and the phase is periodic in 2π
        assert_eq!(pts, scallop_pts(cx, cy, r, bumps, amp, 1.3));
        for (p, q) in pts.iter().zip(scallop_pts(cx, cy, r, bumps, amp, 1.3 + std::f32::consts::TAU)) {
            assert!(dist(*p, q) < 1e-3);
        }
    }
    // amp 0 is a plain circle
    for p in scallop_pts(0.0, 0.0, 10.0, 5, 0.0, 0.0) {
        assert!((dist(p, (0.0, 0.0)) - 10.0).abs() < 1e-4);
    }
}

#[test]
fn along_spacing_offset_and_direction() {
    let pts = [(0.0, 0.0), (30.0, 0.0), (30.0, 40.0)]; // 30 east, then 40 south (y down)
    let s = along(&pts, 10.0, 5.0);
    let at: Vec<(f32, f32)> = s.iter().map(|p| (p.0, p.1)).collect();
    assert_eq!(at, vec![(5.0, 0.0), (15.0, 0.0), (25.0, 0.0), (30.0, 5.0), (30.0, 15.0), (30.0, 25.0), (30.0, 35.0)]);
    assert!(s[..3].iter().all(|p| p.2.abs() < 1e-6));
    assert!(s[3..].iter().all(|p| (p.2 - std::f32::consts::FRAC_PI_2).abs() < 1e-6));
    // consecutive points on one segment are exactly one step apart
    for w in s.windows(2).take(2) {
        assert!((dist((w[0].0, w[0].1), (w[1].0, w[1].1)) - 10.0).abs() < 1e-4);
    }
    // zero-length segments are skipped, degenerate input is empty
    let dup = [(0.0, 0.0), (0.0, 0.0), (20.0, 0.0), (20.0, 0.0)];
    assert_eq!(along(&dup, 10.0, 0.0).len(), 3);
    assert!(along(&[], 5.0, 0.0).is_empty());
    assert!(along(&[(1.0, 1.0)], 5.0, 0.0).is_empty());
    assert!(along(&pts, 10.0, 100.0).is_empty());
}

#[test]
#[ignore = "along() itself still counts from the start of the clipped line; callers must pass unclipped lines (see TESTING.md)"]
fn along_on_clipped_lines_is_world_anchored() {
    // The presets feed along() with lines clipped by SQL to extent + margin. A neighbouring
    // metatile clips the same street at a different place, so the first symbol lands at a
    // different world position and the dash/tick rhythm jumps at the seam.
    let full = [(-40.0f32, 10.0f32), (300.0, 10.0)];
    let clipped = [(-17.3f32, 10.0f32), (300.0, 10.0)]; // same line, another clip box
    let a: Vec<f32> = along(&full, 6.0, 0.0).iter().map(|p| p.0).filter(|x| *x >= 0.0).collect();
    let b: Vec<f32> = along(&clipped, 6.0, 0.0).iter().map(|p| p.0).filter(|x| *x >= 0.0).collect();
    assert_eq!(a, b);
}

#[test]
fn point_at_arc_length() {
    let pts = [(0.0, 0.0), (10.0, 0.0), (10.0, 0.0), (10.0, 20.0)];
    assert_eq!(point_at(&pts, 0.0), (0.0, 0.0));
    assert_eq!(point_at(&pts, 4.0), (4.0, 0.0));
    assert_eq!(point_at(&pts, 10.0), (10.0, 0.0));
    assert_eq!(point_at(&pts, 15.0), (10.0, 5.0));
    assert_eq!(point_at(&pts, 30.0), (10.0, 20.0));
    // beyond the end → last point, empty → origin
    assert_eq!(point_at(&pts, 99.0), (10.0, 20.0));
    assert_eq!(point_at(&[], 3.0), (0.0, 0.0));
    // agrees with along()
    for (x, y, _) in along(&pts, 7.0, 0.0).iter().copied().skip(1) {
        let s = if y == 0.0 { x } else { 10.0 + y };
        let p = point_at(&pts, s);
        assert!(dist(p, (x, y)) < 1e-4);
    }
}

#[test]
fn hachures_alternate_and_point_right() {
    // eastward line in pixel space: the right-hand side is +y (down the screen)
    let pts = [(0.0, 50.0), (40.0, 50.0)];
    let (sp, len) = (4.0, 6.0);
    let path = hachures(&pts, sp, len).unwrap();
    let segs = segments(&path);
    let feet = along(&pts, sp, sp * 0.5);
    assert_eq!(segs.len(), feet.len());
    for (i, ((p, q), f)) in segs.iter().zip(feet.iter()).enumerate() {
        assert_eq!(*p, (f.0, f.1));
        assert!((q.0 - p.0).abs() < 1e-5 && q.1 > p.1, "stroke {i} must point down: {p:?} → {q:?}");
        let want = if i % 2 == 0 { len } else { len * 0.55 };
        assert!((dist(*p, *q) - want).abs() < 1e-4, "stroke {i}: {}", dist(*p, *q));
    }
    // reversing the way flips the side
    let rev = [(40.0, 50.0), (0.0, 50.0)];
    assert!(segments(&hachures(&rev, sp, len).unwrap()).iter().all(|(p, q)| q.1 < p.1));
    assert!(hachures(&[(0.0, 0.0)], sp, len).is_none());
}
