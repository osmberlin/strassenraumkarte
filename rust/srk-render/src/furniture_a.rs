//! Batch A furniture: fire hydrant, mobility hub, bike parking, feature-node street furniture (minzoom 17).

use anyhow::Result;
use geo_types::Coord;
use postgres::Client;
use tiny_skia::{Color, FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};

use crate::layers::TableCache;
use crate::paint::{
    clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb, envelope_sql, fill_circles_m,
    fill_polygons, geometry_points, map_to_px, stroke_circles_m, stroke_polygons,
};
use crate::palette::{fill_furniture_pad, stroke_fire_hydrant, stroke_jelbi_ring};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::svg_stamps::{
    bicycle_parking_icon_size_m, bicycle_parking_svg, fire_hydrant_ring_only,
    furniture_restricted_opacity, mobility_hub_svg, SvgStampCatalog,
};
use crate::tile::{mercator_scale, parse_hex_color, RenderExtent};

fn wkb_from_row(row: &postgres::Row, col: &str) -> Option<Vec<u8>> {
    let wkb: Option<Vec<u8>> = row.get(col);
    wkb.filter(|b| !b.is_empty())
}

pub fn paint(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    cache: &TableCache,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    if z < 17 {
        return Ok(());
    }
    if cache.feature_node {
        paint_fire_hydrant(client, prep_cache, pixmap, extent, svg_stamps, timers)?;
        paint_bike_parking_node(client, prep_cache, pixmap, extent, svg_stamps, timers)?;
        paint_feature_node_furniture(client, prep_cache, pixmap, extent, svg_stamps, timers)?;
    }
    if cache.feature_polygon {
        paint_mobility_hub(client, prep_cache, pixmap, extent, z, svg_stamps, timers)?;
        paint_bike_parking_polygon(client, prep_cache, pixmap, extent, z, svg_stamps, timers)?;
        paint_feature_polygon_furniture(client, prep_cache, pixmap, extent, z, svg_stamps, timers)?;
    }
    Ok(())
}

fn paint_fire_hydrant(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT subclass, {wkb_sql} AS wkb
        FROM feature_node
        WHERE class = 'fire_hydrant'
          AND geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY 1
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        let mut ring = stroke_fire_hydrant();
        ring.set_alpha(1.0);
        for row in &rows {
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            // QGIS: the red ring is opaque only for pillar/pipe/wall (other outlines are alpha 0);
            // the "H" font marker is hidden for those and above 1:1500 (`@map_scale > 1500`).
            let ring_only = fire_hydrant_ring_only(subclass.as_deref());
            if ring_only {
                stroke_circles_m(pixmap, extent, geom.clone(), ring, 0.35, 0.2);
            }
            if !ring_only && scale_le_1500(extent) {
                for pt in geometry_points(geom) {
                    svg_stamps.stamp_char_at_map(
                        pixmap,
                        extent,
                        'H',
                        "#ff0000",
                        pt.x(),
                        pt.y(),
                        0.7,
                    );
                }
            }
        }
    });
    Ok(())
}

fn paint_mobility_hub(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT
          subclass,
          ST_X(ST_Centroid(geom)) AS cx,
          ST_Y(ST_Centroid(geom)) AS cy,
          {wkb_sql} AS wkb
        FROM feature_polygon
        WHERE class = 'mobility_hub'
          AND geom && {env}
        ORDER BY 1
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        let mut fill = fill_furniture_pad();
        fill.set_alpha(0.67);
        let mut jelbi = stroke_jelbi_ring();
        jelbi.set_alpha(0.5);
        for row in &rows {
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            fill_polygons(pixmap, extent, geom.clone(), fill);
            if subclass
                .as_deref()
                .map(|s| s.contains("Jelbi"))
                .unwrap_or(false)
            {
                stroke_polygons(pixmap, extent, geom.clone(), jelbi, 0.5);
            }
            let cx: f64 = row.get("cx");
            let cy: f64 = row.get("cy");
            let rel = mobility_hub_svg(subclass.as_deref());
            // QGIS `mobility_hub (symbol)` is limited to scale ≤ 1:750.
            if scale_le_750(extent) {
                svg_stamps.stamp_at_map(pixmap, extent, rel, cx, cy, 2.2, 2.2, 0.0);
            }
        }
    });
    Ok(())
}

