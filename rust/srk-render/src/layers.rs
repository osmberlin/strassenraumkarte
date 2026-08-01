//! Layer paint passes for `highway_area` isolate and `full-approx`.

use anyhow::{Context, Result};
use postgres::Client;
use tiny_skia::Pixmap;

use crate::paint::{
    clip_line_wkb_sql_fast, clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb,
    draw_tree_crown_marker, envelope_sql, fill_circles_m, fill_polygons,
    fill_polygons_batch_with_shadow, fill_polygons_shadow_only, fill_polygons_textured,
    fill_tree_crown_soft, geometry_points, map_to_px, stroke_lines, DropShadow,
};
use crate::palette::{
    fill_building, fill_for_area_highway, fill_for_landuse, fill_pitch, fill_tree_crown,
    fill_tree_trunk, fill_water, highway_surface_texture, landuse_class_texture,
    landuse_surface_texture, stroke_path, stroke_service, stroke_waterway, surface_colour,
    AREA_HIGHWAY_PAINTED,
};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::textures::TextureCatalog;
use crate::tile::{
    mercator_scale, parse_hex_color, tile_bounds_3857, TileBounds, DEFAULT_BACKGROUND, TILE_SIZE_PX,
};
use crate::tree_markers::TreeMarkerCatalog;

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

/// Write a tile image. Extension selects codec: `.png` (lossless) or `.webp`
/// (lossy at `webp_quality`, matching production JPEG-q90 intent).
pub fn save_tile(
    pixmap: &Pixmap,
    out_path: &std::path::Path,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    if let Some(parent) = out_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let ext = out_path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    crate::profile::time_stage(timers, StageSlot::Encode, || {
        match ext.as_str() {
            "png" => {
                pixmap.save_png(out_path)?;
            }
            "webp" => {
                let w = pixmap.width();
                let h = pixmap.height();
                let encoder = webp::Encoder::from_rgba(pixmap.data(), w, h);
                let q = webp_quality.clamp(0.0, 100.0);
                let memory = encoder.encode(q);
                std::fs::write(out_path, memory.as_ref())
                    .with_context(|| format!("write webp {}", out_path.display()))?;
            }
            other => anyhow::bail!("unsupported tile extension .{other} (use png or webp)"),
        }
        Ok::<(), anyhow::Error>(())
    })?;
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
    prep_cache: &mut PreparedCache,
    z: u32,
    x: u32,
    y: u32,
    out_path: &std::path::Path,
    quiet: bool,
    textures: &TextureCatalog,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = empty_pixmap()?;
    let painted = paint_highway_area(
        client,
        prep_cache,
        &mut pixmap,
        bounds,
        z,
        textures,
        timers,
    )?;
    save_tile(&pixmap, out_path, webp_quality, timers)?;
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
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    textures: &TextureCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT
          "area:highway" AS area_highway,
          surface,
          {wkb_sql} AS wkb
        FROM highway_area
        WHERE geom && {env}
          AND "area:highway" IN {AREA_HIGHWAY_PAINTED}
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mut painted = 0usize;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let area: Option<String> = row.get("area_highway");
            let Some(fill_color) = fill_for_area_highway(area.as_deref()) else {
                continue;
            };
            let surface: Option<String> = row.try_get("surface").ok().flatten();
            let texture = surface
                .as_deref()
                .and_then(highway_surface_texture)
                .and_then(|(id, opacity)| textures.get(id).map(|t| (t, opacity)));
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            match decode_wkb(&wkb) {
                Ok(geom) => {
                    fill_polygons_textured(pixmap, bounds, geom, fill_color, texture);
                    painted += 1;
                }
                Err(e) => eprintln!("warn: skip highway_area WKB: {e:?}"),
            }
        }
    });
    Ok(painted)
}

