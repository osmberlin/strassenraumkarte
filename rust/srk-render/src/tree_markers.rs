//! QGIS RasterMarker tree crown images (`style/symbols/trees/*.png`).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tiny_skia::Pixmap;

#[derive(Debug)]
pub struct TreeMarkerCatalog {
    broadleaved: Pixmap,
    needleleaved: Pixmap,
    /// `true` when at least `broadleaved.png` loaded from disk.
    pub from_file: bool,
}

impl TreeMarkerCatalog {
    pub fn load() -> Result<Self> {
        let repo_root = find_repo_root();
        let broadleaved_path = marker_path(&repo_root, "broadleaved");
        let needleleaved_path = marker_path(&repo_root, "needleleaved");

        let mut broadleaved = Pixmap::load_png(&broadleaved_path)
            .with_context(|| format!("load {}", broadleaved_path.display()))?;
        soften_tree_marker(&mut broadleaved);
        let mut needleleaved = Pixmap::load_png(&needleleaved_path)
            .unwrap_or_else(|_| broadleaved.clone());
        if needleleaved.data() != broadleaved.data() {
            soften_tree_marker(&mut needleleaved);
        }

        eprintln!(
            "tree markers: loaded from {} ({}×{} broadleaved, {}×{} needleleaved)",
            repo_root.display(),
            broadleaved.width(),
            broadleaved.height(),
            needleleaved.width(),
            needleleaved.height(),
        );

        Ok(Self {
            broadleaved,
            needleleaved,
            from_file: true,
        })
    }

    /// Procedural stand-in when PNGs are missing (should not happen in normal dev).
    pub fn fallback() -> Self {
        eprintln!("tree markers: procedural fallback (style/symbols/trees/*.png missing)");
        Self {
            broadleaved: procedural_crown_marker(),
            needleleaved: procedural_crown_marker(),
            from_file: false,
        }
    }

    pub fn for_leaf_type(&self, leaf_type: Option<&str>) -> &Pixmap {
        match leaf_type {
            Some("needleleaved") => &self.needleleaved,
            _ => &self.broadleaved,
        }
    }
}

fn find_repo_root() -> PathBuf {
    if let Ok(root) = std::env::var("SRK_REPO_ROOT") {
        return PathBuf::from(root);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..8 {
        if dir.join("style/symbols/trees").is_dir() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }
    PathBuf::from(".")
}

fn marker_path(root: &Path, name: &str) -> PathBuf {
    root.join("style/symbols/trees").join(format!("{name}.png"))
}


/// Light pre-blur so z17–18 downscale of 600+ px PNGs doesn't pick dark speckles.
fn soften_tree_marker(pm: &mut Pixmap) {
    const RADIUS: u32 = 2;
    const PASSES: u32 = 2;
    let w = pm.width() as usize;
    let h = pm.height() as usize;
    let mut buf = pm.data().to_vec();
    let mut tmp = vec![0u8; buf.len()];
    for _ in 0..PASSES {
        box_blur_h(&buf, &mut tmp, w, h, RADIUS);
        box_blur_v(&tmp, &mut buf, w, h, RADIUS);
    }
    for px in buf.chunks_exact_mut(4) {
        px[0] = px[0].saturating_add(12).min(255);
        px[1] = px[1].saturating_add(12).min(255);
        px[2] = px[2].saturating_add(12).min(255);
    }
    pm.data_mut().copy_from_slice(&buf);
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

/// Soft radial disk when PNGs are unavailable.
fn procedural_crown_marker() -> Pixmap {
    let size = 64u32;
    let mut pm = Pixmap::new(size, size).expect("procedural crown alloc");
    let cx = size as f32 / 2.0;
    let cy = size as f32 / 2.0;
    let r = size as f32 / 2.0 - 1.0;
    let data = pm.data_mut();
    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 + 0.5 - cx;
            let dy = y as f32 + 0.5 - cy;
            let d = (dx * dx + dy * dy).sqrt() / r;
            let i = ((y * size + x) * 4) as usize;
            if d > 1.0 {
                data[i + 3] = 0;
                continue;
            }
            // Soft edge + green tint (#6b8f4e).
            let edge = (1.0 - d).powf(1.8);
            let a = (edge * 0.85 * 255.0).round() as u8;
            data[i] = 0x6b;
            data[i + 1] = 0x8f;
            data[i + 2] = 0x4e;
            data[i + 3] = a;
        }
    }
    pm
}