fn paint_bike_parking_node(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT class, subclass, access, {wkb_sql} AS wkb
        FROM feature_node
        WHERE class IN ('bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking')
          AND geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY 1
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        let mut pad = fill_furniture_pad();
        for row in &rows {
            let class: String = row.get("class");
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let access: Option<String> = row.try_get("access").ok().flatten();
            let opacity = furniture_restricted_opacity(access.as_deref());
            pad.set_alpha(0.67 * opacity);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            fill_circles_m(pixmap, extent, geom.clone(), pad, 0.75);
            let rel = bicycle_parking_svg(&class, subclass.as_deref());
            // QGIS: `@mercator_scale * (1.8 | 2.2)` ground metres.
            let size_m = bicycle_parking_icon_size_m(subclass.as_deref()) * mercator_scale(extent.bounds);
            // The bicycle symbol is a `(symbol)` rule limited to scale ≤ 1:750 in QGIS.
            for pt in geometry_points(geom).into_iter().filter(|_| scale_le_750(extent)) {
                svg_stamps.stamp_at_map(
                    pixmap,
                    extent,
                    rel,
                    pt.x(),
                    pt.y(),
                    size_m,
                    size_m,
                    0.0,
                );
            }
        }
    });
    Ok(())
}

/// `@map_scale ≤ 1500` in QGIS (EPSG:3857 map units, see [`scale_le_750`]).
fn scale_le_1500(extent: RenderExtent) -> bool {
    extent.metres_per_px() <= 1500.0 * 0.0254 / 96.0
}

/// QGIS rules with `scalemaxdenom 750` (≤ 1:750). QGIS derives the map scale from EPSG:3857
/// map units (no latitude correction): 1:750 at 96 dpi is 0.198 map metres per pixel, which
/// is z20 (z19 is 0.299 and does not show the symbol in the QGIS reference).
fn scale_le_750(extent: RenderExtent) -> bool {
    extent.metres_per_px() <= 750.0 * 0.0254 / 96.0
}

fn paint_bike_parking_polygon(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT
          class,
          subclass,
          access,
          ST_X(ST_Centroid(geom)) AS cx,
          ST_Y(ST_Centroid(geom)) AS cy,
          {wkb_sql} AS wkb
        FROM feature_polygon
        WHERE class IN ('bicycle_parking', 'bicycle_rental', 'small_electric_vehicle_parking')
          AND geom && {env}
        ORDER BY 1
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        let mut fill = fill_furniture_pad();
        for row in &rows {
            let class: String = row.get("class");
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let access: Option<String> = row.try_get("access").ok().flatten();
            let opacity = furniture_restricted_opacity(access.as_deref());
            fill.set_alpha(0.67 * opacity);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            fill_polygons(pixmap, extent, geom, fill);
            let cx: f64 = row.get("cx");
            let cy: f64 = row.get("cy");
            let rel = bicycle_parking_svg(&class, subclass.as_deref());
            let size_m = bicycle_parking_icon_size_m(subclass.as_deref()) * mercator_scale(extent.bounds);
            if scale_le_750(extent) {
                svg_stamps.stamp_at_map(pixmap, extent, rel, cx, cy, size_m, size_m, 0.0);
            }
        }
    });
    Ok(())
}

// ---------------------------------------------------------------------------
// feature_node (middleground) street furniture
// ---------------------------------------------------------------------------
//
// Rules transcribed from the QGIS project (`feature_node (middleground)`). Every size is a QGIS
// `@mercator_scale * X` expression, i.e. X ground metres; `Rot::Dir(off)` is the QGIS
// `"direction" + off` data-defined angle (clockwise, OSM bearing). Symbol alpha is applied to SVGs
// and shapes. Classes already painted above (fire hydrant, bicycle parking, mobility hub) and the
// foreground / polygon layers are not handled here.

