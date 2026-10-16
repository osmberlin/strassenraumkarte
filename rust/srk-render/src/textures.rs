//! RasterFill texture catalog — load PNGs from `style/textures/` or the packed sprite,
//! with procedural fallbacks when assets are missing.
//!
//! v1 limits (documented in `audit/tile-regression/STYLE_ITERATE_GAPS.md`):
//! - MapUnit widths scale with zoom; sprite PNGs are baked @ z18 ground width.
//! - No per-feature rotation (`direction` / sett:length).
//! - Map-anchored repeat (Web Mercator phase); QGIS viewport phase may differ on metatile refs.
//! - Class/surface overlays only; no effect stacks on textures.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tiny_skia::{IntRect, Pixmap};

/// QGIS RasterFill MapUnit widths (`vector/scripts/build-sprite.ts`).
const TEXTURE_WIDTH_M: &[(&str, f64)] = &[
    ("surface/sett", 11.0),
    ("surface/paving_stones", 4.5),
    ("surface/concrete", 3.0),
    ("surface/asphalt", 6.0),
    ("wetland", 30.0),
    ("water", 35.0),
    ("woodchips", 8.0),
    ("flowerbed", 10.0),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureSource {
    File,
    Sprite,
    Procedural,
}

#[derive(Debug)]
pub struct Texture {
    pub id: &'static str,
    pub pixmap: Pixmap,
    /// `Some` → ground width in metres (scale with zoom); `None` → native pixel tile.
    pub width_m: Option<f64>,
    pub source: TextureSource,
}

#[derive(Debug)]
pub struct TextureCatalog {
    repo_root: PathBuf,
    textures: HashMap<&'static str, Texture>,
}

impl TextureCatalog {
    pub fn load() -> Result<Self> {
        let repo_root = find_repo_root();
        let mut catalog = Self {
            repo_root: repo_root.clone(),
            textures: HashMap::new(),
        };
        let sprite = load_sprite_sheet(&repo_root).ok();

        for id in TEXTURE_IDS {
            let tex = catalog.load_one(id, sprite.as_ref())?;
            catalog.textures.insert(id, tex);
        }

        let missing: Vec<_> = catalog
            .textures
            .values()
            .filter(|t| t.source == TextureSource::Procedural)
            .map(|t| t.id)
            .collect();
        if !missing.is_empty() {
            eprintln!(
                "textures: procedural fallback for: {}",
                missing.join(", ")
            );
        }
        let from_file = catalog
            .textures
            .values()
            .filter(|t| t.source == TextureSource::File)
            .count();
        let from_sprite = catalog
            .textures
            .values()
            .filter(|t| t.source == TextureSource::Sprite)
            .count();
        eprintln!(
            "textures: {from_file} from style/textures, {from_sprite} from sprite ({})",
            catalog.repo_root.display()
        );

        Ok(catalog)
    }

    pub fn get(&self, id: &str) -> Option<&Texture> {
        self.textures.get(id)
    }

    fn load_one(
        &self,
        id: &str,
        sprite: Option<&(Pixmap, SpriteLayout)>,
    ) -> Result<Texture> {
        let width_m = TEXTURE_WIDTH_M
            .iter()
            .find(|(k, _)| *k == id)
            .map(|(_, w)| *w);

        if let Some(mut pm) = load_from_file(&self.repo_root, id) {
            soften_texture(&mut pm, id);
            return Ok(Texture {
                id: leak_str(id),
                pixmap: pm,
                width_m,
                source: TextureSource::File,
            });
        }
        if let Some((sheet, layout)) = sprite {
            if let Some(mut pm) = crop_sprite(sheet, layout, id) {
                soften_texture(&mut pm, id);
                return Ok(Texture {
                    id: leak_str(id),
                    pixmap: pm,
                    width_m,
                    source: TextureSource::Sprite,
                });
            }
        }
        Ok(Texture {
            id: leak_str(id),
            pixmap: procedural_texture(id),
            width_m,
            source: TextureSource::Procedural,
        })
    }
}

/// Textures needed for highway_area + landuse surface/class overlays (v1).
const TEXTURE_IDS: &[&str] = &[
    "surface/asphalt",
    "surface/concrete",
    "surface/paving_stones",
    "surface/sett",
    "grass",
    "gravel",
    "sand",
    "woodchips",
];

fn leak_str(s: &str) -> &'static str {
    Box::leak(s.to_string().into_boxed_str())
}

