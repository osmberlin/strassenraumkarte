//! Layer paint passes for `highway_area` isolate and `full-approx`.

use anyhow::{Context, Result};
use postgres::Client;
use tiny_skia::Pixmap;

use crate::paint::{
    clip_line_wkb_sql, clip_point_wkb_sql, clip_polygon_wkb_sql, decode_wkb, envelope_sql,
    fill_circles_m, fill_polygons, fill_polygons_batch_with_shadow, fill_tree_crown_soft,
    stroke_lines, DropShadow,
};
use crate::palette::{
    fill_building, fill_building_shade, fill_for_area_highway, fill_for_landuse, fill_pitch,
    fill_tree_crown, fill_tree_trunk, fill_water, stroke_path, stroke_service, stroke_waterway,
    AREA_HIGHWAY_PAINTED,
};
use crate::tile::{parse_hex_color, tile_bounds_3857, TileBounds, DEFAULT_BACKGROUND, TILE_SIZE_PX};

fn opt_f32(row: &postgres::Row, col: &str) -> Option<f32> {
    row.try_get::<_, Option<f32>>(col).ok().flatten()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayerPreset {
    HighwayArea,
    FullApprox,
}

impl LayerPreset {
    pub fn parse(layers: &[String]) -> Result<Self> {
        let names: Vec<String> = layers
            .iter()
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        if names.len() == 1 && names[0] == "highway_area" {
            return Ok(Self::HighwayArea);
        }
        if names.len() == 1 && (names[0] == "full-approx" || names[0] == "full_approx") {
            return Ok(Self::FullApprox);
        }
        anyhow::bail!(
            "supported --layers: highway_area | full-approx (got {:?})",
            layers
        )
    }
}

fn empty_pixmap() -> Result<Pixmap> {
    let bg = parse_hex_color(DEFAULT_BACKGROUND)?;
    let mut pixmap = Pixmap::new(TILE_SIZE_PX, TILE_SIZE_PX).context("pixmap alloc")?;
    pixmap.fill(bg);
    Ok(pixmap)
}

fn save_png(pixmap: &Pixmap, out_path: &std::path::Path) -> Result<()> {
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    pixmap.save_png(out_path)?;
    Ok(())
}

fn table_exists(client: &mut Client, name: &str) -> Result<bool> {
    let row = client.query_one(
        r#"
        SELECT EXISTS (
          SELECT 1 FROM information_schema.tables
          WHERE table_schema = 'public' AND table_name = $1
        )
        "#,
        &[&name],
    )?;
    Ok(row.get(0))
}

fn column_exists(client: &mut Client, table: &str, column: &str) -> Result<bool> {
    let row = client.query_one(
        r#"
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        )
        "#,
        &[&table, &column],
    )?;
    Ok(row.get(0))
}

fn wkb_from_row(row: &postgres::Row, col: &str) -> Option<Vec<u8>> {
    let wkb: Option<Vec<u8>> = row.get(col);
    wkb.filter(|b| !b.is_empty())
}

/// Isolate: `highway_area` class fills only.
pub fn render_highway_area(
    client: &mut Client,
    z: u32,
    x: u32,
    y: u32,
    out_path: &std::path::Path,
    quiet: bool,
) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = empty_pixmap()?;
    let painted = paint_highway_area(client, &mut pixmap, bounds)?;
    save_png(&pixmap, out_path)?;
    if !quiet {
        eprintln!(
            "rendered {z}/{x}/{y} → {} (highway_area parts≈{painted})",
            out_path.display()
        );
    }
    Ok(())
}

fn paint_highway_area(
    client: &mut Client,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
) -> Result<usize> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT
          "area:highway" AS area_highway,
          {wkb_sql} AS wkb
        FROM highway_area
        WHERE geom && {env}
          AND "area:highway" IN {AREA_HIGHWAY_PAINTED}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mut painted = 0usize;
    for row in &rows {
        let area: Option<String> = row.get("area_highway");
        let Some(fill_color) = fill_for_area_highway(area.as_deref()) else {
            continue;
        };
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        match decode_wkb(&wkb) {
            Ok(geom) => {
                fill_polygons(pixmap, bounds, geom, fill_color);
                painted += 1;
            }
            Err(e) => eprintln!("warn: skip highway_area WKB: {e:?}"),
        }
    }
    Ok(painted)
}

