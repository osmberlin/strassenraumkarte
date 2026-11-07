//! Batch B furniture: barriers, entrances, traffic signals.

use anyhow::Result;
use postgres::Client;
use tiny_skia::Pixmap;

use crate::layers::TableCache;
use crate::paint::{
    clip_line_wkb_sql_fast, clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb,
    envelope_sql, fill_circles_m, fill_polygons, fill_stroke_circles_m, geometry_points,
    marker_line_circles_m, stroke_circles_m, stroke_lines, stroke_polygons,
};
use crate::palette::{
    fill_barrier_polygon_hedge, fill_barrier_polygon_planter, fill_barrier_polygon_wall,
    fill_entrance_generic, fill_entrance_parking, gate_access_fill, stroke_barrier_fence,
    stroke_barrier_hedge, stroke_barrier_kerb, stroke_barrier_palisade, stroke_entrance_parking,
};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::svg_stamps::SvgStampCatalog;
use crate::tile::{mercator_scale, parse_hex_color, RenderExtent};

fn colour_with_alpha(c: tiny_skia::Color, alpha: f32) -> tiny_skia::Color {
    tiny_skia::Color::from_rgba(c.red(), c.green(), c.blue(), alpha).unwrap_or(c)
}

fn wkb_from_row(row: &postgres::Row, col: &str) -> Option<Vec<u8>> {
    let wkb: Option<Vec<u8>> = row.get(col);
    wkb.filter(|b| !b.is_empty())
}

/// B1–B3 paint pass: barriers → entrances → traffic signals (caller gates minzoom).
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
    if z >= 17 {
        if cache.barrier_way {
            paint_barrier_way(client, prep_cache, pixmap, extent, z, timers)?;
        }
        if cache.barrier_node {
            paint_barrier_node(client, prep_cache, pixmap, extent, cache, timers)?;
        }
        if cache.barrier_polygon {
            paint_barrier_polygon(client, prep_cache, pixmap, extent, z, timers)?;
        }
    }
    if cache.feature_node && z >= 18 {
        paint_entrance(client, prep_cache, pixmap, extent, svg_stamps, timers)?;
    }
    if cache.stop_positions && z >= 17 {
        paint_traffic_signals(client, prep_cache, pixmap, extent, cache, svg_stamps, timers)?;
    }
    Ok(())
}

fn paint_barrier_way(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT barrier, kerb, {wkb_sql} AS wkb
        FROM barrier_way
        WHERE geom && {env}
          AND barrier IN (
            'fence', 'wall', 'retaining_wall', 'gate', 'guard_rail', 'railing',
            'chain', 'yes', 'hedge', 'fence;hedge', 'hedge;fence',
            'kerb', 'handrail', 'bollard', 'palisade'
          )
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
            let barrier: Option<String> = row.try_get("barrier").ok().flatten();
            let kerb: Option<String> = row.try_get("kerb").ok().flatten();
            let Some(kind) = barrier.as_deref() else {
                continue;
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            match kind {
                "hedge" | "fence;hedge" | "hedge;fence" => {
                    stroke_lines(pixmap, extent, geom, stroke_barrier_hedge(), 0.5);
                }
                "kerb" => {
                    // QGIS `kerb`: SimpleLine #7e7e7e, width 0.15 m × @mercator_scale; symbol
                    // alpha 20 % for `flush` (#cccccc), 50 % for `lowered`.
                    let (colour, alpha) = match kerb.as_deref() {
                        Some("flush") => (parse_hex_color("#cccccc").unwrap_or(stroke_barrier_kerb()), 0.2),
                        Some("lowered") => (stroke_barrier_kerb(), 0.5),
                        _ => (stroke_barrier_kerb(), 1.0),
                    };
                    let colour = colour_with_alpha(colour, alpha);
                    stroke_lines(
                        pixmap,
                        extent,
                        geom,
                        colour,
                        0.15 * mercator_scale(extent.bounds),
                    );
                }
                "handrail" => {
                    stroke_lines(pixmap, extent, geom, stroke_barrier_fence(), 0.08);
                }
                "bollard" => {
                    marker_line_circles_m(
                        pixmap,
                        extent,
                        geom,
                        stroke_barrier_fence(),
                        0.4,
                        2.0,
                    );
                }
                "palisade" => {
                    marker_line_circles_m(
                        pixmap,
                        extent,
                        geom,
                        stroke_barrier_palisade(),
                        0.2,
                        0.2,
                    );
                }
                "fence" | "wall" | "retaining_wall" | "gate" | "guard_rail" | "railing"
                | "chain" | "yes" => {
                    stroke_lines(pixmap, extent, geom, stroke_barrier_fence(), 0.1);
                }
                _ => {}
            }
        }
    });
    Ok(())
}

