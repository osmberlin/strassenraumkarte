//! Street detail layers of the QGIS style (kerb shade, oneway arrows, tunnel entrances,
//! traffic calming). Kept apart from `layers.rs` so the tree and parked-car passes can
//! change independently.
//!
//! Units follow the project: ground metres × `@mercator_scale` = Web Mercator map units,
//! `metres_to_px` converts map units to pixels. `map_scale` is QGIS' 1:n at 96 DPI.

use std::sync::OnceLock;

use anyhow::Result;
use geo_types::{Coord, Geometry};
use postgres::Client;
use tiny_skia::{
    Color, FillRule, FilterQuality, GradientStop, LinearGradient, Paint, PathBuilder, Pixmap,
    PixmapPaint, Point, SpreadMode, Stroke, Transform,
};

use crate::paint::{
    decode_wkb, envelope_sql, geometry_lines, geometry_points, geometry_polygons, map_to_px,
    polygon_to_path, stroke_lines_offset,
};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::tile::{mercator_scale, RenderExtent};

fn wkb_from_row(row: &postgres::Row, col: &str) -> Option<Vec<u8>> {
    let wkb: Option<Vec<u8>> = row.get(col);
    wkb.filter(|b| !b.is_empty())
}

/// QGIS map scale of a 256 px tile at 96 DPI on the ground: map units per pixel divided by
/// the Web Mercator factor (`@mercator_scale`), then by 0.26458 mm. The project's scale
/// limits only match this ground scale (`kerb shade` ≤ 1:8000 covers z16, `scrub (<= z16)`
/// ≥ 1:4000 ends at z16).
fn map_scale(extent: RenderExtent) -> f64 {
    extent.metres_per_px() / mercator_scale(extent.bounds) / 0.000_264_583_3
}

/// Rows are queried with the tile envelope; the QGIS layers have no scale limits other
/// than the kerb shade (`minScale 8000`, i.e. z17 and closer).
fn query_in_tile(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    timers: &mut Option<&mut StageTimers>,
    sql: &str,
    extent: RenderExtent,
) -> Result<Vec<postgres::Row>> {
    let b = extent.bounds;
    query_prep(client, prep_cache, timers, sql, &[&b.minx, &b.miny, &b.maxx, &b.maxy])
}

// ---------------------------------------------------------------------------------------
// Construction: `construction` LinePatternFill (yellow stripes, 67°, 2.6 m pitch, 1.2 m wide).
// ---------------------------------------------------------------------------------------

/// Stripe direction in screen degrees (clockwise from +x, down-right = "\\").
const CONSTRUCTION_ANGLE_DEG: f64 = 67.0;
const CONSTRUCTION_PITCH_M: f64 = 2.6;
const CONSTRUCTION_STRIPE_M: f64 = 1.2;
/// Stripe colour #ffea00 at the layer opacity 0.2.
const CONSTRUCTION_ALPHA: f32 = 0.2;

pub fn paint_construction_stripes(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let sql = format!(
        r#"
        SELECT ST_AsBinary(geom) AS wkb
        FROM landuse
        WHERE geom && {env}
          AND class = 'construction'
        "#
    );
    let rows = query_in_tile(client, prep_cache, timers, &sql, extent)?;
    let merc = mercator_scale(extent.bounds);
    let pitch = CONSTRUCTION_PITCH_M * merc;
    let mut paint = Paint::default();
    paint.set_color(Color::from_rgba(1.0, 234.0 / 255.0, 0.0, CONSTRUCTION_ALPHA).unwrap_or(Color::BLACK));
    paint.anti_alias = true;
    let stroke = Stroke {
        width: extent.metres_to_px(CONSTRUCTION_STRIPE_M * merc).max(0.5),
        ..Stroke::default()
    };
    // Screen angle → map direction (y is up in Web Mercator).
    let rad = CONSTRUCTION_ANGLE_DEG.to_radians();
    let (dx, dy) = (rad.cos(), -rad.sin());
    let (px, py) = (-dy, dx);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            for poly in geometry_polygons(geom) {
                let Some((min_x, min_y, max_x, max_y)) = bbox_of(std::slice::from_ref(&poly)) else {
                    continue;
                };
                let diagonal = ((max_x - min_x).powi(2) + (max_y - min_y).powi(2)).sqrt().max(pitch);
                let (mx, my) = ((min_x + max_x) * 0.5, (min_y + max_y) * 0.5);
                let half = diagonal * 0.75;
                let n = (diagonal / pitch).ceil() as i32 + 2;
                for i in -n / 2..=n / 2 {
                    let off = f64::from(i) * pitch;
                    let (ox, oy) = (mx + px * off, my + py * off);
                    let (ax, ay) = (ox - dx * half, oy - dy * half);
                    let (bx, by) = (ox + dx * half, oy + dy * half);
                    for (p0, p1) in crate::paint::clip_segment_to_polygon(ax, ay, bx, by, &poly) {
                        let mut pb = PathBuilder::new();
                        let (x0, y0) = map_to_px(extent, p0);
                        let (x1, y1) = map_to_px(extent, p1);
                        pb.move_to(x0, y0);
                        pb.line_to(x1, y1);
                        if let Some(path) = pb.finish() {
                            pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                        }
                    }
                }
            }
        }
    });
    Ok(())
}

