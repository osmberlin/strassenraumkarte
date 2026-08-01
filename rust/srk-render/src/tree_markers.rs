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

        let broadleaved = Pixmap::load_png(&broadleaved_path)
            .with_context(|| format!("load {}", broadleaved_path.display()))?;
        let needleleaved = Pixmap::load_png(&needleleaved_path)
            .unwrap_or_else(|_| broadleaved.clone());

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