fn paint_barrier_node(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    cache: &TableCache,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let foot_col = if cache.barrier_node_has_foot {
        "foot,"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT barrier, {foot_col} {wkb_sql} AS wkb
        FROM barrier_node
        WHERE geom && {env}
          AND ST_Intersects(geom, {env})
          AND barrier IN (
            'bollard', 'cycle_barrier',
            'gate', 'bump_gate', 'kissing_gate', 'lift_gate', 'sliding_gate',
            'swing_gate', 'turnstile', 'full-height_turnstile'
          )
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
    let gate_stroke = parse_hex_color("#232323").unwrap_or(stroke_barrier_fence());
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let barrier: Option<String> = row.try_get("barrier").ok().flatten();
            let Some(kind) = barrier.as_deref() else {
                continue;
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            match kind {
                "bollard" => {
                    fill_circles_m(pixmap, extent, geom, stroke_barrier_fence(), 0.2);
                }
                "cycle_barrier" => {
                    stroke_circles_m(pixmap, extent, geom.clone(), gate_stroke, 1.0, 0.12);
                    stroke_circles_m(pixmap, extent, geom, gate_stroke, 0.65, 0.12);
                }
                "gate" | "bump_gate" | "kissing_gate" | "lift_gate" | "sliding_gate"
                | "swing_gate" | "turnstile" | "full-height_turnstile" => {
                    let foot: Option<String> = if cache.barrier_node_has_foot {
                        row.try_get("foot").ok().flatten()
                    } else {
                        None
                    };
                    let fill = gate_access_fill(foot.as_deref());
                    fill_stroke_circles_m(pixmap, extent, geom, fill, gate_stroke, 0.375, 0.1);
                }
                _ => {}
            }
        }
    });
    Ok(())
}

fn paint_barrier_polygon(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT barrier, {wkb_sql} AS wkb
        FROM barrier_polygon
        WHERE geom && {env}
          AND barrier IN ('hedge', 'fence;hedge', 'hedge;fence', 'planter', 'wall')
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
            let barrier: Option<String> = row.try_get("barrier").ok().flatten();
            let Some(kind) = barrier.as_deref() else {
                continue;
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let (fill, outline, outline_w) = match kind {
                "hedge" | "fence;hedge" | "hedge;fence" => {
                    (fill_barrier_polygon_hedge(), None, 0.0)
                }
                "planter" => (
                    fill_barrier_polygon_planter(),
                    Some(stroke_barrier_fence()),
                    0.06,
                ),
                "wall" => (
                    fill_barrier_polygon_wall(),
                    Some(stroke_barrier_fence()),
                    0.1,
                ),
                _ => continue,
            };
            fill_polygons(pixmap, extent, geom.clone(), fill);
            if let Some(outline) = outline {
                stroke_polygons(pixmap, extent, geom, outline, outline_w);
            }
        }
    });
    Ok(())
}

fn paint_entrance(
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
        WHERE class = 'entrance'
          AND geom && {env}
          AND ST_Intersects(geom, {env})
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
    let generic_stroke = stroke_barrier_fence();
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let sub = subclass.as_deref().unwrap_or("");
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            if sub == "parking_entrance" {
                fill_stroke_circles_m(
                    pixmap,
                    extent,
                    geom,
                    fill_entrance_parking(),
                    stroke_entrance_parking(),
                    0.4,
                    0.2,
                );
            } else if sub.contains("subway") {
                for pt in geometry_points(geom) {
                    svg_stamps.stamp_at_map(
                        pixmap,
                        extent,
                        "public_transport/subway.svg",
                        pt.x(),
                        pt.y(),
                        2.0,
                        2.0,
                        0.0,
                    );
                }
            } else if sub.contains("s-train") {
                for pt in geometry_points(geom) {
                    svg_stamps.stamp_at_map(
                        pixmap,
                        extent,
                        "public_transport/s-train.svg",
                        pt.x(),
                        pt.y(),
                        2.2,
                        2.2,
                        0.0,
                    );
                }
            } else {
                fill_stroke_circles_m(
                    pixmap,
                    extent,
                    geom,
                    fill_entrance_generic(),
                    generic_stroke,
                    0.3,
                    0.03,
                );
            }
        }
    });
    Ok(())
}

fn paint_traffic_signals(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    cache: &TableCache,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let az_col = if cache.stop_positions_has_road_azimuth {
        "road_azimuth,"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT {az_col} {wkb_sql} AS wkb
        FROM stop_positions
        WHERE highway = 'traffic_signals'
          AND geom && {env}
          AND ST_Intersects(geom, {env})
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
            let direction = if cache.stop_positions_has_road_azimuth {
                row.try_get::<_, Option<i32>>("road_azimuth")
                    .ok()
                    .flatten()
                    .map(|a| a as f32)
                    .unwrap_or(0.0)
            } else {
                0.0
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            for pt in geometry_points(geom) {
                svg_stamps.stamp_at_map(
                    pixmap,
                    extent,
                    "highway/traffic_signals.svg",
                    pt.x(),
                    pt.y(),
                    2.0,
                    2.0,
                    direction,
                );
            }
        }
    });
    Ok(())
}