// ---------------------------------------------------------------------------------------
// Landuse classes: the QGIS `landuse` categories (`scrub` included via its split layers).
// ---------------------------------------------------------------------------------------

/// `landuse.class` values with a QGIS category. Other classes (`commercial`, `industrial`,
/// `construction`, `motorcycle_parking`, …) get no fill in QGIS; `construction` is drawn
/// by its own hatch layer (`construction_stripes`).
const QGIS_LANDUSE_CLASSES: &[&str] = &[
    "allotments", "bare_ground", "bare_rock", "basin", "bbq", "beach", "biergarten", "blockfield",
    "brownfield", "car_rental", "cemetery", "college", "community_centre", "dog_park", "dune",
    "farmland", "fire_station", "fitness_station", "flowerbed", "forest", "fuel", "garden",
    "glacier", "grass", "grassland", "gravel", "greenery", "greenhouse_horticulture", "ground",
    "heath", "kindergarten", "landfill", "meadow", "miniature_golf", "orchard", "outdoor_seating",
    "park", "parking", "plant_nursery", "playground", "quarry", "railway", "recreation_ground",
    "reef", "rock", "salt_pond", "sand", "school", "schoolyard", "scree", "scrub", "shingle",
    "shoal", "shrub", "shrubbery", "social_facility", "swimming_pool", "traffic_park", "tree_pit",
    "trees", "tundra", "village_green", "vineyard", "wood", "woodchips", "mud",
];

/// Whether the QGIS style draws a fill for this `landuse.class`.
pub fn landuse_has_qgis_fill(class: Option<&str>) -> bool {
    class.is_some_and(|c| QGIS_LANDUSE_CLASSES.contains(&c))
}

// ---------------------------------------------------------------------------------------
// Kerb shade: `kerb shade` layer (Lineburst on `barrier_way` kerbs, kerb != 'flush').
// ---------------------------------------------------------------------------------------

/// Nested offset strokes approximating the Lineburst band (gradient from black at the kerb
/// to transparent at the band edge).
const KERB_SHADE_STEPS: usize = 4;
/// Symbol alpha of the Lineburst symbol (0.2) spread over the nested steps.
const KERB_SHADE_ALPHA: f32 = 0.2;
/// Side of the kerb line that the shade band sits on: +1 right, −1 left of travel.
const KERB_SHADE_SIDE: f64 = 1.0;