/// Node classes this painter reads from `feature_node`.
const FURNITURE_NODE_CLASSES: &[&str] = &[
    "manhole",
    "waste_basket",
    "bench",
    "street_cabinet",
    "pole",
    "post_box",
    "recycling",
    "table_tennis",
    "picnic_table",
    "table",
    "artwork",
    "advertising_column",
    "vending_machine",
    "charging_station",
    "drinking_water",
    "clock",
    "water_well",
    "planter",
    "monitoring_station",
    "shelter",
    "fountain",
    "grit_bin",
    "information",
    "telephone",
    "street_lamp",
    "traffic_sign",
];

#[derive(Clone, Copy)]
enum Rot {
    /// No data-defined angle (QGIS static 0).
    Fixed,
    /// `"direction" + offset`.
    Dir(f64),
}

#[derive(Clone, Copy)]
enum Mark {
    /// SVG from `style/symbols/`, ground-metre size.
    Svg {
        rel: &'static str,
        size: f64,
        rot: Rot,
        alpha: f32,
    },
    /// Filled circle with an outline ring.
    Disc {
        size: f64,
        fill: &'static str,
        outline: &'static str,
        outline_w: f64,
        alpha: f32,
    },
    /// Filled rectangle (square markers, crosses), rotated about its centre.
    Rect {
        w: f64,
        h: f64,
        fill: &'static str,
        outline: &'static str,
        outline_w: f64,
        rot: Rot,
        alpha: f32,
    },
}

