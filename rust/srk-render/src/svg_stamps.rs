//! Lazy SVG stamp catalog for traffic signs / road marking icons under `style/symbols/`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::Result;
use tiny_skia::{Pixmap, PixmapPaint, Transform};

use crate::paint::map_to_px;
use crate::tile::RenderExtent;

#[derive(Debug)]
pub struct SvgStampCatalog {
    root: PathBuf,
    trees: Mutex<HashMap<String, resvg::usvg::Tree>>,
}

impl SvgStampCatalog {
    pub fn load() -> Result<Self> {
        let root = find_repo_root();
        let symbols = root.join("style/symbols");
        if !symbols.is_dir() {
            anyhow::bail!("style/symbols not found under {}", root.display());
        }
        eprintln!("svg stamps: symbols root {}", symbols.display());
        Ok(Self {
            root,
            trees: Mutex::new(HashMap::new()),
        })
    }

    pub fn fallback() -> Self {
        eprintln!("svg stamps: disabled");
        Self {
            root: PathBuf::from("."),
            trees: Mutex::new(HashMap::new()),
        }
    }

    fn tree_for(&self, rel: &str) -> Option<resvg::usvg::Tree> {
        {
            let guard = self.trees.lock().ok()?;
            if let Some(t) = guard.get(rel) {
                return Some(t.clone());
            }
        }
        let path = self.root.join("style/symbols").join(rel);
        if !path.is_file() {
            return None;
        }
        let data = std::fs::read(&path).ok()?;
        let data = preprocess_qgis_svg_params(&data);
        let mut opts = resvg::usvg::Options::default();
        opts.fontdb_mut().load_system_fonts();
        let tree = resvg::usvg::Tree::from_data(&data, &opts).ok()?;
        if let Ok(mut guard) = self.trees.lock() {
            guard.insert(rel.to_string(), tree.clone());
        }
        Some(tree)
    }

    /// Stamp SVG centred at map metres `(x,y)`, sized `width_m` × `height_m`, rotated deg.
    pub fn stamp_at_map(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        rel_path: &str,
        x: f64,
        y: f64,
        width_m: f64,
        height_m: f64,
        direction_deg: f32,
    ) {
        let Some(tree) = self.tree_for(rel_path) else {
            return;
        };
        let w_px = extent.metres_to_px(width_m).max(2.0).round() as u32;
        let h_px = extent.metres_to_px(height_m).max(2.0).round() as u32;
        let w_px = w_px.min(extent.width_px).max(2);
        let h_px = h_px.min(extent.height_px).max(2);

        let Some(mut rstamp) = resvg::tiny_skia::Pixmap::new(w_px, h_px) else {
            return;
        };
        let size = tree.size();
        let sx = w_px as f32 / size.width();
        let sy = h_px as f32 / size.height();
        let fit = resvg::tiny_skia::Transform::from_scale(sx, sy);
        resvg::render(&tree, fit, &mut rstamp.as_mut());

        let Some(mut stamp) = Pixmap::new(w_px, h_px) else {
            return;
        };
        stamp.data_mut().copy_from_slice(rstamp.data());

        let (cx, cy) = map_to_px(extent, geo_types::Coord { x, y });
        let paint = PixmapPaint::default();
        let t = Transform::from_translate(-(w_px as f32) * 0.5, -(h_px as f32) * 0.5)
            .post_rotate(direction_deg)
            .post_translate(cx, cy);
        pixmap.draw_pixmap(0, 0, stamp.as_ref(), &paint, t, None);
    }
}

fn find_repo_root() -> PathBuf {
    if let Ok(root) = std::env::var("SRK_REPO_ROOT") {
        return PathBuf::from(root);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..8 {
        if dir.join("style/symbols").is_dir() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }
    PathBuf::from(".")
}

fn preprocess_qgis_svg_params(data: &[u8]) -> Vec<u8> {
    let Ok(text) = std::str::from_utf8(data) else {
        return data.to_vec();
    };
    let mut out = text.to_string();
    out = out.replace("param(fill) #ffffff", "#ffffff");
    out = out.replace("param(outline) #000000", "#000000");
    out = out.replace("param(outline) #232323", "#232323");
    out.into_bytes()
}

#[allow(dead_code)]
fn _path_exists(p: &Path) -> bool {
    p.exists()
}

/// Resolve relative SVG path for a `road_marking_node` row.
pub fn road_marking_node_svg(
    road_marking: Option<&str>,
    symbol: Option<&str>,
    arrow: Option<&str>,
    class: Option<&str>,
) -> Option<String> {
    match road_marking.unwrap_or("") {
        "arrow" => {
            let a = arrow.filter(|s| !s.is_empty())?;
            Some(format!("traffic_signs/arrows/{a}.svg"))
        }
        "traffic_sign" => {
            let sym = symbol.filter(|s| !s.is_empty())?;
            let cls = class.filter(|s| !s.is_empty()).unwrap_or("DE");
            Some(format!("traffic_signs/{cls}/{sym}.svg"))
        }
        "symbol" => {
            let sym = symbol.filter(|s| !s.is_empty())?;
            if matches!(sym, "bicycle" | "footway" | "wheelchair" | "loading" | "charging") {
                Some(format!("traffic_signs/symbols/{sym}.svg"))
            } else {
                None
            }
        }
        _ => None,
    }
}
