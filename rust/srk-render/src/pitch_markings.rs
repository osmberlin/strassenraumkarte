//! QGIS SvgMarker pitch markings (`style/textures/pitches/*.svg`) via resvg.
//!
//! `resvg` 0.44 pulls `tiny-skia` 0.11; the renderer uses 0.12. Stamps are
//! rasterized with resvg's skia, then byte-copied into our pixmap for compositing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tiny_skia::{Pixmap, PixmapPaint, Transform};

use crate::paint::map_to_px;
use crate::palette::pitch_marking_svg_stem;
use crate::tile::RenderExtent;

const STEMS: &[&str] = &[
    "multi",
    "soccer",
    "soccer_small",
    "basketball_1",
    "basketball_2",
    "tennis",
    "volleyball",
    "badminton",
    "handball",
    "field_hockey",
    "rugby_league",
    "rugby_union",
    "chess",
];

#[derive(Debug)]
pub struct PitchMarkingCatalog {
    trees: HashMap<&'static str, resvg::usvg::Tree>,
}

impl PitchMarkingCatalog {
    pub fn load() -> Result<Self> {
        let root = find_repo_root();
        let dir = root.join("style/textures/pitches");
        let mut trees = HashMap::new();
        let mut opts = resvg::usvg::Options::default();
        opts.fontdb_mut().load_system_fonts();

        for stem in STEMS {
            let path = dir.join(format!("{stem}.svg"));
            if !path.is_file() {
                continue;
            }
            let data =
                std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            let data = preprocess_qgis_svg_params(&data);
            match resvg::usvg::Tree::from_data(&data, &opts) {
                Ok(tree) => {
                    trees.insert(*stem, tree);
                }
                Err(e) => eprintln!("warn: pitch SVG {stem}: {e}"),
            }
        }
        eprintln!(
            "pitch markings: loaded {} SVG(s) from {}",
            trees.len(),
            dir.display()
        );
        Ok(Self { trees })
    }

    pub fn fallback() -> Self {
        eprintln!("pitch markings: no SVGs loaded");
        Self {
            trees: HashMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.trees.is_empty()
    }

    /// Render marking centred on `(cx,cy)` map metres size, rotated `direction` deg.
    pub fn stamp(
        &self,
        pixmap: &mut Pixmap,
        extent: RenderExtent,
        stem: &str,
        cx: f32,
        cy: f32,
        width_m: f64,
        height_m: f64,
        direction_deg: f32,
    ) {
        let Some(tree) = self.trees.get(stem) else {
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
        resvg::render(tree, fit, &mut rstamp.as_mut());

        let Some(mut stamp) = Pixmap::new(w_px, h_px) else {
            return;
        };
        stamp.data_mut().copy_from_slice(rstamp.data());

        let mut paint = PixmapPaint::default();
        paint.opacity = 0.95;
        // QGIS/MapLibre: rotate by direction+90°, stamp centred on the point.
        let t = Transform::from_translate(-(w_px as f32) * 0.5, -(h_px as f32) * 0.5)
            .post_rotate(direction_deg + 90.0)
            .post_translate(cx, cy);
        pixmap.draw_pixmap(0, 0, stamp.as_ref(), &paint, t, None);
    }
}

pub fn stem_for_feature(
    sport: Option<&str>,
    hoops: Option<&str>,
    dist_long: Option<f32>,
) -> Option<&'static str> {
    pitch_marking_svg_stem(sport, hoops, dist_long)
}

fn find_repo_root() -> PathBuf {
    if let Ok(root) = std::env::var("SRK_REPO_ROOT") {
        return PathBuf::from(root);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..8 {
        if dir.join("style/textures/pitches").is_dir() {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }
    PathBuf::from(".")
}

/// QGIS SvgMarker params: `param(outline) #ededed` → white field lines.
fn preprocess_qgis_svg_params(data: &[u8]) -> Vec<u8> {
    let Ok(text) = std::str::from_utf8(data) else {
        return data.to_vec();
    };
    let mut out = text.to_string();
    out = out.replace("param(outline) #ededed", "#ffffff");
    out = out.replace("param(outline) #ffffff", "#ffffff");
    out = out.replace("stroke:#ededed", "stroke:#ffffff");
    out = out.replace("stroke=\"#ededed\"", "stroke=\"#ffffff\"");
    // Drop QGIS param() stroke-width wrappers; keep the numeric fallback.
    // e.g. stroke-width="param(outline-width) 5.5" → stroke-width="5.5"
    if let Ok(re) = regex_lite_replace_param_width(&out) {
        out = re;
    }
    out.into_bytes()
}

fn regex_lite_replace_param_width(s: &str) -> Result<String, ()> {
    // Avoid a regex crate dep: simple scan for param(outline-width).
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    let needle = "param(outline-width)";
    while let Some(i) = rest.find(needle) {
        out.push_str(&rest[..i]);
        let after = &rest[i + needle.len()..];
        let trimmed = after.trim_start();
        // Keep following number token
        let mut end = 0;
        for (idx, c) in trimmed.char_indices() {
            if c.is_ascii_digit() || c == '.' {
                end = idx + c.len_utf8();
            } else {
                break;
            }
        }
        if end > 0 {
            out.push_str(&trimmed[..end]);
            rest = &trimmed[end..];
        } else {
            out.push_str(needle);
            rest = after;
        }
    }
    out.push_str(rest);
    Ok(out)
}

#[allow(dead_code)]
fn _path_exists(p: &Path) -> bool {
    p.exists()
}

/// Helper used by layers to place a marking from map coords.
pub fn stamp_at_map_point(
    catalog: &PitchMarkingCatalog,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    stem: &str,
    x: f64,
    y: f64,
    width_m: f64,
    height_m: f64,
    direction_deg: f32,
) {
    let (cx, cy) = map_to_px(extent, geo_types::Coord { x, y });
    catalog.stamp(
        pixmap,
        extent,
        stem,
        cx,
        cy,
        width_m,
        height_m,
        direction_deg,
    );
}
