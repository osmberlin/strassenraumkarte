//! QGIS RasterMarker tree crown images (`style/symbols/trees/*.png`).
//!
//! The catalog keeps a mip chain per leaf type (2×2 box halving) so that a
//! crown of any on-screen size is sampled from a source at most ~2× larger than
//! the target. That avoids the speckled, aliased crowns a single 600+ px PNG
//! produces when stamped down to 6–40 px.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tiny_skia::Pixmap;

#[derive(Debug)]
pub struct TreeMarkerCatalog {
    /// One mip chain per image variant (`broadleaved01.png` … `broadleaved19.png`).
    broadleaved: Vec<Vec<Pixmap>>,
    needleleaved: Vec<Vec<Pixmap>>,
    shrub: Vec<Vec<Pixmap>>,
}

impl TreeMarkerCatalog {
    pub fn load() -> Result<Self> {
        let repo_root = find_repo_root();
        let broadleaved = load_variants(&repo_root, "broadleaved")?;
        let needleleaved = load_variants(&repo_root, "needleleaved").unwrap_or_else(|_| broadleaved.clone());
        let shrub = load_variants(&repo_root, "shrub").unwrap_or_else(|_| broadleaved.clone());

        eprintln!(
            "tree markers: loaded from {} ({} broadleaved, {} needleleaved, {} shrub variants)",
            repo_root.display(),
            broadleaved.len(),
            needleleaved.len(),
            shrub.len(),
        );

        Ok(Self {
            broadleaved: broadleaved.into_iter().map(mip_chain).collect(),
            needleleaved: needleleaved.into_iter().map(mip_chain).collect(),
            shrub: shrub.into_iter().map(mip_chain).collect(),
        })
    }

    /// Procedural stand-in when PNGs are missing (should not happen in normal dev).
    pub fn fallback() -> Self {
        eprintln!("tree markers: procedural fallback (style/symbols/trees/*.png missing)");
        Self {
            broadleaved: vec![mip_chain(procedural_crown_marker())],
            needleleaved: vec![mip_chain(procedural_crown_marker())],
            shrub: vec![mip_chain(procedural_crown_marker())],
        }
    }

    /// Smallest mip whose larger side is at least `min_side_px`, so the final
    /// draw is a downscale of at most 2× (bilinear stays clean).
    ///
    /// QGIS picks the image per feature with `rand(1, N, "tid")`
    /// (`broadleaved01`–`19`, `needleleaved01`–`06`, `shrub01`–`06`); `variant` is a
    /// stable per-feature key that stands in for that seeded draw.
    pub fn sprite_for(
        &self,
        leaf_type: Option<&str>,
        is_shrub: bool,
        variant: u64,
        min_side_px: f32,
    ) -> &Pixmap {
        let variants = if is_shrub {
            &self.shrub
        } else {
            match leaf_type {
                Some("needleleaved") => &self.needleleaved,
                _ => &self.broadleaved,
            }
        };
        let chain = &variants[(variant % variants.len() as u64) as usize];
        chain
            .iter()
            .rev()
            .find(|pm| pm.width().max(pm.height()) as f32 >= min_side_px)
            .unwrap_or(&chain[0])
    }
}

/// `name01.png`, `name02.png`, … (style since main 05991fe); falls back to the
/// single `name.png` of older styles.
fn load_variants(root: &Path, name: &str) -> Result<Vec<Pixmap>> {
    let mut out = Vec::new();
    for i in 1..=99 {
        let path = marker_path(root, &format!("{name}{i:02}"));
        if !path.is_file() {
            break;
        }
        out.push(Pixmap::load_png(&path).with_context(|| format!("load {}", path.display()))?);
    }
    if out.is_empty() {
        let path = marker_path(root, name);
        out.push(Pixmap::load_png(&path).with_context(|| format!("load {}", path.display()))?);
    }
    Ok(out)
}

/// Level 0 is the source PNG; each next level halves both sides (2×2 box).
/// Stops once the larger side is below 16 px.
fn mip_chain(base: Pixmap) -> Vec<Pixmap> {
    let mut levels = vec![base];
    loop {
        let last = levels.last().expect("non-empty");
        if last.width().max(last.height()) < 32 {
            break;
        }
        let next = halve(last);
        levels.push(next);
    }
    levels
}

/// Premultiplied 2×2 box average (correct for premultiplied RGBA).
fn halve(src: &Pixmap) -> Pixmap {
    let sw = src.width() as usize;
    let sh = src.height() as usize;
    let dw = (sw / 2).max(1);
    let dh = (sh / 2).max(1);
    let mut dst = Pixmap::new(dw as u32, dh as u32).expect("mip alloc");
    let s = src.data();
    let d = dst.data_mut();
    for y in 0..dh {
        for x in 0..dw {
            let x0 = (2 * x).min(sw - 1);
            let x1 = (2 * x + 1).min(sw - 1);
            let y0 = (2 * y).min(sh - 1);
            let y1 = (2 * y + 1).min(sh - 1);
            let idx = [
                (y0 * sw + x0) * 4,
                (y0 * sw + x1) * 4,
                (y1 * sw + x0) * 4,
                (y1 * sw + x1) * 4,
            ];
            let o = (y * dw + x) * 4;
            for c in 0..4 {
                let sum: u32 = idx.iter().map(|&i| u32::from(s[i + c])).sum();
                d[o + c] = ((sum + 2) / 4) as u8;
            }
        }
    }
    dst
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
                continue;
            }
            // Soft edge + green tint (#6b8f4e), premultiplied.
            let edge = (1.0 - d).powf(1.8);
            let a = edge * 0.85;
            data[i] = (0x6b as f32 * a).round() as u8;
            data[i + 1] = (0x8f as f32 * a).round() as u8;
            data[i + 2] = (0x4e as f32 * a).round() as u8;
            data[i + 3] = (a * 255.0).round() as u8;
        }
    }
    pm
}
