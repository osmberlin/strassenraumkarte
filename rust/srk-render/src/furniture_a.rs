//! Batch A furniture: fire hydrant, mobility hub, bike parking (minzoom 17).

use anyhow::Result;
use postgres::Client;
use tiny_skia::Pixmap;

use crate::layers::TableCache;
use crate::paint::{
    clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb, envelope_sql, fill_circles_m,
    fill_polygons, geometry_points, stroke_circles_m, stroke_polygons,
};
use crate::palette::{fill_furniture_pad, stroke_fire_hydrant, stroke_jelbi_ring};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::svg_stamps::{
    bicycle_parking_icon_size_m, bicycle_parking_svg, fire_hydrant_ring_only,
    furniture_restricted_opacity, mobility_hub_svg, SvgStampCatalog,
};
use crate::tile::RenderExtent;

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
    }
    if cache.feature_polygon {
        paint_mobility_hub(client, prep_cache, pixmap, extent, z, svg_stamps, timers)?;
        paint_bike_parking_polygon(client, prep_cache, pixmap, extent, z, svg_stamps, timers)?;
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
            stroke_circles_m(pixmap, extent, geom.clone(), ring, 0.35, 0.2);
            if !fire_hydrant_ring_only(subclass.as_deref()) {
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
            svg_stamps.stamp_at_map(pixmap, extent, rel, cx, cy, 2.2, 2.2, 0.0);
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
            let size_m = bicycle_parking_icon_size_m(subclass.as_deref());
            for pt in geometry_points(geom) {
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
            let size_m = bicycle_parking_icon_size_m(subclass.as_deref());
            svg_stamps.stamp_at_map(pixmap, extent, rel, cx, cy, size_m, size_m, 0.0);
        }
    });
    Ok(())
}
