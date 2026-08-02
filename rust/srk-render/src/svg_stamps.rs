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
        self.stamp_tree_at_map(pixmap, extent, &tree, x, y, width_m, height_m, direction_deg);
    }

    /// Stamp a single character via inline SVG (fire hydrant `H`, etc.).
    pub fn stamp_char_at_map(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        ch: char,
        color_hex: &str,
        x: f64,
        y: f64,
        size_m: f64,
    ) {
        let key = format!("char:{ch}:{color_hex}");
        let Some(tree) = self.tree_for_inline(&key, ch, color_hex) else {
            return;
        };
        self.stamp_tree_at_map(pixmap, extent, &tree, x, y, size_m, size_m, 0.0);
    }

    fn tree_for_inline(&self, key: &str, ch: char, color_hex: &str) -> Option<resvg::usvg::Tree> {
        {
            let guard = self.trees.lock().ok()?;
            if let Some(t) = guard.get(key) {
                return Some(t.clone());
            }
        }
        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
  <text x="50" y="58" font-size="72" font-family="Arial, Helvetica, sans-serif" fill="{color_hex}" text-anchor="middle">{ch}</text>
</svg>"#
        );
        let mut opts = resvg::usvg::Options::default();
        opts.fontdb_mut().load_system_fonts();
        let tree = resvg::usvg::Tree::from_str(&svg, &opts).ok()?;
        if let Ok(mut guard) = self.trees.lock() {
            guard.insert(key.to_string(), tree.clone());
        }
        Some(tree)
    }

    fn stamp_tree_at_map(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        tree: &resvg::usvg::Tree,
        x: f64,
        y: f64,
        width_m: f64,
        height_m: f64,
        direction_deg: f32,
    ) {
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
        resvg::render(tree, fit, &mut rstamp.as_mut());

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

pub fn fire_hydrant_ring_only(subclass: Option<&str>) -> bool {
    let s = subclass.unwrap_or("");
    s.contains("pillar") || s.contains("pipe") || s.contains("wall")
}

pub fn bicycle_parking_svg(class: &str, subclass: Option<&str>) -> &'static str {
    if class == "bicycle_rental" {
        return "amenity/bicycle_rental.svg";
    }
    let sub = subclass.unwrap_or("");
    if sub.contains("cargo_bike") {
        return "amenity/cargo_bike.svg";
    }
    if class == "small_electric_vehicle_parking" {
        return "amenity/small_electric_vehicle.svg";
    }
    "amenity/bicycle.svg"
}

pub fn bicycle_parking_icon_size_m(subclass: Option<&str>) -> f64 {
    if subclass.unwrap_or("").contains("cargo_bike") {
        2.2
    } else {
        1.8
    }
}

pub fn mobility_hub_svg(subclass: Option<&str>) -> &'static str {
    if subclass.unwrap_or("").contains("Jelbi") {
        "amenity/mobility_hub_Jelbi.svg"
    } else {
        "amenity/mobility_hub.svg"
    }
}

pub fn furniture_restricted_opacity(access: Option<&str>) -> f32 {
    match access {
        Some("private") | Some("customers") | Some("no") => 0.35,
        _ => 1.0,
    }
}