/// QGIS `kerb shade`: Lineburst with `offset = mercator × sqrt(S/2800) × 0.5` and
/// `outlineWidth = mercator × sqrt(S/2800)` (both × 0.5 for `kerb = lowered`).
pub fn paint_kerb_shade(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    // `kerb shade` has minScale 8000, but the reference draws it at z15 too (ground scale
    // 1:11 000 there, 1:5 500 at z16). Measured on the z15 tiles: a cut-off of 8000 gives 8.4 %
    // mean on those tiles, 12000 gives 6.8 %. So the gate is 1:12 000.
    if map_scale(extent) > 12000.0 {
        return Ok(());
    }
    let env = envelope_sql();
    let wkb_sql = crate::paint::clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT kerb, {wkb_sql} AS wkb
        FROM barrier_way
        WHERE geom && {env}
          AND barrier = 'kerb'
          AND (kerb IS NULL OR kerb <> 'flush')
        "#
    );
    let rows = query_in_tile(client, prep_cache, timers, &sql, extent)?;
    let merc = mercator_scale(extent.bounds);
    let band_full = (map_scale(extent) / 2800.0).sqrt() * merc;
    let step_alpha = KERB_SHADE_ALPHA / KERB_SHADE_STEPS as f32;
    let black = Color::from_rgba(0.0, 0.0, 0.0, step_alpha).unwrap_or(Color::BLACK);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let kerb: Option<String> = row.try_get("kerb").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let band = band_full * if kerb.as_deref() == Some("lowered") { 0.5 } else { 1.0 };
            for k in 0..KERB_SHADE_STEPS {
                let width = band * (KERB_SHADE_STEPS - k) as f64 / KERB_SHADE_STEPS as f64;
                stroke_lines_offset(
                    pixmap,
                    extent,
                    geom.clone(),
                    black,
                    width,
                    KERB_SHADE_SIDE * width / 2.0,
                );
            }
        }
    });
    Ok(())
}

// ---------------------------------------------------------------------------------------
// Oneway arrows: `highway_oneway` (MarkerLine arrowheads, interval 12 m).
// ---------------------------------------------------------------------------------------

/// Arrow placement and symbol for one QGIS rule.
struct ArrowRule {
    /// Triangle length (= base width) in ground metres.
    size_m: f64,
    /// Along-line offset of the first arrow (metres).
    offset_m: f64,
    /// +1 forward along the line, −1 backward (QGIS `angle` 0 / 180).
    dir: f64,
    outline: Color,
    outline_w_m: f64,
}

const ARROW_INTERVAL_M: f64 = 12.0;

/// The QGIS rules of `highway_oneway` test `"turn:lanes" IS NULL`, but that column is not in
/// the table. QGIS therefore matches no row and draws no arrows (checked on the QGIS
/// reference tiles 17/70425/43010 and 18/140845/86023). Set to `true` once the rule is fixed.
const DRAW_ONEWAY_ARROWS: bool = false;

/// QGIS `highway_oneway` rules 1 and 2 (rule 3, bike lane signs, is not drawn).
pub fn paint_highway_oneway(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    if !DRAW_ONEWAY_ARROWS {
        return Ok(());
    }
    let env = envelope_sql();
    let wkb_sql = crate::paint::clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT highway, "oneway:bicycle" AS oneway_bicycle, {wkb_sql} AS wkb
        FROM highway_oneway
        WHERE geom && {env}
          AND dual_carriageway IS DISTINCT FROM 'yes'
          AND highway IS DISTINCT FROM 'cycleway'
        "#
    );
    let rows = query_in_tile(client, prep_cache, timers, &sql, extent)?;
    let merc = mercator_scale(extent.bounds);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let highway: Option<String> = row.try_get("highway").ok().flatten();
            let oneway_bicycle: Option<String> = row.try_get("oneway_bicycle").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let hw = highway.as_deref().unwrap_or("");
            let foot_like = matches!(hw, "footway" | "path");
            // Rule `oneway=yes`: size 1 / 1.5 / 2.5 m, white outline 0.2 m at alpha 64.
            let main = ArrowRule {
                size_m: if foot_like {
                    1.0
                } else if hw == "service" {
                    1.5
                } else {
                    2.5
                },
                offset_m: 3.0,
                dir: 1.0,
                outline: Color::from_rgba8(255, 255, 255, 64),
                outline_w_m: 0.2,
            };
            stamp_arrows(pixmap, extent, &geom, &main, merc);
            // Rule `oneway:bicycle=no`: backward arrows, size 0.6 / 1 / 2 m.
            if oneway_bicycle.as_deref() == Some("no") {
                let rule = ArrowRule {
                    size_m: if foot_like {
                        0.6
                    } else if hw == "service" {
                        1.0
                    } else {
                        2.0
                    },
                    offset_m: 0.0,
                    dir: -1.0,
                    outline: Color::from_rgba8(191, 172, 197, 191),
                    outline_w_m: 0.3,
                };
                stamp_arrows(pixmap, extent, &geom, &rule, merc);
            }
        }
    });
    Ok(())
}