/// Full approximate stack: landuse → water → roads → buildings → trees.
///
/// Deferred vs QGIS: labels (PAL), SVG markers, full effect stacks (innerShadow/glow),
/// symbol levels, blend modes. RasterFill v1: map-anchored surface/class textures.
pub fn render_full_approx(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    z: u32,
    x: u32,
    y: u32,
    out_path: &std::path::Path,
    quiet: bool,
    cache: &TableCache,
    textures: &TextureCatalog,
    tree_markers: &TreeMarkerCatalog,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let bounds = tile_bounds_3857(x, y, z);
    let mut pixmap = empty_pixmap()?;

    let check_sql = tile_has_any_data_sql(cache);
    let hit_rows = query_prep(
        client,
        prep_cache,
        timers,
        &check_sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let any_hit: bool = hit_rows[0].get("any_hit");
    if !any_hit {
        save_tile(&pixmap, out_path, webp_quality, timers)?;
        if !quiet {
            eprintln!("rendered {z}/{x}/{y} → {} (full-approx, empty)", out_path.display());
        }
        return Ok(());
    }

    paint_landuse(client, prep_cache, &mut pixmap, bounds, z, textures, timers)?;
    if cache.pitch {
        paint_pitch(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    if cache.water_body {
        paint_water_body(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    if cache.waterway {
        paint_waterway(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    // Streets: path → service → highway_area (matches QGIS / MapLibre sandwich).
    if cache.highway {
        paint_highway_path(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    if cache.highway_service {
        paint_highway_service(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    paint_highway_area(
        client,
        prep_cache,
        &mut pixmap,
        bounds,
        z,
        textures,
        timers,
    )?;
    if cache.road_marking_polygon {
        paint_road_marking_polygon(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    if cache.building_shade {
        paint_building_shade(client, prep_cache, &mut pixmap, bounds, z, timers)?;
    }
    // QGIS paints `building_parts_dissolved_height` only (no separate `building` maplayer).
    if cache.building_parts {
        paint_building_parts(
            client,
            prep_cache,
            &mut pixmap,
            bounds,
            z,
            cache.building_parts_has_height,
            timers,
        )?;
    }
    if cache.tree {
        paint_tree(
            client,
            prep_cache,
            &mut pixmap,
            bounds,
            z,
            cache,
            tree_markers,
            timers,
        )?;
    }

    save_tile(&pixmap, out_path, webp_quality, timers)?;
    if !quiet {
        eprintln!("rendered {z}/{x}/{y} → {} (full-approx)", out_path.display());
    }
    Ok(())
}

/// One cheap EXISTS probe before painting; skips sparse edge tiles.
fn tile_has_any_data_sql(cache: &TableCache) -> String {
    let env = envelope_sql();
    let mut parts = vec![
        format!("EXISTS (SELECT 1 FROM landuse WHERE geom && {env})"),
        format!(
            r#"EXISTS (SELECT 1 FROM highway_area WHERE geom && {env} AND "area:highway" IN {AREA_HIGHWAY_PAINTED})"#
        ),
    ];
    if cache.pitch {
        parts.push(format!("EXISTS (SELECT 1 FROM pitch WHERE geom && {env})"));
    }
    if cache.water_body {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM water_body_dissolved WHERE geom && {env})"
        ));
    }
    if cache.waterway {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM waterway_clipped WHERE geom && {env})"
        ));
    }
    if cache.highway {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM highway WHERE type = 'path' AND geom && {env})"
        ));
    }
    if cache.highway_service {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM highway_service WHERE geom && {env})"
        ));
    }
    if cache.road_marking_polygon {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM road_marking_polygon WHERE geom && {env}
              AND road_marking IN ('surface_colour', 'crossing')
              AND colour IS NOT NULL
              AND colour NOT IN ('', 'no', 'none'))"#
        ));
    }
    if cache.building_shade {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM building_shade WHERE geom && {env})"
        ));
    }
    if cache.building_parts {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM building_parts_dissolved_height WHERE geom && {env})"
        ));
    }
    if cache.tree {
        parts.push(format!("EXISTS (SELECT 1 FROM tree WHERE geom && {env})"));
    }
    format!("SELECT ({}) AS any_hit", parts.join(" OR "))
}