/// Marks for one feature node. Empty when QGIS draws nothing for it.
fn furniture_marks(
    class: &str,
    subclass: Option<&str>,
    support: Option<&str>,
    has_direction: bool,
) -> Vec<Mark> {
    let sub = subclass.unwrap_or("");
    let svg = |rel: &'static str, size: f64, rot: Rot, alpha: f32| Mark::Svg { rel, size, rot, alpha };
    match class {
        "manhole" => vec![svg("man_made/manhole.svg", 0.75, Rot::Fixed, 0.5)],
        "waste_basket" => vec![svg("amenity/waste_basket.svg", 0.8, Rot::Fixed, 1.0)],
        "bench" => {
            let rel = if sub.contains("backrest_no") {
                "amenity/bench_backrest_no.svg"
            } else {
                "amenity/bench.svg"
            };
            vec![svg(rel, 1.7, Rot::Dir(-180.0), 1.0)]
        }
        "street_cabinet" => vec![Mark::Rect {
            w: 0.8,
            h: 0.8,
            fill: "#63d9c6",
            outline: "#808080",
            outline_w: 0.05,
            rot: Rot::Dir(90.0),
            alpha: 1.0,
        }],
        "pole" => vec![Mark::Disc {
            size: 0.5,
            fill: "#808080",
            outline: "#808080",
            outline_w: 0.0,
            alpha: 1.0,
        }],
        "post_box" => {
            let rel = if sub == "PIN Mail" {
                "amenity/post_box_green.svg"
            } else {
                "amenity/post_box_yellow.svg"
            };
            vec![svg(rel, 1.2, Rot::Fixed, 0.5)]
        }
        "recycling" => vec![svg("amenity/recycling.svg", 1.4, Rot::Fixed, 1.0)],
        "table_tennis" => {
            let rel = if sub.contains("net_no") {
                "leisure/table_tennis_net_no.svg"
            } else if sub.contains("net_yes") {
                "leisure/table_tennis_net_yes.svg"
            } else {
                "leisure/table_tennis.svg"
            };
            vec![svg(rel, 1.7, Rot::Dir(0.0), 1.0)]
        }
        "picnic_table" | "table" => vec![svg("leisure/picnic_table.svg", 1.75, Rot::Fixed, 1.0)],
        "artwork" => vec![svg("tourism/artwork.svg", 1.6, Rot::Fixed, 0.67)],
        "advertising_column" => vec![Mark::Disc {
            size: 1.6,
            fill: "#d0d0c5",
            outline: "#505050",
            outline_w: 0.2,
            alpha: 1.0,
        }],
        "vending_machine" => {
            let (s, rot) = if sub == "parking_tickets" {
                (0.5, Rot::Dir(90.0))
            } else {
                (0.3, Rot::Dir(90.0))
            };
            vec![Mark::Rect {
                w: s,
                h: s,
                fill: "#63d9c6",
                outline: "#808080",
                outline_w: 0.04,
                rot,
                alpha: 1.0,
            }]
        }
        "charging_station" => vec![Mark::Rect {
            w: 0.5,
            h: 0.5,
            fill: "#74b0d9",
            outline: "#505050",
            outline_w: 0.05,
            rot: Rot::Dir(0.0),
            alpha: 1.0,
        }],
        "drinking_water" => vec![Mark::Disc {
            size: 0.6,
            fill: "#d6d8ed",
            outline: "#505050",
            outline_w: 0.06,
            alpha: 1.0,
        }],
        "clock" => {
            if matches!(support, Some("wall" | "wall_mounted")) {
                vec![]
            } else {
                vec![Mark::Rect {
                    w: 0.6,
                    h: 0.6,
                    fill: "#63d9c6",
                    outline: "#232323",
                    outline_w: 0.06,
                    rot: Rot::Fixed,
                    alpha: 1.0,
                }]
            }
        }
        "water_well" => vec![Mark::Disc {
            size: 1.25,
            fill: "#808080",
            outline: "#232323",
            outline_w: 0.0,
            alpha: 1.0,
        }],
        "planter" => vec![Mark::Disc {
            size: 0.75,
            fill: "#c7d6b8",
            outline: "#505050",
            outline_w: 0.12,
            alpha: 1.0,
        }],
        "monitoring_station" => vec![Mark::Disc {
            size: 0.3,
            fill: "#808080",
            outline: "#505050",
            outline_w: 0.0,
            alpha: 1.0,
        }],
        "shelter" => vec![Mark::Disc {
            size: 3.0,
            fill: "#dadada",
            outline: "#505050",
            outline_w: 0.12,
            alpha: 1.0,
        }],
        "fountain" => vec![
            Mark::Disc {
                size: 3.2,
                fill: "#cac7ed",
                outline: "#505050",
                outline_w: 0.12,
                alpha: 1.0,
            },
            svg("amenity/fountain.svg", 3.2, Rot::Fixed, 1.0),
        ],
        "grit_bin" => vec![Mark::Rect {
            w: 1.0,
            h: 1.0,
            fill: "#e9a95f",
            outline: "#8b8579",
            outline_w: 0.2,
            rot: Rot::Dir(90.0),
            alpha: 1.0,
        }],
        "information" if sub == "guidepost" => {
            vec![svg("tourism/guidepost.svg", 1.8, Rot::Fixed, 1.0)]
        }
        "telephone" => vec![svg("amenity/telephone.svg", 1.2, Rot::Fixed, 1.0)],
        "street_lamp" => {
            if sub.contains("bent_mast") && has_direction {
                vec![svg(
                    "highway/street_lamp_bent_mast.svg",
                    6.0,
                    Rot::Dir(-90.0),
                    1.0,
                )]
            } else if sub.contains("wall") && has_direction {
                // Wall lamps are a bracket plus lamp head; not approximated.
                vec![]
            } else {
                vec![
                    Mark::Disc {
                        size: 0.67,
                        fill: "#dadada",
                        outline: "#808080",
                        outline_w: 0.11,
                        alpha: 1.0,
                    },
                    // QGIS `cross2` at 0.45 m: a stroked cross; its colour is the outline grey.
                    Mark::Rect {
                        w: 0.45,
                        h: 0.11,
                        fill: "#808080",
                        outline: "#808080",
                        outline_w: 0.0,
                        rot: Rot::Fixed,
                        alpha: 1.0,
                    },
                    Mark::Rect {
                        w: 0.11,
                        h: 0.45,
                        fill: "#808080",
                        outline: "#808080",
                        outline_w: 0.0,
                        rot: Rot::Fixed,
                        alpha: 1.0,
                    },
                ]
            }
        }
        "traffic_sign" => {
            if sub.contains("222") {
                let rel = if sub.contains("222-10") {
                    "traffic_signs/DE/222-10.svg"
                } else {
                    "traffic_signs/DE/222.svg"
                };
                vec![svg(rel, 0.9, Rot::Dir(180.0), 1.0)]
            } else if sub.contains("605") {
                // Vertical panels: sign-number specific artwork not transcribed.
                vec![]
            } else if sub.contains("street_name_sign") {
                vec![svg(
                    "traffic_signs/street_name_sign.svg",
                    1.4,
                    Rot::Dir(180.0),
                    1.0,
                )]
            } else {
                // General sign: pentagon sign head (the pole is sub-pixel at these scales).
                let size = if matches!(support, Some("pole") | None) {
                    0.67
                } else {
                    0.33
                };
                vec![Mark::Disc {
                    size,
                    fill: "#ededed",
                    outline: "#808080",
                    outline_w: 0.11,
                    alpha: 0.5,
                }]
            }
        }
        _ => vec![],
    }
}