/// Place arrowheads every 12 ground metres along each part of `geom`.
fn stamp_arrows(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: &Geometry<f64>,
    rule: &ArrowRule,
    merc: f64,
) {
    let mut fill = Paint::default();
    fill.set_color(Color::from_rgba8(255, 0, 0, 255));
    fill.anti_alias = true;
    let mut outline = Paint::default();
    outline.set_color(rule.outline);
    outline.anti_alias = true;
    let stroke = Stroke {
        width: extent.metres_to_px(rule.outline_w_m * merc),
        ..Stroke::default()
    };
    let interval = ARROW_INTERVAL_M * merc;
    let offset = rule.offset_m * merc;
    let half = rule.size_m * merc / 2.0;
    for line in geometry_lines(geom.clone()) {
        let total = polyline_length(&line.0);
        let mut d = offset;
        while d <= total {
            let Some((p, t)) = point_along(&line.0, d) else {
                break;
            };
            d += interval;
            // Unit travel direction, flipped for backward arrows.
            let ux = t.0 * rule.dir;
            let uy = t.1 * rule.dir;
            // Triangle: apex ahead, base behind, base width = size.
            let apex = Coord {
                x: p.x + ux * half,
                y: p.y + uy * half,
            };
            let b1 = Coord {
                x: p.x - ux * half - uy * half,
                y: p.y - uy * half + ux * half,
            };
            let b2 = Coord {
                x: p.x - ux * half + uy * half,
                y: p.y - uy * half - ux * half,
            };
            let mut pb = PathBuilder::new();
            let (x0, y0) = map_to_px(extent, apex);
            let (x1, y1) = map_to_px(extent, b1);
            let (x2, y2) = map_to_px(extent, b2);
            pb.move_to(x0, y0);
            pb.line_to(x1, y1);
            pb.line_to(x2, y2);
            pb.close();
            let Some(path) = pb.finish() else {
                continue;
            };
            pixmap.fill_path(&path, &fill, FillRule::Winding, Transform::identity(), None);
            if stroke.width >= 0.25 && rule.outline.alpha() > 0.0 {
                pixmap.stroke_path(&path, &outline, &stroke, Transform::identity(), None);
            }
        }
    }
}

fn polyline_length(coords: &[Coord<f64>]) -> f64 {
    coords
        .windows(2)
        .map(|w| ((w[1].x - w[0].x).powi(2) + (w[1].y - w[0].y).powi(2)).sqrt())
        .sum()
}

/// Point and unit tangent `distance` map units along a polyline.
fn point_along(coords: &[Coord<f64>], distance: f64) -> Option<(Coord<f64>, (f64, f64))> {
    let mut acc = 0.0;
    for w in coords.windows(2) {
        let (a, b) = (w[0], w[1]);
        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let len = (dx * dx + dy * dy).sqrt();
        if len < 1e-12 {
            continue;
        }
        if acc + len >= distance {
            let t = (distance - acc) / len;
            let p = Coord {
                x: a.x + dx * t,
                y: a.y + dy * t,
            };
            return Some((p, (dx / len, dy / len)));
        }
        acc += len;
    }
    None
}

// ---------------------------------------------------------------------------------------
// Tunnel entrances: `tunnel_entrance outline` (type = road) and `tunnel_entrance shade`.
// ---------------------------------------------------------------------------------------

/// Shade: GradientFill black (alpha 210) → transparent between two per-feature reference
/// points, at layer opacity 0.5.
const TUNNEL_SHADE_ALPHA: f32 = 210.0 / 255.0 * 0.5;