#[derive(Clone, Debug)]
pub struct TableCache {
    pub pitch: bool,
    pub water_body: bool,
    pub waterway: bool,
    pub highway_service: bool,
    pub highway: bool,
    pub road_marking_polygon: bool,
    pub building_shade: bool,
    pub building_parts: bool,
    pub tree: bool,
    pub tree_has_leaf_type: bool,
    pub tree_has_rotation: bool,
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
            road_marking_polygon: table_exists(client, "road_marking_polygon")?,
            building_shade: table_exists(client, "building_shade")?,
            building_parts: table_exists(client, "building_parts_dissolved_height")?,
            tree: table_exists(client, "tree")?,
            tree_has_leaf_type: column_exists(client, "tree", "leaf_type")?,
            tree_has_rotation: column_exists(client, "tree", "rotation")?,
            building_parts_has_height: column_exists(
                client,
                "building_parts_dissolved_height",
                "height",
            )?,
        })
    }
}

fn paint_landuse(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    textures: &TextureCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT class, surface, {wkb_sql} AS wkb
        FROM landuse
        WHERE geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: Option<String> = row.get("class");
            let surface: Option<String> = row.try_get("surface").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let base = fill_for_landuse(class.as_deref());
            let texture = surface
                .as_deref()
                .and_then(landuse_surface_texture)
                .or_else(|| class.as_deref().and_then(landuse_class_texture))
                .and_then(|(id, opacity)| textures.get(id).map(|t| (t, opacity)));
            match decode_wkb(&wkb) {
                Ok(geom) => fill_polygons_textured(pixmap, bounds, geom, base, texture),
                Err(e) => eprintln!("warn: skip landuse WKB: {e:?}"),
            }
        }
    });
    Ok(())
}

fn paint_pitch(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM pitch
        WHERE geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons(pixmap, bounds, geom, fill_pitch());
            }
        }
    });
    Ok(())
}

fn paint_water_body(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM water_body_dissolved
        WHERE geom && {env}
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons(pixmap, bounds, geom, fill_water());
            }
        }
    });
    Ok(())
}

fn paint_waterway(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT width, {wkb_sql} AS wkb
        FROM waterway_clipped
        WHERE geom && {env}
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
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
    });
    Ok(())
}

fn paint_highway_service(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT class, width, {wkb_sql} AS wkb
        FROM highway_service
        WHERE geom && {env}
        ORDER BY COALESCE(layer, 0)
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
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
                let width_map = width_m * mercator_scale(bounds);
                stroke_lines(pixmap, bounds, geom, stroke_service(), width_map);
            }
        }
    });
    Ok(())
}

fn paint_highway_path(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_line_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT highway, width, {wkb_sql} AS wkb
        FROM highway
        WHERE type = 'path'
          AND geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
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
                let width_map = width_m * mercator_scale(bounds);
                stroke_lines(
                    pixmap,
                    bounds,
                    geom,
                    stroke_path(highway.as_deref()),
                    width_map,
                );
            }
        }
    });
    Ok(())
}

fn paint_road_marking_polygon(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT road_marking, colour, {wkb_sql} AS wkb
        FROM road_marking_polygon
        WHERE geom && {env}
          AND road_marking IN ('surface_colour', 'crossing')
          AND colour IS NOT NULL
          AND colour NOT IN ('', 'no', 'none')
        ORDER BY osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let colour: Option<String> = row.try_get("colour").ok().flatten();
            let Some(mut fill) = surface_colour(colour.as_deref()) else {
                continue;
            };
            fill.set_alpha(0.45);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons(pixmap, bounds, geom, fill);
            }
        }
    });
    Ok(())
}

fn paint_building_shade(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM building_shade
        WHERE geom && {env}
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mut geoms = Vec::new();
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            geoms.push(geom);
        }
    }
    // QGIS: dropShadow enabled, drawSource DISABLED — soft shadow only.
    fill_polygons_shadow_only(pixmap, bounds, &geoms, DropShadow::building_shade(), timers);
    Ok(())
}