/// Full approximate stack: landuse → water → roads → buildings → trees.
///
/// Deferred vs QGIS: labels (PAL), SVG markers, RasterFill textures, full
/// effect stacks (innerShadow/glow), symbol levels, blend modes.
/// Cheap building drop-shadow + soft tree crowns are included.
pub fn render_full_approx(
    client: &mut Client,
    z: u32,
    x: u32,
    y: u32,
    out_path: &std::path::Path,
    quiet: bool,
    cache: &mut TableCache,
) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = empty_pixmap()?;

    paint_landuse(client, &mut pixmap, bounds)?;
    if cache.pitch {
        paint_pitch(client, &mut pixmap, bounds)?;
    }
    if cache.water_body {
        paint_water_body(client, &mut pixmap, bounds)?;
    }
    if cache.waterway {
        paint_waterway(client, &mut pixmap, bounds)?;
    }
    // Streets: path → service → highway_area (matches QGIS / MapLibre sandwich).
    if cache.highway {
        paint_highway_path(client, &mut pixmap, bounds)?;
    }
    if cache.highway_service {
        paint_highway_service(client, &mut pixmap, bounds)?;
    }
    paint_highway_area(client, &mut pixmap, bounds)?;
    if cache.building_shade {
        paint_building_shade(client, &mut pixmap, bounds)?;
    }
    if cache.building_parts {
        paint_building_parts(
            client,
            &mut pixmap,
            bounds,
            cache.building_parts_has_height,
        )?;
    }
    if cache.building {
        paint_building(client, &mut pixmap, bounds)?;
    }
    if cache.tree {
        paint_tree(client, &mut pixmap, bounds)?;
    }

    save_png(&pixmap, out_path)?;
    if !quiet {
        eprintln!("rendered {z}/{x}/{y} → {} (full-approx)", out_path.display());
    }
    Ok(())
}

#[derive(Debug)]
pub struct TableCache {
    pub pitch: bool,
    pub water_body: bool,
    pub waterway: bool,
    pub highway_service: bool,
    pub highway: bool,
    pub building_shade: bool,
    pub building: bool,
    pub building_parts: bool,
    pub tree: bool,
    pub building_parts_has_height: bool,
}

impl TableCache {
    pub fn probe(client: &mut Client) -> Result<Self> {
        Ok(Self {
            pitch: table_exists(client, "pitch")?,
            water_body: table_exists(client, "water_body_dissolved")?,
            waterway: table_exists(client, "waterway_clipped")?,
            highway_service: table_exists(client, "highway_service")?,
            highway: table_exists(client, "highway")?,
            building_shade: table_exists(client, "building_shade")?,
            building: table_exists(client, "building")?,
            building_parts: table_exists(client, "building_parts_dissolved_height")?,
            tree: table_exists(client, "tree")?,
            building_parts_has_height: column_exists(
                client,
                "building_parts_dissolved_height",
                "height",
            )?,
        })
    }
}

fn paint_landuse(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT class, {wkb_sql} AS wkb
        FROM landuse
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let class: Option<String> = row.get("class");
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        match decode_wkb(&wkb) {
            Ok(geom) => fill_polygons(pixmap, bounds, geom, fill_for_landuse(class.as_deref())),
            Err(e) => eprintln!("warn: skip landuse WKB: {e:?}"),
        }
    }
    Ok(())
}

fn paint_pitch(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM pitch
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            fill_polygons(pixmap, bounds, geom, fill_pitch());
        }
    }
    Ok(())
}

fn paint_water_body(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM water_body_dissolved
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            fill_polygons(pixmap, bounds, geom, fill_water());
        }
    }
    Ok(())
}