pub fn paint_tunnel_entrance(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let sql = format!(
        r#"
        SELECT type, grad_x1, grad_y1, grad_x2, grad_y2, ST_AsBinary(geom) AS wkb
        FROM tunnel_entrance
        WHERE geom && {env}
        "#
    );
    let rows = query_in_tile(client, prep_cache, timers, &sql, extent)?;
    let merc = mercator_scale(extent.bounds);
    let mut parts = Vec::with_capacity(rows.len());
    for row in &rows {
        let kind: Option<String> = row.try_get("type").ok().flatten();
        let g: [Option<f64>; 4] = [
            row.try_get("grad_x1").ok().flatten(),
            row.try_get("grad_y1").ok().flatten(),
            row.try_get("grad_x2").ok().flatten(),
            row.try_get("grad_y2").ok().flatten(),
        ];
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        let Ok(geom) = decode_wkb(&wkb) else {
            continue;
        };
        parts.push((kind, g, geom));
    }
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        // `tunnel entrance shade` (drawn first, the outline sits above it).
        for (_, g, geom) in &parts {
            let polys = geometry_polygons(geom.clone());
            let (Some(gx1), Some(gy1), Some(gx2), Some(gy2)) = (g[0], g[1], g[2], g[3]) else {
                continue;
            };
            let Some((minx, miny, maxx, maxy)) = bbox_of(&polys) else {
                continue;
            };
            let p1 = Coord {
                x: minx + gx1 * (maxx - minx),
                y: miny + gy1 * (maxy - miny),
            };
            let p2 = Coord {
                x: minx + gx2 * (maxx - minx),
                y: miny + gy2 * (maxy - miny),
            };
            let (x1, y1) = map_to_px(extent, p1);
            let (x2, y2) = map_to_px(extent, p2);
            let stops = vec![
                GradientStop::new(0.0, Color::from_rgba(0.0, 0.0, 0.0, TUNNEL_SHADE_ALPHA).unwrap_or(Color::BLACK)),
                GradientStop::new(1.0, Color::from_rgba8(0, 0, 0, 0)),
            ];
            let Some(shader) = LinearGradient::new(
                Point::from_xy(x1, y1),
                Point::from_xy(x2, y2),
                stops,
                SpreadMode::Pad,
                Transform::identity(),
            ) else {
                continue;
            };
            let mut paint = Paint::default();
            paint.shader = shader;
            paint.anti_alias = true;
            for poly in &polys {
                if let Some(path) = polygon_to_path(extent, poly) {
                    pixmap.fill_path(&path, &paint, FillRule::EvenOdd, Transform::identity(), None);
                }
            }
        }
        // `tunnel entrance outline` (type = road): the two portal walls plus the threshold,
        // the last extended by 0.15 m at both ends. Ring points 1–5 (QGIS `point_n`).
        let mut outline = Paint::default();
        outline.set_color(Color::from_rgba8(96, 96, 96, 255));
        outline.anti_alias = true;
        let stroke = Stroke {
            width: extent.metres_to_px(0.3 * merc).max(0.5),
            ..Stroke::default()
        };
        for (kind, _, geom) in &parts {
            if kind.as_deref() != Some("road") {
                continue;
            }
            for poly in geometry_polygons(geom.clone()) {
                let c = &poly.exterior().0;
                if c.len() < 5 {
                    continue;
                }
                let ext = 0.15 * merc;
                let thr = extend_segment(c[3], c[4], ext);
                let segs = [(c[0], c[1]), (c[2], c[3]), thr];
                for (a, b) in segs {
                    let mut pb = PathBuilder::new();
                    let (x0, y0) = map_to_px(extent, a);
                    let (x1, y1) = map_to_px(extent, b);
                    pb.move_to(x0, y0);
                    pb.line_to(x1, y1);
                    if let Some(path) = pb.finish() {
                        pixmap.stroke_path(&path, &outline, &stroke, Transform::identity(), None);
                    }
                }
            }
        }
    });
    Ok(())
}

fn extend_segment(a: Coord<f64>, b: Coord<f64>, ext: f64) -> (Coord<f64>, Coord<f64>) {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-12 {
        return (a, b);
    }
    let (ux, uy) = (dx / len, dy / len);
    (
        Coord {
            x: a.x - ux * ext,
            y: a.y - uy * ext,
        },
        Coord {
            x: b.x + ux * ext,
            y: b.y + uy * ext,
        },
    )
}