fn paint_building_parts(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    z: u32,
    order_by_height: bool,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
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
        {order}
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    // QGIS: flat `#ffe9e9` @ symbol α 0.7 + dropShadow (no ShapeburstFill).
    let mut color = fill_building();
    color.set_alpha(0.78);
    let mut geoms = Vec::new();
    for row in &rows {
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        match decode_wkb(&wkb) {
            Ok(geom) => geoms.push(geom),
            Err(e) => eprintln!("warn: skip building_parts WKB: {e:?}"),
        }
    }
    fill_polygons_batch_with_shadow(pixmap, bounds, &geoms, color, DropShadow::building(), timers);
    Ok(())
}

fn paint_tree(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    bounds: TileBounds,
    _z: u32,
    cache: &TableCache,
    tree_markers: &TreeMarkerCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let leaf_col = if cache.tree_has_leaf_type {
        "leaf_type,"
    } else {
        ""
    };
    let rot_col = if cache.tree_has_rotation {
        "rotation,"
    } else {
        ""
    };
    let sql = format!(
        r#"
        SELECT
          diameter_crown,
          circumference,
          "natural" AS natural_tag,
          {leaf_col}
          {rot_col}
          {wkb_sql} AS wkb
        FROM tree
        WHERE geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&bounds.minx, &bounds.miny, &bounds.maxx, &bounds.maxy],
    )?;
    let mscale = mercator_scale(bounds);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
        let natural: Option<String> = row.try_get("natural_tag").ok().flatten();
        let diameter = opt_f32(row, "diameter_crown");
        let circumference = opt_f32(row, "circumference");
        let leaf_type: Option<String> = if cache.tree_has_leaf_type {
            row.try_get("leaf_type").ok().flatten()
        } else {
            None
        };
        let rotation: Option<f32> = if cache.tree_has_rotation {
            row.try_get::<_, Option<i32>>("rotation")
                .ok()
                .flatten()
                .map(|r| r as f32)
        } else {
            None
        };
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        let Ok(geom) = decode_wkb(&wkb) else {
            continue;
        };
        if natural.as_deref() != Some("tree_stump") {
            let is_shrub = natural.as_deref() == Some("shrub");
            let crown_ground_m = diameter
                .filter(|d| *d > 0.0)
                .map(f64::from)
                .unwrap_or(if is_shrub { 4.5 } else { 7.0 });
            let crown_map_m = crown_ground_m * mscale;
            let shadow = if is_shrub {
                DropShadow::shrub()
            } else {
                DropShadow::tree()
            };
            let rotation_deg = rotation.unwrap_or(0.0);
            let mut crown = fill_tree_crown();
            crown.set_alpha(0.55);
            if tree_markers.from_file {
                let marker = tree_markers.for_leaf_type(leaf_type.as_deref());
                for pt in geometry_points(geom.clone()) {
                    let (cx, cy) = map_to_px(
                        bounds,
                        geo_types::Coord {
                            x: pt.x(),
                            y: pt.y(),
                        },
                    );
                    draw_tree_crown_marker(
                        pixmap,
                        bounds,
                        cx,
                        cy,
                        marker,
                        crown_map_m,
                        rotation_deg,
                        shadow,
                        0.35,
                    );
                }
            }
            fill_tree_crown_soft(pixmap, bounds, geom.clone(), crown, crown_map_m / 2.0);
        }
        if let Some(c) = circumference.filter(|c| *c > 0.0).map(f64::from) {
            let trunk_r_ground = c / (2.0 * std::f64::consts::PI);
            let mut trunk = fill_tree_trunk();
            trunk.set_alpha(0.8);
            fill_circles_m(
                pixmap,
                bounds,
                geom,
                trunk,
                trunk_r_ground * mscale,
            );
        }
    }
    });
    Ok(())
}
