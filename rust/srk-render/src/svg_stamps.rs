//! Lazy SVG stamp catalog for traffic signs / road marking icons under `style/symbols/`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::Result;
use tiny_skia::{Pixmap, PixmapPaint, Transform};

use tiny_skia::{BlendMode, FilterQuality};

use crate::paint::{box_blur_approx, map_to_px, tint_pixmap_rgb, DropShadow};
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

    /// Like `tree_for`, with QGIS `param(fill)` resolved to `fill_hex` (the SVG default
    /// when `None`). Only the parking-car path uses this.
    fn tree_for_fill(&self, rel: &str, fill_hex: Option<&str>) -> Option<resvg::usvg::Tree> {
        let key = format!("{rel}#fill={}", fill_hex.unwrap_or(""));
        {
            let guard = self.trees.lock().ok()?;
            if let Some(t) = guard.get(&key) {
                return Some(t.clone());
            }
        }
        let path = self.root.join("style/symbols").join(rel);
        if !path.is_file() {
            return None;
        }
        let data = std::fs::read(&path).ok()?;
        let text = std::str::from_utf8(&data).ok()?;
        let text = resolve_param_fill(text, fill_hex);
        let mut opts = resvg::usvg::Options::default();
        opts.fontdb_mut().load_system_fonts();
        let tree = resvg::usvg::Tree::from_str(&text, &opts).ok()?;
        if let Ok(mut guard) = self.trees.lock() {
            guard.insert(key, tree.clone());
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

    /// Same as [`stamp_at_map`](Self::stamp_at_map) with the QGIS symbol alpha (`opacity` 0–1).
    pub fn stamp_at_map_opacity(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        rel_path: &str,
        x: f64,
        y: f64,
        width_m: f64,
        height_m: f64,
        direction_deg: f32,
        opacity: f32,
    ) {
        let Some(tree) = self.tree_for(rel_path) else {
            return;
        };
        self.stamp_tree_at_map_opacity(pixmap, extent, &tree, x, y, width_m, height_m, direction_deg, opacity);
    }

    /// Per-feature SVG marker as QGIS draws `symbols/cars/*.svg`: the SVG's
    /// `param(fill)` takes `fill_hex` (the feature's `colour`, or the SVG default
    /// when `None`), the marker is fitted to `width_m` × `height_m` (`None` keeps the
    /// SVG's aspect ratio) and rotated clockwise by `angle_deg`. `layer_opacity` and an
    /// optional drop shadow (QGIS layer effect stack, drawn under the marker) are
    /// applied per feature.
    #[allow(clippy::too_many_arguments)]
    pub fn stamp_feature_marker(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        rel_path: &str,
        fill_hex: Option<&str>,
        x: f64,
        y: f64,
        width_m: f64,
        height_m: Option<f64>,
        angle_deg: f32,
        layer_opacity: f32,
        shadow: Option<DropShadow>,
    ) {
        let Some(tree) = self.tree_for_fill(rel_path, fill_hex) else {
            return;
        };
        let size = tree.size();
        // `None` keeps the SVG's own aspect ratio.
        let height_m = height_m.unwrap_or(width_m * f64::from(size.height() / size.width()));
        let w_f = extent.metres_to_px(width_m).max(0.0);
        let h_f = extent.metres_to_px(height_m).max(0.0);
        // QGIS draws nothing for an SVG marker narrower than one pixel
        // (`street parking (<= z17)` is blank at z15, 0.8 px wide, and visible at z16).
        if w_f < 1.0 {
            return;
        }
        // Markers keep their true size: the SVG is fitted to w_f × h_f inside a
        // whole-pixel canvas, centred, so anti-aliasing gives the partial coverage.
        let w_px = (w_f.ceil() as u32).max(1);
        let h_px = (h_f.ceil() as u32).max(1);
        let Some(mut rstamp) = resvg::tiny_skia::Pixmap::new(w_px, h_px) else {
            return;
        };
        let fit = resvg::tiny_skia::Transform::from_scale(
            w_f as f32 / size.width(),
            h_f as f32 / size.height(),
        )
        .post_translate((w_px as f32 - w_f as f32) * 0.5, (h_px as f32 - h_f as f32) * 0.5);
        resvg::render(&tree, fit, &mut rstamp.as_mut());
        // resvg links its own tiny-skia; copy the premultiplied pixels into ours.
        let Some(mut stamp) = Pixmap::new(w_px, h_px) else {
            return;
        };
        stamp.data_mut().copy_from_slice(rstamp.data());

        // Rotate the marker into a square canvas whose centre is the marker centre.
        let (cx, cy) = map_to_px(extent, geo_types::Coord { x, y });
        let (sdx, sdy) = shadow.map(|s| s.offset_px(extent)).unwrap_or((0.0, 0.0));
        let blur_px = shadow
            .map(|s| extent.metres_to_px(s.blur_m).max(0.0))
            .unwrap_or(0.0);
        let diag = ((w_px * w_px + h_px * h_px) as f32).sqrt();
        let pad = (blur_px * 1.5).ceil() as u32 + 2 + sdx.abs().max(sdy.abs()).ceil() as u32;
        let side = (diag.ceil() as u32 + 2 * pad).max(4);
        let Some(mut canvas) = Pixmap::new(side, side) else {
            return;
        };
        let ox = (cx - side as f32 * 0.5).round() as i32;
        let oy = (cy - side as f32 * 0.5).round() as i32;
        let (lx, ly) = (cx - ox as f32, cy - oy as f32);
        let resample = PixmapPaint {
            opacity: 1.0,
            blend_mode: BlendMode::SourceOver,
            quality: FilterQuality::Bilinear,
        };
        let rot = Transform::from_translate(-(w_px as f32) * 0.5, -(h_px as f32) * 0.5)
            .post_rotate(angle_deg)
            .post_translate(lx, ly);
        canvas.draw_pixmap(0, 0, stamp.as_ref(), &resample, rot, None);

        let op = layer_opacity.clamp(0.0, 1.0);
        if let Some(sh) = shadow {
            // Silhouette of the marker, offset, blurred and tinted; knocked out under
            // the marker (QGIS shows the shadow only beside the opaque symbol).
            let mut sil = canvas.clone();
            let mask: Vec<u8> = sil.data().chunks_exact(4).map(|px| px[3]).collect();
            for px in sil.data_mut().chunks_exact_mut(4) {
                px[0] = 0;
                px[1] = 0;
                px[2] = 0;
            }
            let Some(mut sh_canvas) = Pixmap::new(side, side) else {
                return;
            };
            let shift = Transform::from_translate(sdx, sdy);
            sh_canvas.draw_pixmap(0, 0, sil.as_ref(), &resample, shift, None);
            let radius = (blur_px * 0.5).round().max(1.0) as u32;
            box_blur_approx(&mut sh_canvas, radius);
            tint_pixmap_rgb(&mut sh_canvas, sh.color, sh.opacity);
            for (px, m) in sh_canvas.data_mut().chunks_exact_mut(4).zip(mask.iter()) {
                let keep = 1.0 - f32::from(*m) / 255.0;
                if keep < 1.0 {
                    for c in px.iter_mut() {
                        *c = (f32::from(*c) * keep).round() as u8;
                    }
                }
            }
            let mult = PixmapPaint {
                opacity: op,
                blend_mode: BlendMode::Multiply,
                quality: FilterQuality::Nearest,
            };
            pixmap.draw_pixmap(ox, oy, sh_canvas.as_ref(), &mult, Transform::identity(), None);
        }

        let body = PixmapPaint {
            opacity: op,
            blend_mode: BlendMode::SourceOver,
            quality: FilterQuality::Nearest,
        };
        pixmap.draw_pixmap(ox, oy, canvas.as_ref(), &body, Transform::identity(), None);
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
        self.stamp_tree_at_map_opacity(pixmap, extent, tree, x, y, width_m, height_m, direction_deg, 1.0);
    }

    #[allow(clippy::too_many_arguments)]
    fn stamp_tree_at_map_opacity(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        tree: &resvg::usvg::Tree,
        x: f64,
        y: f64,
        width_m: f64,
        height_m: f64,
        direction_deg: f32,
        opacity: f32,
    ) {
        // QGIS SVG markers have no pixel floor: a sub-pixel symbol is (nearly) invisible.
        // Skip only when the stamp covers less than a quarter pixel; otherwise draw ≥1 px.
        let w_f = extent.metres_to_px(width_m).max(0.0);
        let h_f = extent.metres_to_px(height_m).max(0.0);
        if w_f * h_f < 0.25 {
            return;
        }
        let w_px = (w_f.round() as u32).min(extent.width_px).max(1);
        let h_px = (h_f.round() as u32).min(extent.height_px).max(1);

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
        let paint = PixmapPaint {
            opacity: opacity.clamp(0.0, 1.0),
            ..PixmapPaint::default()
        };
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

/// QGIS `param(fill) #rrggbb`: the feature colour replaces the SVG default
/// (or the default is kept when `fill_hex` is `None`).
fn resolve_param_fill(text: &str, fill_hex: Option<&str>) -> String {
    const KEY: &str = "param(fill) #";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(pos) = rest.find(KEY) {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + KEY.len()..];
        let hex_len = after.bytes().take_while(|b| b.is_ascii_hexdigit()).count().min(6);
        let default = &after[..hex_len];
        match fill_hex {
            Some(f) => out.push_str(f),
            None => {
                out.push('#');
                out.push_str(default);
            }
        }
        rest = &after[hex_len..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::resolve_param_fill;

    #[test]
    fn param_fill_takes_feature_colour_or_svg_default() {
        let svg = r##"<g fill="param(fill) #808080"/><g fill="param(fill) #469de4"/>"##;
        assert_eq!(
            resolve_param_fill(svg, Some("#949494")),
            r##"<g fill="#949494"/><g fill="#949494"/>"##
        );
        assert_eq!(
            resolve_param_fill(svg, None),
            r##"<g fill="#808080"/><g fill="#469de4"/>"##
        );
        assert_eq!(resolve_param_fill("no params", Some("#000000")), "no params");
    }
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