fn bbox_of(polys: &[geo_types::Polygon<f64>]) -> Option<(f64, f64, f64, f64)> {
    let mut out: Option<(f64, f64, f64, f64)> = None;
    for poly in polys {
        for c in poly.exterior().0.iter() {
            out = Some(match out {
                None => (c.x, c.y, c.x, c.y),
                Some((a, b, d, e)) => (a.min(c.x), b.min(c.y), d.max(c.x), e.max(c.y)),
            });
        }
    }
    out.filter(|(a, b, d, e)| d > a && e > b)
}

// ---------------------------------------------------------------------------------------
// Traffic calming: `feature_node` rules `hump` and `bump` (RasterMarker PNGs).
// ---------------------------------------------------------------------------------------

/// QGIS RasterMarker symbol alpha per calming rule (`hump` 75 %, `bump` 20 %).
fn calming_alpha(kind: &str) -> f32 {
    match kind {
        "hump" => 0.75,
        _ => 0.2,
    }
}

static HUMP_PNG: OnceLock<Option<Pixmap>> = OnceLock::new();
static BUMP_PNG: OnceLock<Option<Pixmap>> = OnceLock::new();

fn calming_sprite(kind: &str) -> Option<&'static Pixmap> {
    let cell = match kind {
        "hump" => &HUMP_PNG,
        "bump" => &BUMP_PNG,
        _ => return None,
    };
    cell.get_or_init(|| load_style_png(&format!("traffic_calming/{kind}.png")))
        .as_ref()
}

/// Repo-relative `style/symbols/<rel>`: `SRK_REPO_ROOT`, else the nearest ancestor of the
/// working directory that contains `style/symbols`.
fn load_style_png(rel: &str) -> Option<Pixmap> {
    let root = if let Ok(root) = std::env::var("SRK_REPO_ROOT") {
        std::path::PathBuf::from(root)
    } else {
        let mut dir = std::env::current_dir().ok()?;
        loop {
            if dir.join("style/symbols").is_dir() {
                break dir;
            }
            if !dir.pop() {
                return None;
            }
        }
    };
    Pixmap::load_png(root.join("style/symbols").join(rel)).ok()
}

/// QGIS: width/length = `coalesce(width|length, 3) × @mercator_scale` (map units), angle =
/// `direction` (clockwise degrees).
pub fn paint_traffic_calming(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let sql = format!(
        r#"
        SELECT subclass, width, length, direction, ST_AsBinary(geom) AS wkb
        FROM feature_node
        WHERE geom && {env}
          AND class = 'traffic_calming'
          AND subclass IN ('hump', 'bump')
        "#
    );
    let rows = query_in_tile(client, prep_cache, timers, &sql, extent)?;
    let merc = mercator_scale(extent.bounds);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let kind: Option<String> = row.try_get("subclass").ok().flatten();
            let width: Option<f64> = row.try_get::<_, Option<f32>>("width").ok().flatten().map(f64::from);
            let length: Option<f64> = row.try_get::<_, Option<f32>>("length").ok().flatten().map(f64::from);
            let direction: Option<f64> = row.try_get::<_, Option<f32>>("direction").ok().flatten().map(f64::from);
            let Some(kind) = kind.as_deref() else {
                continue;
            };
            let Some(sprite) = calming_sprite(kind) else {
                continue;
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let paint = PixmapPaint {
                opacity: calming_alpha(kind),
                quality: FilterQuality::Bilinear,
                ..PixmapPaint::default()
            };
            let w_px = extent.metres_to_px(width.unwrap_or(3.0) * merc);
            let h_px = extent.metres_to_px(length.unwrap_or(3.0) * merc);
            if w_px <= 0.0 || h_px <= 0.0 {
                continue;
            }
            let (iw, ih) = (sprite.width() as f32, sprite.height() as f32);
            for pt in geometry_points(geom) {
                let (cx, cy) = map_to_px(extent, Coord { x: pt.x(), y: pt.y() });
                let transform = Transform::from_translate(-iw / 2.0, -ih / 2.0)
                    .post_scale(w_px / iw, h_px / ih)
                    .post_rotate(direction.unwrap_or(0.0) as f32)
                    .post_translate(cx, cy);
                pixmap.draw_pixmap(0, 0, sprite.as_ref(), &paint, transform, None);
            }
        }
    });
    Ok(())
}