fn rot_deg(rot: Rot, direction: Option<f32>) -> f32 {
    match (rot, direction) {
        (Rot::Dir(off), Some(d)) => d + off as f32,
        _ => 0.0,
    }
}

fn paint_furniture_mark(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    svg_stamps: &SvgStampCatalog,
    cx: f64,
    cy: f64,
    direction: Option<f32>,
    mark: Mark,
) {
    let merc = mercator_scale(extent.bounds);
    match mark {
        Mark::Svg {
            rel,
            size,
            rot,
            alpha,
        } => {
            let s = size * merc;
            svg_stamps.stamp_at_map_opacity(
                pixmap,
                extent,
                rel,
                cx,
                cy,
                s,
                s,
                rot_deg(rot, direction),
                alpha,
            );
        }
        Mark::Disc {
            size,
            fill,
            outline,
            outline_w,
            alpha,
        } => {
            let (px, py) = map_to_px(extent, Coord { x: cx, y: cy });
            let r = extent.metres_to_px(size * merc / 2.0);
            if r * r * std::f32::consts::PI < 0.25 {
                return;
            }
            let Some(path) = PathBuilder::from_circle(px, py, r) else {
                return;
            };
            let mut fill_c = parse_hex_color(fill).unwrap_or(Color::BLACK);
            fill_c.set_alpha(alpha);
            let mut paint = Paint::default();
            paint.set_color(fill_c);
            paint.anti_alias = true;
            pixmap.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
            if outline_w > 0.0 {
                let mut stroke_c = parse_hex_color(outline).unwrap_or(Color::BLACK);
                stroke_c.set_alpha(alpha);
                let mut sp = Paint::default();
                sp.set_color(stroke_c);
                sp.anti_alias = true;
                let stroke = Stroke {
                    width: extent.metres_to_px(outline_w * merc).max(0.5),
                    ..Stroke::default()
                };
                pixmap.stroke_path(&path, &sp, &stroke, Transform::identity(), None);
            }
        }
        Mark::Rect {
            w,
            h,
            fill,
            outline,
            outline_w,
            rot,
            alpha,
        } => {
            let (px, py) = map_to_px(extent, Coord { x: cx, y: cy });
            let hw = extent.metres_to_px(w * merc / 2.0);
            let hh = extent.metres_to_px(h * merc / 2.0);
            if 4.0 * hw * hh < 0.25 {
                return;
            }
            let Some(rect) = tiny_skia::Rect::from_ltrb(-hw, -hh, hw, hh) else {
                return;
            };
            let path = PathBuilder::from_rect(rect);
            let t = Transform::from_rotate(rot_deg(rot, direction)).post_translate(px, py);
            let mut fill_c = parse_hex_color(fill).unwrap_or(Color::BLACK);
            fill_c.set_alpha(alpha);
            let mut paint = Paint::default();
            paint.set_color(fill_c);
            paint.anti_alias = true;
            pixmap.fill_path(&path, &paint, FillRule::Winding, t, None);
            if outline_w > 0.0 {
                let mut stroke_c = parse_hex_color(outline).unwrap_or(Color::BLACK);
                stroke_c.set_alpha(alpha);
                let mut sp = Paint::default();
                sp.set_color(stroke_c);
                sp.anti_alias = true;
                let stroke = Stroke {
                    width: extent.metres_to_px(outline_w * merc).max(0.5),
                    ..Stroke::default()
                };
                pixmap.stroke_path(&path, &sp, &stroke, t, None);
            }
        }
    }
}