fn paint_waterway(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT width, {wkb_sql} AS wkb
        FROM waterway_clipped
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let width_m = opt_f32(row, "width")
            .filter(|w| *w > 0.0)
            .map(f64::from)
            .unwrap_or(2.0);
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            stroke_lines(pixmap, bounds, geom, stroke_waterway(), width_m);
        }
    }
    Ok(())
}

fn paint_highway_service(
    client: &mut Client,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT class, width, {wkb_sql} AS wkb
        FROM highway_service
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY COALESCE(layer, 0)
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let class: Option<String> = row.try_get("class").ok().flatten();
        let default_m = match class.as_deref() {
            None | Some("alley") => 4.0,
            _ => 3.0,
        };
        let width_m = opt_f32(row, "width")
            .filter(|w| *w > 0.0)
            .map(f64::from)
            .unwrap_or(default_m);
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            stroke_lines(pixmap, bounds, geom, stroke_service(), width_m);
        }
    }
    Ok(())
}

fn paint_highway_path(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT highway, width, {wkb_sql} AS wkb
        FROM highway
        WHERE type = 'path'
          AND geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let highway: Option<String> = row.try_get("highway").ok().flatten();
        let width_m = opt_f32(row, "width")
            .filter(|w| *w > 0.0)
            .map(f64::from)
            .unwrap_or(1.8);
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            stroke_lines(
                pixmap,
                bounds,
                geom,
                stroke_path(highway.as_deref()),
                width_m,
            );
        }
    }
    Ok(())
}

fn paint_building_shade(
    client: &mut Client,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM building_shade
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    // Without dropShadow, solid shade is mostly covered by pink footprints;
    // keep a faint pass so overhangs still read as dark.
    let mut color = fill_building_shade();
    color.set_alpha(0.25);
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            fill_polygons(pixmap, bounds, geom, color);
        }
    }
    Ok(())
}

fn paint_building_parts(
    client: &mut Client,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    order_by_height: bool,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let order = if order_by_height {
        "ORDER BY COALESCE(height, 0)"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM building_parts_dissolved_height
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        {order}
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mut color = fill_building();
    color.set_alpha(0.85);
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            // Shadow is applied on `building` footprints only (avoids double blur).
            fill_polygons(pixmap, bounds, geom, color);
        }
    }
    Ok(())
}

fn paint_building(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM building
        WHERE geom && {env}
          AND NOT ST_IsEmpty(ST_ClipByBox2D(geom, {env}))
        ORDER BY osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mut color = fill_building();
    color.set_alpha(0.9);
    let mut geoms = Vec::new();
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        match decode_wkb(&wkb) {
            Ok(geom) => geoms.push(geom),
            Err(e) => eprintln!("warn: skip building WKB: {e:?}"),
        }
    }
    fill_polygons_batch_with_shadow(pixmap, bounds, &geoms, color, DropShadow::building());
    Ok(())
}

fn paint_tree(client: &mut Client, pixmap: &mut Pixmap, bounds: TileBounds) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT
          diameter_crown,
          circumference,
          "natural" AS natural_tag,
          {wkb_sql} AS wkb
        FROM tree
        WHERE geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY osm_id
        "#
    );
    let rows = client.query(
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    for row in &rows {
        let natural: Option<String> = row.try_get("natural_tag").ok().flatten();
        let diameter = opt_f32(row, "diameter_crown");
        let circumference = opt_f32(row, "circumference");
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        let Ok(geom) = decode_wkb(&wkb) else {
            continue;
        };
        if natural.as_deref() != Some("tree_stump") {
            let crown_d = diameter
                .filter(|d| *d > 0.0)
                .map(f64::from)
                .unwrap_or(7.0);
            let mut crown = fill_tree_crown();
            crown.set_alpha(0.62);
            fill_tree_crown_soft(pixmap, bounds, geom.clone(), crown, crown_d / 2.0);
        }
        if let Some(c) = circumference.filter(|c| *c > 0.0).map(f64::from) {
            let trunk_r = c / (2.0 * std::f64::consts::PI);
            let mut trunk = fill_tree_trunk();
            trunk.set_alpha(0.8);
            fill_circles_m(pixmap, bounds, geom, trunk, trunk_r);
        }
    }
    Ok(())
}