fn find_repo_root() -> PathBuf {
    if let Ok(root) = std::env::var("SRK_REPO_ROOT") {
        return PathBuf::from(root);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..8 {
        if dir.join("style").is_dir() || dir.join("vector/public/sprites").is_dir() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }
    PathBuf::from(".")
}

fn texture_file_path(root: &Path, id: &str) -> PathBuf {
    if id.contains('/') {
        root.join("style/textures").join(format!("{id}.png"))
    } else {
        root.join("style/textures").join(format!("{id}.png"))
    }
}

fn load_from_file(root: &Path, id: &str) -> Option<Pixmap> {
    let path = texture_file_path(root, id);
    Pixmap::load_png(&path).ok()
}

/// Light blur on high-contrast textures so MapUnit downscale matches Qt softness
/// and Bicubic/Bilinear edge ringing ("Blitzer") stays low.
fn soften_texture(pm: &mut Pixmap, id: &str) {
    let (radius, passes) = match id {
        // Asphalt is ~39% dark texels — needs stronger pre-blur than sett.
        "surface/asphalt" => (3u32, 3u32),
        "surface/sett" => (2u32, 2u32),
        "surface/paving_stones" | "gravel" | "grass" => (1u32, 2u32),
        _ => return,
    };
    let w = pm.width() as usize;
    let h = pm.height() as usize;
    let mut buf = pm.data().to_vec();
    let mut tmp = vec![0u8; buf.len()];
    for _ in 0..passes {
        box_blur_h_tex(&buf, &mut tmp, w, h, radius);
        box_blur_v_tex(&tmp, &mut buf, w, h, radius);
    }
    // Lift crushed blacks so AA edges can't flash near-black texels.
    if id == "surface/asphalt" || id == "surface/sett" {
        for px in buf.chunks_exact_mut(4) {
            px[0] = px[0].saturating_add(18).min(255);
            px[1] = px[1].saturating_add(18).min(255);
            px[2] = px[2].saturating_add(18).min(255);
        }
    }
    pm.data_mut().copy_from_slice(&buf);
}

fn box_blur_h_tex(src: &[u8], dst: &mut [u8], w: usize, h: usize, radius: u32) {
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

fn box_blur_v_tex(src: &[u8], dst: &mut [u8], w: usize, h: usize, radius: u32) {
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

type SpriteLayout = HashMap<String, SpriteRect>;

#[derive(serde::Deserialize)]
struct SpriteRect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

fn load_sprite_sheet(root: &Path) -> Result<(Pixmap, SpriteLayout)> {
    let png_path = root.join("vector/public/sprites/strassenraumkarte.png");
    let json_path = root.join("vector/public/sprites/strassenraumkarte.json");
    let sheet = Pixmap::load_png(&png_path)
        .with_context(|| format!("load sprite sheet {}", png_path.display()))?;
    let json = std::fs::read_to_string(&json_path)
        .with_context(|| format!("read {}", json_path.display()))?;
    let layout: SpriteLayout = serde_json::from_str(&json)?;
    Ok((sheet, layout))
}

fn crop_sprite(sheet: &Pixmap, layout: &SpriteLayout, id: &str) -> Option<Pixmap> {
    let rect = layout.get(id)?;
    let r = IntRect::from_xywh(rect.x as i32, rect.y as i32, rect.width, rect.height)?;
    sheet.clone_rect(r)
}

/// Cheap procedural tiles when PNGs are absent from the working tree.
fn procedural_texture(id: &str) -> Pixmap {
    let w = 48u32;
    let h = 48u32;
    let mut pm = Pixmap::new(w, h).expect("procedural alloc");
    let data = pm.data_mut();
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let (r, g, b, a) = procedural_pixel(id, x, y, w, h);
            data[i] = r;
            data[i + 1] = g;
            data[i + 2] = b;
            data[i + 3] = a;
        }
    }
    pm
}

fn procedural_pixel(id: &str, x: u32, y: u32, _w: u32, _h: u32) -> (u8, u8, u8, u8) {
    let hash = |a: u32, b: u32| -> u32 {
        let mut v = a.wrapping_mul(374761393).wrapping_add(b.wrapping_mul(668265263));
        v = (v ^ (v >> 13)).wrapping_mul(1274126177);
        v ^ (v >> 16)
    };
    match id {
        "surface/asphalt" => {
            let n = hash(x, y) % 28;
            let g = 155u8.saturating_add(n as u8);
            (g, g, g.saturating_sub(2), 220)
        }
        "surface/concrete" => {
            let g = 178u8.saturating_add((hash(x / 2, y / 2) % 12) as u8);
            (g, g, g, 200)
        }
        "surface/paving_stones" => {
            let cell = 12u32;
            let cx = x / cell;
            let cy = y / cell;
            let edge = (x % cell < 1) || (y % cell < 1);
            let v = 165u8.saturating_add(((cx + cy) % 5) as u8 * 6);
            if edge {
                (v.saturating_sub(25), v.saturating_sub(25), v.saturating_sub(28), 210)
            } else {
                (v, v, v.saturating_sub(3), 200)
            }
        }
        "surface/sett" => {
            let cell = 10u32;
            let cx = x / cell;
            let cy = y / cell;
            let ox = (hash(cx, cy) % (cell - 2)) + 1;
            let oy = (hash(cy, cx) % (cell - 2)) + 1;
            let dx = x % cell;
            let dy = y % cell;
            let in_stone = dx >= ox && dx < ox + cell - 3 && dy >= oy && dy < oy + cell - 3;
            if in_stone {
                (142, 140, 136, 215)
            } else {
                (108, 106, 102, 180)
            }
        }
        "grass" => {
            let n = hash(x, y) % 20;
            (118u8.saturating_add(n as u8), 148u8.saturating_add((n / 2) as u8), 78, 190)
        }
        "gravel" => {
            let n = hash(x, y) % 35;
            let g = 185u8.saturating_add(n as u8);
            (g, g, g.saturating_sub(4), 200)
        }
        "sand" => {
            let n = hash(x, y) % 18;
            (218u8.saturating_add(n as u8), 210u8.saturating_add(n as u8), 160, 200)
        }
        "woodchips" => {
            let stripe = (x + y * 3) % 9 < 2;
            if stripe {
                (160, 120, 70, 200)
            } else {
                (190, 150, 95, 190)
            }
        }
        _ => {
            let g = 160u8.saturating_add((hash(x, y) % 30) as u8);
            (g, g, g, 180)
        }
    }
}