/// `feature_node (middleground)` street furniture: manhole, bins, benches, lamps, signs, …
fn paint_feature_node_furniture(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let classes = FURNITURE_NODE_CLASSES
        .iter()
        .map(|c| format!("'{c}'"))
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!(
        r#"
        SELECT class, subclass, support, direction::real AS direction, {wkb_sql} AS wkb
        FROM feature_node
        WHERE class IN ({classes})
          AND geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: String = row.get("class");
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let support: Option<String> = row.try_get("support").ok().flatten();
            let direction: Option<f32> = row.try_get("direction").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let marks = furniture_marks(
                &class,
                subclass.as_deref(),
                support.as_deref(),
                direction.is_some(),
            );
            if marks.is_empty() {
                continue;
            }
            for pt in geometry_points(geom) {
                for mark in &marks {
                    paint_furniture_mark(
                        pixmap,
                        extent,
                        svg_stamps,
                        pt.x(),
                        pt.y(),
                        direction,
                        *mark,
                    );
                }
            }
        }
    });
    Ok(())
}

/// `feature_polygon (middleground)` small street-furniture areas: recycling containers, waste
/// disposal, toilets, skatepark obstacles. Fill (+ outline) in QGIS colours; recycling areas get
/// the recycling symbol at their centroid. Recycling areas are limited to < 150 m² (QGIS `$area`).
fn paint_feature_polygon_furniture(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT
          class,
          ST_X(ST_Centroid(geom)) AS cx,
          ST_Y(ST_Centroid(geom)) AS cy,
          {wkb_sql} AS wkb
        FROM feature_polygon
        WHERE class IN ('recycling', 'waste_disposal', 'toilets', 'skatepark_obstacle')
          AND (class <> 'recycling' OR ST_Area(geom) < 150)
          AND geom && {env}
        ORDER BY osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[
            &extent.bounds.minx,
            &extent.bounds.miny,
            &extent.bounds.maxx,
            &extent.bounds.maxy,
        ],
    )?;
    let merc = mercator_scale(extent.bounds);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: String = row.get("class");
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let (fill_hex, outline_hex, outline_g) = match class.as_str() {
                "recycling" | "waste_disposal" => ("#dadada", "#808080", 0.02),
                "toilets" => ("#cbcbcb", "#808080", 0.05),
                "skatepark_obstacle" => ("#aba7a0", "#93958f", 0.12),
                _ => continue,
            };
            let fill = parse_hex_color(fill_hex).unwrap_or(Color::BLACK);
            fill_polygons(pixmap, extent, geom.clone(), fill);
            if outline_g >= 0.05 {
                let outline = parse_hex_color(outline_hex).unwrap_or(Color::BLACK);
                stroke_polygons(pixmap, extent, geom, outline, outline_g * merc);
            }
            if class == "recycling" {
                let cx: f64 = row.get("cx");
                let cy: f64 = row.get("cy");
                svg_stamps.stamp_at_map_opacity(
                    pixmap,
                    extent,
                    "amenity/recycling.svg",
                    cx,
                    cy,
                    1.4 * merc,
                    1.4 * merc,
                    0.0,
                    1.0,
                );
            }
        }
    });
    Ok(())
}
