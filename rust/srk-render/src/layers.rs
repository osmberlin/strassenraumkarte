//! Layer paint passes for `highway_area` isolate and `full-approx`.

use crate::furniture_a;
use crate::furniture_batch_b;
use crate::street_detail;
use anyhow::{Context, Result};
use postgres::Client;
use tiny_skia::Pixmap;

use crate::paint::{
    clip_line_wkb_sql_fast, clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb,
    draw_tree_crown_marker, envelope_sql, fill_circles_m, fill_polygons,
    fill_polygons_batch_shadow_under,
    fill_polygons_raster_fill, fill_polygons_shadow_only, fill_polygons_textured, fill_polygons_hatch,
    geometry_points, map_to_px, stroke_embankment, stroke_lines, stroke_lines_offset,
    stroke_lines_offset_dashed, stroke_polygons, stroke_steps_hash, DropShadow, RasterFillParams,
};
use crate::palette::{
    fill_building, fill_for_area_highway, fill_for_landuse, fill_for_pitch, fill_playground,
    fill_playground_climbingframe, fill_sandpit, fill_tree_trunk, fill_water,
    highway_surface_rule, landuse_class_rules, landuse_surface_rule, pitch_surface_rule,
    road_marking_colour, stroke_landscape, stroke_path, stroke_path_casing, stroke_playground,
    stroke_playground_climbingframe, stroke_service, stroke_tactile, stroke_waterway, surface_colour,
    AREA_HIGHWAY_PAINTED,
};
use crate::pitch_markings::{stamp_at_map_point, stem_for_feature, PitchMarkingCatalog};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::svg_stamps::{road_marking_node_svg, SvgStampCatalog};
use crate::textures::TextureCatalog;
use crate::tile::{
    crop_tile, mercator_scale, parse_hex_color, MetaTile, RenderExtent, DEFAULT_BACKGROUND,
};
use crate::tree_markers::TreeMarkerCatalog;

fn opt_f32(row: &postgres::Row, col: &str) -> Option<f32> {
    row.try_get::<_, Option<f32>>(col).ok().flatten()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayerPreset {
    HighwayArea,
    FullApprox,
    /// Design research: landscape-architecture plan.
    La,
    /// Design research: fantasy-book ink map.
    Ink,
    /// Design research: roof shapes preview (roof_mass / roof_facet / roof_shape_line).
    Roofs,
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
        if names.len() == 1 && names[0] == "la" {
            return Ok(Self::La);
        }
        if names.len() == 1 && names[0] == "ink" {
            return Ok(Self::Ink);
        }
        if names.len() == 1 && names[0] == "roofs" {
            return Ok(Self::Roofs);
        }
        anyhow::bail!(
            "supported --layers: highway_area | full-approx | la | ink | roofs (got {:?})",
            layers
        )
    }
}

fn empty_pixmap(extent: RenderExtent) -> Result<Pixmap> {
    let bg = parse_hex_color(DEFAULT_BACKGROUND)?;
    let mut pixmap = Pixmap::new(extent.width_px, extent.height_px).context("pixmap alloc")?;
    pixmap.fill(bg);
    Ok(pixmap)
}

/// Write a tile image. Extension selects codec: `.png` (lossless harness),
/// `.webp` / `.jpg` / `.jpeg` (lossy at `quality`, live farm formats).
pub fn save_tile(
    pixmap: &Pixmap,
    out_path: &std::path::Path,
    quality: f32,
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
                let mut config = webp::WebPConfig::new()
                    .map_err(|()| anyhow::anyhow!("WebPConfig::new failed"))?;
                config.quality = quality.clamp(0.0, 100.0);
                // method 0–6: 1 = fast farm encode (libwebp default is 4).
                config.method = 1;
                let memory = encoder
                    .encode_advanced(&config)
                    .map_err(|e| anyhow::anyhow!("webp encode_advanced: {e:?}"))?;
                std::fs::write(out_path, memory.as_ref())
                    .with_context(|| format!("write webp {}", out_path.display()))?;
            }
            "jpg" | "jpeg" => {
                let w = pixmap.width();
                let h = pixmap.height();
                let rgba = pixmap.data();
                let mut rgb = Vec::with_capacity((w * h * 3) as usize);
                for px in rgba.chunks_exact(4) {
                    rgb.push(px[0]);
                    rgb.push(px[1]);
                    rgb.push(px[2]);
                }
                let img = image::RgbImage::from_raw(w, h, rgb)
                    .context("build rgb image for jpeg")?;
                let q = quality.clamp(1.0, 100.0) as u8;
                let mut file = std::fs::File::create(out_path)
                    .with_context(|| format!("create jpeg {}", out_path.display()))?;
                let mut encoder =
                    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut file, q);
                encoder
                    .encode(img.as_raw(), w, h, image::ExtendedColorType::Rgb8)
                    .with_context(|| format!("encode jpeg {}", out_path.display()))?;
            }
            other => {
                anyhow::bail!("unsupported tile extension .{other} (use png, webp, or jpg)")
            }
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

fn write_meta_cores(
    mt: &MetaTile,
    pixmap: &Pixmap,
    out_dir: &std::path::Path,
    format_ext: &str,
    quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let mut written = 0usize;
    for y in mt.y0..=mt.y1 {
        for x in mt.x0..=mt.x1 {
            let core = crop_tile(pixmap, mt.rx0, mt.ry0, x, y);
            let path = out_dir.join(format!("{}/{}/{}.{}", mt.z, x, y, format_ext));
            save_tile(&core, &path, quality, timers)?;
            written += 1;
        }
    }
    Ok(written)
}

/// Design-research presets (`la`, `ink`): own paint stacks in `style_la` / `style_ink`.
pub fn render_style(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    mt: MetaTile,
    out_dir: &std::path::Path,
    format_ext: &str,
    quiet: bool,
    preset: LayerPreset,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let extent = RenderExtent::for_metatile(&mt);
    let pixmap = match preset {
        LayerPreset::La => crate::style_la::render(client, prep_cache, extent, mt.z)?,
        LayerPreset::Roofs => crate::roof_shapes::render(client, prep_cache, extent, mt.z)?,
        _ => crate::style_ink::render(client, prep_cache, extent, mt.z)?,
    };
    let written = write_meta_cores(&mt, &pixmap, out_dir, format_ext, webp_quality, timers)?;
    if !quiet {
        eprintln!("rendered metatile z{} cores {}x{}-{}x{} → {} tiles ({:?})", mt.z, mt.x0, mt.y0, mt.x1, mt.y1, written, preset);
    }
    Ok(written)
}

/// Isolate: `highway_area` class fills only.
pub fn render_highway_area(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    mt: MetaTile,
    out_dir: &std::path::Path,
    format_ext: &str,
    quiet: bool,
    textures: &TextureCatalog,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let extent = RenderExtent::for_metatile(&mt);
    let mut pixmap = empty_pixmap(extent)?;
    let painted = paint_highway_area(
        client,
        prep_cache,
        &mut pixmap,
        extent,
        mt.z,
        textures,
        timers,
    )?;
    let written = write_meta_cores(&mt, &pixmap, out_dir, format_ext, webp_quality, timers)?;
    if !quiet {
        eprintln!(
            "rendered metatile z{} cores {}x{}-{}x{} → {} tiles (highway_area parts≈{painted})",
            mt.z,
            mt.x0,
            mt.y0,
            mt.x1,
            mt.y1,
            written,
        );
    }
    Ok(written)
}

fn paint_highway_area(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    textures: &TextureCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    // Surface overlays (RasterFill) match on `surface` alone in QGIS, so rows outside the
    // class fills still get their texture.
    let sql = format!(
        r#"
        SELECT
          "area:highway" AS area_highway,
          surface,
          "sett:length" AS sett_length,
          direction,
          {wkb_sql} AS wkb
        FROM highway_area
        WHERE geom && {env}
          AND ("area:highway" IN {AREA_HIGHWAY_PAINTED}
               OR surface IN ('asphalt', 'concrete', 'concrete:plates', 'paving_stones', 'sett'))
        ORDER BY COALESCE(layer, 0), osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let mut painted = 0usize;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let area: Option<String> = row.get("area_highway");
            let surface: Option<String> = row.try_get("surface").ok().flatten();
            let sett_length: Option<String> = row.try_get("sett_length").ok().flatten();
            let direction = opt_f32(row, "direction").map(f64::from);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let geom = match decode_wkb(&wkb) {
                Ok(geom) => geom,
                Err(e) => {
                    eprintln!("warn: skip highway_area WKB: {e:?}");
                    continue;
                }
            };
            if let Some(fill_color) = fill_for_area_highway(area.as_deref()) {
                fill_polygons(pixmap, extent, geom.clone(), fill_color);
                painted += 1;
            }
            if let Some(rule) = surface
                .as_deref()
                .and_then(|s| highway_surface_rule(s, sett_length.as_deref()))
            {
                paint_texture_rule(pixmap, extent, geom, textures, rule, direction);
            }
        }
    });
    Ok(painted)
}

/// Apply one QGIS RasterFill rule (`palette::TextureRule`) to `geom` when its texture loaded.
fn paint_texture_rule(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: geo_types::Geometry<f64>,
    textures: &TextureCatalog,
    rule: crate::palette::TextureRule,
    direction: Option<f64>,
) {
    let Some(texture) = textures.get(rule.id) else {
        return;
    };
    fill_polygons_raster_fill(
        pixmap,
        extent,
        geom,
        texture,
        RasterFillParams {
            alpha: rule.alpha,
            width_m: rule.width_m,
            angle_deg: rule.angle_deg(direction),
            multiply: rule.multiply,
        },
    );
}

/// Full approximate stack: landuse → water → roads → buildings → trees.
///
/// Deferred vs QGIS: labels (PAL), SVG markers, full effect stacks (innerShadow/glow),
/// symbol levels, blend modes. RasterFill v1: map-anchored surface/class textures.
pub fn render_full_approx(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    mt: MetaTile,
    out_dir: &std::path::Path,
    format_ext: &str,
    quiet: bool,
    cache: &TableCache,
    textures: &TextureCatalog,
    tree_markers: &TreeMarkerCatalog,
    pitch_markings: &PitchMarkingCatalog,
    svg_stamps: &SvgStampCatalog,
    webp_quality: f32,
    timers: &mut Option<&mut StageTimers>,
) -> Result<usize> {
    let extent = RenderExtent::for_metatile(&mt);
    let mut pixmap = empty_pixmap(extent)?;
    let b = extent.bounds;
    let z = mt.z;

    let check_sql = tile_has_any_data_sql(cache, z);
    let hit_rows = query_prep(
        client,
        prep_cache,
        timers,
        &check_sql,
        &[&b.minx, &b.miny, &b.maxx, &b.maxy],
    )?;
    let any_hit: bool = hit_rows[0].get("any_hit");
    if !any_hit {
        let written = write_meta_cores(&mt, &pixmap, out_dir, format_ext, webp_quality, timers)?;
        if !quiet {
            eprintln!(
                "rendered metatile z{} cores {}x{}-{}x{} → {} tiles (full-approx, empty)",
                z,
                mt.x0,
                mt.y0,
                mt.x1,
                mt.y1,
                written,
            );
        }
        return Ok(written);
    }

    paint_landuse(client, prep_cache, &mut pixmap, extent, z, textures, timers)?;
    // `construction` hatch belongs to the QGIS landuse group, below roads and buildings.
    if cache.landuse_construction {
        street_detail::paint_construction_stripes(client, prep_cache, &mut pixmap, extent, timers)?;
    }
    if cache.pitch {
        paint_pitch(client, prep_cache, &mut pixmap, extent, z, textures, timers)?;
    }
    if cache.pitch_markings && !pitch_markings.is_empty() && z >= 15 {
        paint_pitch_markings(
            client,
            prep_cache,
            &mut pixmap,
            extent,
            pitch_markings,
            timers,
        )?;
    }
    if cache.playground_polygon {
        paint_sandpit(client, prep_cache, &mut pixmap, extent, z, textures, timers)?;
    }
    if cache.water_body {
        paint_water_body(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.waterway {
        paint_waterway(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    // Below z17 the QGIS crowns (`tree crown (<= z17)`) and trunks sit low in the custom layer
    // order, under landuse, paving, roads and buildings: only the gaps show them in the reference.
    if cache.tree && z < 17 {
        paint_tree(client, prep_cache, &mut pixmap, extent, cache, tree_markers, timers)?;
    }
    // QGIS draw order (layer tree, bottom → top): path casing, path fill, service, tactile,
    // highway_area, then the `z14`–`z20` kerb innerShadow. Carriageways therefore cover footway
    // crossings, and service roads sit above footways.
    if cache.highway {
        paint_highway_path(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.highway_service {
        paint_highway_service(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.tactile_paving && z >= 17 {
        paint_tactile_paving(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    paint_highway_area(
        client,
        prep_cache,
        &mut pixmap,
        extent,
        z,
        textures,
        timers,
    )?;
    if cache.highway_oneway {
        street_detail::paint_highway_oneway(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    // `kerb shade` (Lineburst on kerbs) and `tunnel entrance` (outline + shade): both in the
    // QGIS highway group, below buildings.
    street_detail::paint_kerb_shade(client, prep_cache, &mut pixmap, extent, z, timers)?;
    if cache.tunnel_entrance {
        street_detail::paint_tunnel_entrance(client, prep_cache, &mut pixmap, extent, timers)?;
    }
    if cache.feature_node {
        street_detail::paint_traffic_calming(client, prep_cache, &mut pixmap, extent, timers)?;
    }
    // Böschungen after paths so the comb stays visible on park / path edges.
    if cache.landscape_way && z >= 15 {
        paint_landscape_way(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.building_shade {
        paint_building_shade(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.building_parts {
        paint_building_parts(
            client,
            prep_cache,
            &mut pixmap,
            extent,
            z,
            cache.building_parts_has_height,
            timers,
        )?;
    }
    if cache.building_lines {
        paint_building_lines(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    // From z17 the crowns are drawn over paving and buildings (matches the reference better than
    // QGIS's strict stacking); parked cars, road markings and barriers stay above them.
    if cache.tree && z >= 17 {
        paint_tree(client, prep_cache, &mut pixmap, extent, cache, tree_markers, timers)?;
    }
    // Road markings after buildings so parking_edge / signs stay visible on the carriageway.
    if cache.road_marking_polygon {
        paint_road_marking_polygon(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.road_marking_way && z >= 15 {
        paint_road_marking_way(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.road_marking_node && z >= 15 {
        paint_road_marking_node(client, prep_cache, &mut pixmap, extent, svg_stamps, timers)?;
    }

    // QGIS `street parking` layers sit in the highway stratum: above road surfaces and
    // markings, below the barrier / playground / feature layers of the same layer bucket.
    if cache.street_parking_point {
        paint_street_parking_point(client, prep_cache, &mut pixmap, extent, svg_stamps, timers)?;
    }

    furniture_batch_b::paint(
        client,
        prep_cache,
        &mut pixmap,
        extent,
        z,
        cache,
        svg_stamps,
        timers,
    )?;

    if cache.feature_node && z >= 16 {
        paint_viewpoint(client, prep_cache, &mut pixmap, extent, svg_stamps, timers)?;
    }

    // Furniture G6: playground equipment (after ground/roads/buildings, before trees).
    if z >= 15 {
        if cache.playground_way {
            paint_playground_way(client, prep_cache, &mut pixmap, extent, z, timers)?;
        }
        if cache.playground_polygon {
            paint_playground_polygon(client, prep_cache, &mut pixmap, extent, z, timers)?;
        }
        if cache.playground_node {
            paint_playground_node(client, prep_cache, &mut pixmap, extent, timers)?;
        }
    }

    furniture_a::paint(
        client,
        prep_cache,
        &mut pixmap,
        extent,
        z,
        cache,
        svg_stamps,
        timers,
    )?;

    crate::labels_full::paint(client, prep_cache, &mut pixmap, extent, z, timers)?;

    let written = write_meta_cores(&mt, &pixmap, out_dir, format_ext, webp_quality, timers)?;
    if !quiet {
        eprintln!(
            "rendered metatile z{} cores {}x{}-{}x{} → {} tiles (full-approx)",
            z,
            mt.x0,
            mt.y0,
            mt.x1,
            mt.y1,
            written,
        );
    }
    Ok(written)
}

/// One cheap EXISTS probe before painting; skips sparse edge tiles.
fn tile_has_any_data_sql(cache: &TableCache, z: u32) -> String {
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
    if cache.playground_polygon {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM playground_polygon WHERE geom && {env})"
        ));
    }
    if cache.playground_way {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM playground_way WHERE geom && {env})"
        ));
    }
    if cache.playground_node {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM playground_node WHERE geom && {env})"
        ));
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
    if cache.landscape_way {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM landscape_way WHERE geom && {env}
              AND class IN ('cliff','embankment','earth_bank'))"#
        ));
    }
    if cache.highway {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM highway WHERE type = 'path' AND geom && {env})"
        ));
    }
    if cache.tactile_paving && z >= 17 {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM tactile_paving WHERE geom && {env})"
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
              AND (
                road_marking = 'zebra_stripe'
                OR road_marking IN ('restriction', 'barred_area')
                OR (
                  road_marking IN ('surface_colour', 'crossing')
                  AND colour IS NOT NULL
                  AND colour NOT IN ('', 'no', 'none')
                )
              ))"#
        ));
    }
    if cache.road_marking_way {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM road_marking_way WHERE geom && {env})"
        ));
    }
    if cache.road_marking_node {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM road_marking_node WHERE geom && {env})"
        ));
    }
    if cache.barrier_way && z >= 17 {
        parts.push(format!("EXISTS (SELECT 1 FROM barrier_way WHERE geom && {env})"));
    }
    if cache.barrier_node && z >= 17 {
        parts.push(format!("EXISTS (SELECT 1 FROM barrier_node WHERE geom && {env})"));
    }
    if cache.barrier_polygon && z >= 17 {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM barrier_polygon WHERE geom && {env})"
        ));
    }
    if cache.feature_node && z >= 18 {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM feature_node WHERE geom && {env} AND class = 'entrance')"#
        ));
    }
    if cache.stop_positions && z >= 17 {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM stop_positions WHERE geom && {env} AND highway = 'traffic_signals')"#
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
    if cache.street_parking_point {
        parts.push(format!(
            "EXISTS (SELECT 1 FROM street_parking_point WHERE geom && {env})"
        ));
    }
    if z >= 17 && cache.feature_node {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM feature_node WHERE geom && {env}
              AND class IN ('fire_hydrant','bicycle_parking','bicycle_rental','small_electric_vehicle_parking'))"#
        ));
    }
    if z >= 17 && cache.feature_polygon {
        parts.push(format!(
            r#"EXISTS (SELECT 1 FROM feature_polygon WHERE geom && {env}
              AND class IN ('mobility_hub','bicycle_parking','bicycle_rental','small_electric_vehicle_parking'))"#
        ));
    }
    format!("SELECT ({}) AS any_hit", parts.join(" OR "))
}

fn paint_landuse(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let mut parts: Vec<(Option<String>, Option<String>, geo_types::Geometry<f64>)> =
        Vec::with_capacity(rows.len());
    for row in &rows {
        let class: Option<String> = row.get("class");
        let surface: Option<String> = row.try_get("surface").ok().flatten();
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        match decode_wkb(&wkb) {
            Ok(geom) => parts.push((class, surface, geom)),
            Err(e) => eprintln!("warn: skip landuse WKB: {e:?}"),
        }
    }
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        // `landuse` layer: class SimpleFill, then its class RasterFill overlays (Normal blend).
        for (class, _, geom) in &parts {
            if !street_detail::landuse_has_qgis_fill(class.as_deref()) {
                continue;
            }
            fill_polygons(pixmap, extent, geom.clone(), fill_for_landuse(class.as_deref()));
            for rule in landuse_class_rules(class.as_deref().unwrap_or("")) {
                paint_texture_rule(pixmap, extent, geom.clone(), textures, *rule, None);
            }
        }
        // `landuse surface` layer (Multiply), drawn above the whole `landuse` layer.
        for (_, surface, geom) in &parts {
            if let Some(rule) = surface.as_deref().and_then(|s| landuse_surface_rule(s, None)) {
                paint_texture_rule(pixmap, extent, geom.clone(), textures, rule, None);
            }
        }
    });
    Ok(())
}

fn paint_pitch(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    textures: &TextureCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT surface, "surface:colour" AS surface_colour, sport, {wkb_sql} AS wkb
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let mut parts: Vec<(Option<String>, Option<String>, Option<String>, geo_types::Geometry<f64>)> =
        Vec::with_capacity(rows.len());
    for row in &rows {
        let surface: Option<String> = row.try_get("surface").ok().flatten();
        let colour: Option<String> = row.try_get("surface_colour").ok().flatten();
        let sport: Option<String> = row.try_get("sport").ok().flatten();
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        if let Ok(geom) = decode_wkb(&wkb) {
            parts.push((surface, colour, sport, geom));
        }
    }
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        // `pitch` layer: flat SimpleFill.
        for (surface, colour, sport, geom) in &parts {
            let base = fill_for_pitch(colour.as_deref(), surface.as_deref(), sport.as_deref());
            fill_polygons(pixmap, extent, geom.clone(), base);
        }
        // `pitch surface` layer (Multiply), above the pitch fills.
        for (surface, _, _, geom) in &parts {
            if let Some(rule) = surface.as_deref().and_then(|s| pitch_surface_rule(s, None)) {
                paint_texture_rule(pixmap, extent, geom.clone(), textures, rule, None);
            }
        }
    });
    Ok(())
}

/// G1 sandpit: `playground_polygon WHERE playground = 'sandpit'`.
fn paint_sandpit(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    textures: &TextureCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_polygon_wkb_sql_fast("geom", z);
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM playground_polygon
        WHERE playground = 'sandpit' AND geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
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
    let sand_tex = textures.get("sand").map(|t| (t, 0.08_f32));
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons_textured(pixmap, extent, geom, fill_sandpit(), sand_tex);
            }
        }
    });
    Ok(())
}

/// G6 playground equipment lines: casing then fill.
fn paint_playground_way(
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
        SELECT {wkb_sql} AS wkb
        FROM playground_way
        WHERE playground IS NOT NULL AND geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
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
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            // Casing 0.5 m outline, then 0.36 m fill (furniture.ts).
            stroke_lines(pixmap, extent, geom.clone(), stroke_playground(), 0.5);
            stroke_lines(pixmap, extent, geom, fill_playground(), 0.36);
        }
    });
    Ok(())
}

/// G6 playground equipment polygons (excludes sandpit — painted in G1).
fn paint_playground_polygon(
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
        SELECT playground, {wkb_sql} AS wkb
        FROM playground_polygon
        WHERE playground IS DISTINCT FROM 'sandpit' AND geom && {env}
        ORDER BY COALESCE(layer, 0), osm_id
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
            let kind: Option<String> = row.try_get("playground").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let climbing = kind.as_deref() == Some("climbingframe");
            let (fill, outline, outline_m) = if climbing {
                (
                    fill_playground_climbingframe(),
                    stroke_playground_climbingframe(),
                    0.26,
                )
            } else {
                (fill_playground(), stroke_playground(), 0.12)
            };
            fill_polygons(pixmap, extent, geom.clone(), fill);
            stroke_polygons(pixmap, extent, geom, outline, outline_m);
        }
    });
    Ok(())
}

/// G6 playground equipment nodes: filled circle + outline.
fn paint_playground_node(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT {wkb_sql} AS wkb
        FROM playground_node
        WHERE playground IS NOT NULL AND geom && {env}
          AND ST_Intersects(geom, {env})
        ORDER BY COALESCE(layer, 0), osm_id
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
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            // diameter 0.75 m, stroke 0.12 m → outer then inner.
            fill_circles_m(pixmap, extent, geom.clone(), stroke_playground(), 0.435);
            fill_circles_m(pixmap, extent, geom, fill_playground(), 0.375);
        }
    });
    Ok(())
}

fn paint_water_body(
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons(pixmap, extent, geom, fill_water());
            }
        }
    });
    Ok(())
}

fn paint_waterway(
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
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
                stroke_lines(pixmap, extent, geom, stroke_waterway(), width_m);
            }
        }
    });
    Ok(())
}

fn paint_highway_service(
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: Option<String> = row.try_get("class").ok().flatten();
            // Default widths follow the QGIS rule (4 m alley/untagged, 3 m otherwise); tagged
            // `width` (ground m) scales with @mercator_scale. Pixel parity favours the tag path.
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
                let width_map = width_m * mercator_scale(extent.bounds);
                stroke_lines(pixmap, extent, geom, stroke_service(), width_map);
            }
        }
    });
    Ok(())
}

fn paint_highway_path(
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
        SELECT highway, class, width, informal, tunnel, {wkb_sql} AS wkb
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let highway: Option<String> = row.try_get("highway").ok().flatten();
            let class: Option<String> = row.try_get("class").ok().flatten();
            let informal = row
                .try_get::<_, Option<String>>("informal")
                .ok()
                .flatten()
                .as_deref()
                == Some("yes");
            let tunnel: Option<String> = row.try_get("tunnel").ok().flatten();
            let tag_width_m = opt_f32(row, "width").filter(|w| *w > 0.0).map(f64::from);
            let width_m = tag_width_m.unwrap_or(1.8);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };

            if highway.as_deref() == Some("steps") && tunnel.as_deref() != Some("yes") {
                let hash_color = stroke_path(Some("steps"), class.as_deref());
                stroke_steps_hash(pixmap, extent, geom, hash_color, width_m, 0.6, 0.06);
                continue;
            }

            let ms = mercator_scale(extent.bounds);
            // QGIS casing: 0.2 map-unit line at ±(width / 2, or 0.9 m untagged) × @mercator_scale.
            if path_needs_casing(highway.as_deref(), class.as_deref(), informal) {
                let half = tag_width_m.map_or(0.9, |w| w * 0.5) * ms;
                let sidewalk_class = matches!(class.as_deref(), Some("sidewalk" | "crossing" | "link"));
                let (dash, alpha) = if informal {
                    ("0.6;2.4", 1.0)
                } else if sidewalk_class {
                    // Qt DashLine (4 on / 2 off × 0.2 m), casing α 0.5.
                    ("0.8;0.4", 0.5)
                } else {
                    ("0.6;0.6", 1.0)
                };
                let mut casing = stroke_path_casing(class.as_deref());
                casing.set_alpha(alpha);
                stroke_lines_offset_dashed(pixmap, extent, geom.clone(), casing, 0.2, half, Some(dash));
                stroke_lines_offset_dashed(pixmap, extent, geom.clone(), casing, 0.2, -half, Some(dash));
            }

            // QGIS fill: constant map-unit widths (Web Mercator m), not the `width` tag.
            let fill_width_map = if informal {
                1.2
            } else if highway.as_deref() == Some("cycleway") {
                1.0
            } else {
                tag_width_m.unwrap_or(1.8) * ms
            };
            let mut fill_color = stroke_path(highway.as_deref(), class.as_deref());
            if informal {
                fill_color.set_alpha(0.67);
            }
            stroke_lines(pixmap, extent, geom, fill_color, fill_width_map);
        }
    });
    Ok(())
}

/// Tactile paving along kerbs / footways (`#d3d3d3`, 1 m; kerb offset −0.5 m).
fn paint_tactile_paving(
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
        SELECT class, {wkb_sql} AS wkb
        FROM tactile_paving
        WHERE geom && {env}
        ORDER BY COALESCE(layer, 0)
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
    let color = stroke_tactile();
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: Option<String> = row.try_get("class").ok().flatten();
            // QGIS: offset = @mercator_scale × (kerb ? -0.5 : 0); width 1 map unit (Web Mercator m).
            let offset_m = if class.as_deref() == Some("kerb") {
                -0.5 * mercator_scale(extent.bounds)
            } else {
                0.0
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                stroke_lines_offset(pixmap, extent, geom, color, 1.0, offset_m);
            }
        }
    });
    Ok(())
}

fn path_needs_casing(highway: Option<&str>, class: Option<&str>, informal: bool) -> bool {
    if informal { return true; }
    if matches!(class, Some("sidewalk" | "crossing" | "link")) { return true; }
    matches!(highway, Some("footway" | "path" | "bridleway" | "pedestrian"))
}

/// G3 landscape: cliff / embankment / earth_bank (Böschungen).
fn paint_landscape_way(
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
        SELECT class, ST_Length(geom)::real AS len_m, {wkb_sql} AS wkb
        FROM landscape_way
        WHERE class IN ('cliff', 'embankment', 'earth_bank')
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
    let color = stroke_landscape();
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let len = opt_f32(row, "len_m").unwrap_or(0.0);
            // QGIS cliff/earth_bank: spine 0.3/0.6 m, markers 1.2/2.4 m, triangles 0.8/1.6 m.
            let (mut spine, spacing, tri, perp): (f64, f64, f64, f64) = if len < 20.0 {
                (0.3, 1.2, 0.8, 0.3)
            } else {
                (0.6, 2.4, 1.6, 0.6)
            };
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            if let Ok(geom) = decode_wkb(&wkb) {
                // Keep comb readable at z17–18 (QGIS MapUnit strokes soften less than our AA).
                spine = spine.max(extent.metres_per_px() * 1.25);
                stroke_embankment(pixmap, extent, geom, color, spine, spacing, tri, perp);
            }
        }
    });
    Ok(())
}

/// Foreground viewpoint icon (`symbols/tourism/viewpoint*.svg`).
fn paint_viewpoint(
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
        SELECT
          subclass,
          direction::real AS direction,
          {wkb_sql} AS wkb
        FROM feature_node
        WHERE class = 'viewpoint'
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
            let subclass: Option<String> = row.try_get("subclass").ok().flatten();
            let all_dir = subclass
                .as_deref()
                .map(|s| s.contains("all_directions"))
                .unwrap_or(false);
            let rel = if all_dir {
                "tourism/viewpoint_all_directions.svg"
            } else {
                "tourism/viewpoint.svg"
            };
            let size_m = if all_dir { 5.2 } else { 3.0 };
            let direction = opt_f32(row, "direction").unwrap_or(90.0);
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
                    rel,
                    pt.x(),
                    pt.y(),
                    size_m,
                    size_m,
                    direction,
                );
            }
        }
    });
    Ok(())
}

pub(crate) fn paint_road_marking_polygon(
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
        SELECT road_marking, colour, pattern, direction::real AS direction, {wkb_sql} AS wkb
        FROM road_marking_polygon
        WHERE geom && {env}
          AND (
            road_marking = 'zebra_stripe'
            OR (
              road_marking IN ('surface_colour', 'crossing')
              AND colour IS NOT NULL
              AND colour NOT IN ('', 'no', 'none')
            )
            OR road_marking IN ('restriction', 'barred_area')
          )
        ORDER BY osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let road_marking: Option<String> = row.try_get("road_marking").ok().flatten();
            let marking = road_marking.as_deref().unwrap_or("");
            let pattern: Option<String> = row.try_get("pattern").ok().flatten();
            let pattern_s = pattern.as_deref();
            let direction = opt_f32(row, "direction").map(f64::from);
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };

            if matches!(marking, "restriction" | "barred_area") {
                if matches!(pattern_s, Some("zigzag" | "x")) {
                    continue;
                }
                let colour: Option<String> = row.try_get("colour").ok().flatten();
                let outline = road_marking_colour(colour.as_deref());
                if pattern_s != Some("none") {
                    fill_polygons_hatch(
                        pixmap,
                        extent,
                        geom.clone(),
                        outline,
                        0.67,
                        direction,
                        pattern_s,
                    );
                }
                stroke_polygons(pixmap, extent, geom, outline, 0.12);
                continue;
            }

            if marking == "zebra_stripe" {
                let colour: Option<String> = row.try_get("colour").ok().flatten();
                let mut fill = road_marking_colour(colour.as_deref());
                fill.set_alpha(1.0);
                fill_polygons(pixmap, extent, geom, fill);
                continue;
            }

            let colour: Option<String> = row.try_get("colour").ok().flatten();
            let Some(mut fill) = surface_colour(colour.as_deref()) else {
                continue;
            };
            fill.set_alpha(0.45);
            fill_polygons(pixmap, extent, geom, fill);
        }
    });
    Ok(())
}

/// G5 road marking lines/// G5 road marking lines: parking_edge, edge_line, centre lines, etc.
pub(crate) fn paint_road_marking_way(
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
        SELECT
          road_marking,
          colour,
          dasharray,
          width::real AS width,
          {wkb_sql} AS wkb
        FROM road_marking_way
        WHERE geom && {env}
          AND COALESCE(road_marking, '') NOT IN ('', 'zigzag', 'x')
          AND COALESCE(stroke, '') NOT IN ('zebra', 'ladder')
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
            let colour: Option<String> = row.try_get("colour").ok().flatten();
            let dasharray: Option<String> = row.try_get("dasharray").ok().flatten();
            // QGIS: `@mercator_scale * "width"` (ground metres → map units); layer opacity 0.67.
            // A 0.12 m line is sub-pixel at z17–18 and stays a faint stroke, as in QGIS.
            let merc = mercator_scale(extent.bounds);
            let width_m = opt_f32(row, "width")
                .filter(|w| *w > 0.0)
                .map(f64::from)
                .unwrap_or(0.12)
                * merc;
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let mut color = road_marking_colour(colour.as_deref());
            color.set_alpha(ROAD_MARKING_LAYER_OPACITY);
            // Dash lengths scale with `@mercator_scale` too (`to_real(@element) * @mercator_scale`).
            let dash_scaled: Option<String> = dasharray
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty() && *s != "99;0")
                .map(|s| {
                    s.split(';')
                        .filter_map(|v| v.trim().parse::<f64>().ok())
                        .map(|v| format!("{}", v * merc))
                        .collect::<Vec<_>>()
                        .join(";")
                });
            stroke_lines_exact(pixmap, extent, geom, color, width_m, dash_scaled.as_deref());
        }
    });
    Ok(())
}

/// G5 road marking nodes: traffic signs / arrows / bicycle symbols on the carriageway.
fn paint_road_marking_node(
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
        SELECT
          road_marking,
          symbol,
          arrow,
          class,
          width::real AS width,
          length::real AS length,
          direction::real AS direction,
          {wkb_sql} AS wkb
        FROM road_marking_node
        WHERE geom && {env}
          AND ST_Intersects(geom, {env})
          AND road_marking IN ('traffic_sign', 'arrow', 'symbol')
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
            let road_marking: Option<String> = row.try_get("road_marking").ok().flatten();
            let symbol: Option<String> = row.try_get("symbol").ok().flatten();
            let arrow: Option<String> = row.try_get("arrow").ok().flatten();
            let class: Option<String> = row.try_get("class").ok().flatten();
            let Some(rel) = road_marking_node_svg(
                road_marking.as_deref(),
                symbol.as_deref(),
                arrow.as_deref(),
                class.as_deref(),
            ) else {
                continue;
            };
            // QGIS data-defined SVG sizes, in ground metres (× `@mercator_scale` → map units):
            // traffic_sign: width × length; arrow: 0.3·length·clamp(2 − length/5, 1, 2) × length;
            // symbol: width × length. No minimum size: at z15–18 a 0.6 m sign is sub-pixel in QGIS.
            let merc = mercator_scale(extent.bounds);
            let length_g = opt_f32(row, "length").map(f64::from);
            let width_g = opt_f32(row, "width").map(f64::from);
            let (width_g, length_g) = match road_marking.as_deref() {
                Some("arrow") => {
                    let l = length_g.unwrap_or(2.0);
                    (l * 0.3 * 1.0_f64.max(2.0_f64.min(2.0 - l / 5.0)), l)
                }
                _ => {
                    let l = length_g.or(width_g).unwrap_or(2.0);
                    (width_g.or(length_g).unwrap_or(2.0), l)
                }
            };
            let (width_m, height_m) = (width_g * merc, length_g * merc);
            // traffic_sign: QGIS/MapLibre rotate direction+180; arrows/symbols use direction.
            let mut direction = opt_f32(row, "direction").unwrap_or(0.0);
            if road_marking.as_deref() == Some("traffic_sign") {
                direction += 180.0;
            }
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
                    &rel,
                    pt.x(),
                    pt.y(),
                    width_m,
                    height_m,
                    direction,
                );
            }
        }
    });
    Ok(())
}

fn paint_building_shade(
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
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
    fill_polygons_shadow_only(pixmap, extent, &geoms, DropShadow::building_shade(), timers);
    Ok(())
}

/// QGIS `road_marking_*` layer opacity (`layerOpacity` 0.67).
const ROAD_MARKING_LAYER_OPACITY: f32 = 0.67;

/// QGIS `building_parts_dissolved_height` symbol alpha (`alpha="0.7"`).
const BUILDING_SYMBOL_ALPHA: f32 = 0.7;

fn paint_building_parts(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    // QGIS symbol alpha 0.7 on `#ffe9e9`; the dropShadow sits under the fill (see paint.rs).
    let mut color = fill_building();
    color.set_alpha(BUILDING_SYMBOL_ALPHA);
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
    fill_polygons_batch_shadow_under(pixmap, extent, &geoms, color, DropShadow::building(), timers);
    Ok(())
}

/// Stroke lines at their true width (no 0.5 px floor, unlike `stroke_lines_dashed`): QGIS draws
/// sub-pixel building and road lines as faint anti-aliased strokes, not as 1 px lines.
fn stroke_lines_exact(
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    geom: geo_types::Geometry<f64>,
    color: tiny_skia::Color,
    width_m: f64,
    dasharray_m: Option<&str>,
) {
    let mut width_px = extent.metres_to_px(width_m).max(0.01);
    let mut color = color;
    if width_px < 1.0 {
        // Sub-pixel strokes: draw 1 px at proportionally lower alpha (area coverage), since
        // tiny-skia's thin-stroke path does not reproduce the AA coverage of a sub-pixel line.
        color.set_alpha(color.alpha() * width_px);
        width_px = 1.0;
    }
    let mut paint = tiny_skia::Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    let dash = dasharray_m.and_then(|spec| {
        let parts: Vec<f32> = spec
            .split(';')
            .filter_map(|p| p.trim().parse::<f64>().ok())
            .map(|m| extent.metres_to_px(m).max(0.01))
            .collect();
        let mut arr = parts;
        if arr.is_empty() {
            return None;
        }
        if arr.len() % 2 == 1 {
            let first = arr[0];
            arr.push(first);
        }
        tiny_skia::StrokeDash::new(arr, 0.0)
    });
    let stroke = tiny_skia::Stroke {
        width: width_px,
        dash,
        ..tiny_skia::Stroke::default()
    };
    for line in crate::paint::geometry_lines(geom) {
        let Some(path) = crate::paint::linestring_to_path(extent, &line) else {
            continue;
        };
        pixmap.stroke_path(&path, &paint, &stroke, tiny_skia::Transform::identity(), None);
    }
}

/// QGIS `building_lines` (categorised by `class`): footline, part outlines, roof edges/ridges.
/// Widths are ground metres × `@mercator_scale` (`building_lines` symbols 0–4).
fn paint_building_lines(
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
        SELECT class, {wkb_sql} AS wkb
        FROM building_lines
        WHERE geom && {env}
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let merc = mercator_scale(extent.bounds);
    let grey = |_: u8| parse_hex_color("#808080").unwrap_or(tiny_skia::Color::BLACK);
    let footline = parse_hex_color("#cacaca").unwrap_or(tiny_skia::Color::BLACK);
    let dash_ground = "0.45;0.45";
    let dash_map: String = dash_ground
        .split(';')
        .filter_map(|v| v.parse::<f64>().ok())
        .map(|v| format!("{}", v * merc))
        .collect::<Vec<_>>()
        .join(";");
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let class: Option<String> = row.try_get("class").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            match class.as_deref() {
                Some("footline_covered") => {
                    stroke_lines_exact(pixmap, extent, geom.clone(), footline, 0.2 * merc, None);
                    stroke_lines_exact(pixmap, extent, geom, grey(255), 0.1 * merc, Some(&dash_map));
                }
                Some("footline_uncovered") => {
                    stroke_lines_exact(pixmap, extent, geom, grey(255), 0.05 * merc, None);
                }
                Some("part_outline") => {
                    stroke_lines_exact(pixmap, extent, geom, grey(255), 0.02 * merc, None);
                }
                Some("roof_edge" | "roof_ridge") => {
                    stroke_lines_exact(pixmap, extent, geom, grey(255), 0.04 * merc, None);
                }
                _ => {}
            }
        }
    });
    Ok(())
}

#[derive(Clone, Debug)]
pub struct TableCache {
    pub pitch: bool,
    pub pitch_markings: bool,
    pub playground_polygon: bool,
    pub playground_way: bool,
    pub playground_node: bool,
    pub water_body: bool,
    pub waterway: bool,
    pub highway_service: bool,
    pub highway: bool,
    pub landscape_way: bool,
    pub tactile_paving: bool,
    pub feature_node: bool,
    pub feature_polygon: bool,
    pub barrier_way: bool,
    pub barrier_node: bool,
    pub barrier_polygon: bool,
    pub barrier_node_has_foot: bool,
    pub stop_positions: bool,
    pub stop_positions_has_road_azimuth: bool,
    pub road_marking_polygon: bool,
    pub road_marking_way: bool,
    pub road_marking_node: bool,
    pub building_shade: bool,
    pub building_parts: bool,
    pub building_lines: bool,
    pub tree: bool,
    pub street_parking_point: bool,
    pub tree_has_leaf_type: bool,
    pub tree_has_rotation: bool,
    pub building_parts_has_height: bool,
    pub highway_oneway: bool,
    pub tunnel_entrance: bool,
    pub landuse_construction: bool,
}

impl TableCache {
    pub fn probe(client: &mut Client) -> Result<Self> {
        Ok(Self {
            pitch: table_exists(client, "pitch")?,
            pitch_markings: table_exists(client, "pitch_markings")?,
            playground_polygon: table_exists(client, "playground_polygon")?,
            playground_way: table_exists(client, "playground_way")?,
            playground_node: table_exists(client, "playground_node")?,
            water_body: table_exists(client, "water_body_dissolved")?,
            waterway: table_exists(client, "waterway_clipped")?,
            highway_service: table_exists(client, "highway_service")?,
            highway: table_exists(client, "highway")?,
            landscape_way: table_exists(client, "landscape_way")?,
            tactile_paving: table_exists(client, "tactile_paving")?,
            feature_node: table_exists(client, "feature_node")?,
            feature_polygon: table_exists(client, "feature_polygon")?,
            barrier_way: table_exists(client, "barrier_way")?,
            barrier_node: table_exists(client, "barrier_node")?,
            barrier_polygon: table_exists(client, "barrier_polygon")?,
            barrier_node_has_foot: column_exists(client, "barrier_node", "foot")?,
            stop_positions: table_exists(client, "stop_positions")?,
            stop_positions_has_road_azimuth: column_exists(client, "stop_positions", "road_azimuth")?,
            road_marking_polygon: table_exists(client, "road_marking_polygon")?,
            road_marking_way: table_exists(client, "road_marking_way")?,
            road_marking_node: table_exists(client, "road_marking_node")?,
            building_shade: table_exists(client, "building_shade")?,
            building_parts: table_exists(client, "building_parts_dissolved_height")?,
            building_lines: table_exists(client, "building_lines")?,
            tree: table_exists(client, "tree")?,
            street_parking_point: table_exists(client, "street_parking_point")?,
            tree_has_leaf_type: column_exists(client, "tree", "leaf_type")?,
            tree_has_rotation: column_exists(client, "tree", "rotation")?,
            building_parts_has_height: column_exists(
                client,
                "building_parts_dissolved_height",
                "height",
            )?,
            highway_oneway: table_exists(client, "highway_oneway")?,
            tunnel_entrance: table_exists(client, "tunnel_entrance")?,
            landuse_construction: table_exists(client, "landuse")?,
        })
    }
}

/// SvgMarker stamps for soccer / basketball / etc. (QGIS `pitch_markings`).
fn paint_pitch_markings(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    catalog: &PitchMarkingCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT
          sport,
          hoops,
          dist_long::real AS dist_long,
          dist_short::real AS dist_short,
          direction::real AS direction,
          {wkb_sql} AS wkb
        FROM pitch_markings
        WHERE geom && {env}
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
            let sport: Option<String> = row.try_get("sport").ok().flatten();
            let hoops: Option<String> = row.try_get("hoops").ok().flatten();
            let dist_long = opt_f32(row, "dist_long");
            let dist_short = opt_f32(row, "dist_short");
            let direction = opt_f32(row, "direction").unwrap_or(0.0);
            let Some(stem) = stem_for_feature(sport.as_deref(), hoops.as_deref(), dist_long) else {
                continue;
            };
            let width_m = f64::from(dist_long.unwrap_or(20.0)) * 0.95;
            let height_m = f64::from(dist_short.unwrap_or(dist_long.unwrap_or(20.0))) * 0.95;
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            for pt in geometry_points(geom) {
                stamp_at_map_point(
                    catalog,
                    pixmap,
                    extent,
                    stem,
                    pt.x(),
                    pt.y(),
                    width_m,
                    height_m.max(2.0),
                    direction,
                );
            }
        }
    });
    Ok(())
}

/// Parked cars: QGIS `street parking` layers (`<= z17` for scale 1:2000–1:1 000 000,
/// `> z17` below 1:2000; repeated per OSM `layer` bucket with the same symbol).
///
/// Each point is an SvgMarker `symbols/cars/<type>.svg` with `param(fill)` = `colour`,
/// rotated by `angle`, 2.4 m wide (`2.4 * @mercator_scale`), layer opacity 0.67. The
/// `> z17` layer adds a drop shadow. QGIS repeats the layer per `layer` bucket and also
/// keeps an unlayered copy; this paints each point once.
fn paint_street_parking_point(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    svg_stamps: &SvgStampCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    const CAR_LAYER_OPACITY: f32 = 0.67;
    const CAR_WIDTH_GROUND_M: f64 = 2.4;
    const CAR_TYPES: [&str; 7] = [
        "motor_vehicle01",
        "motor_vehicle02",
        "bus",
        "hgv",
        "hgv_articulated",
        "taxi",
        "emergency",
    ];
    let env = envelope_sql();
    let wkb_sql = clip_point_wkb_sql("geom");
    let sql = format!(
        r#"
        SELECT
          "type",
          colour,
          angle,
          {wkb_sql} AS wkb
        FROM street_parking_point
        WHERE geom && {env}
          AND ST_Intersects(geom, {env})
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let mscale = mercator_scale(extent.bounds);
    let width_m = CAR_WIDTH_GROUND_M * mscale;
    let shadow = scale_below_2000(extent).then(DropShadow::parked_car);
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let kind: Option<String> = row.try_get("type").ok().flatten();
            let Some(kind) = kind.filter(|k| CAR_TYPES.contains(&k.as_str())) else {
                continue;
            };
            let colour: Option<String> = row.try_get("colour").ok().flatten();
            let angle: f32 = row
                .try_get::<_, Option<i32>>("angle")
                .ok()
                .flatten()
                .unwrap_or(0) as f32;
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let Ok(geom) = decode_wkb(&wkb) else {
                continue;
            };
            let rel = format!("cars/{kind}.svg");
            for pt in geometry_points(geom) {
                svg_stamps.stamp_feature_marker(
                    pixmap,
                    extent,
                    &rel,
                    colour.as_deref(),
                    pt.x(),
                    pt.y(),
                    width_m,
                    None,
                    angle,
                    CAR_LAYER_OPACITY,
                    shadow,
                );
            }
        }
    });
    Ok(())
}

/// QGIS scale denominator below 1:2000 (the `> z17` layer ranges), at the harness DPI (96).
/// Web Mercator tiles are 256 px, so the nominal map scale has no latitude correction.
fn scale_below_2000(extent: RenderExtent) -> bool {
    const METRES_PER_INCH_OVER_DPI: f64 = 0.0254 / 96.0;
    let metres_per_px = 1.0 / f64::from(extent.metres_to_px(1.0));
    metres_per_px / METRES_PER_INCH_OVER_DPI < 2000.0
}

fn paint_tree(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
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
    // Older imports carry a random `rotation`; since main 05991fe QGIS draws
    // `rand(-20, 20, "osm_id")` instead — approximated by osm_id mod 41.
    let rot_col = if cache.tree_has_rotation {
        "rotation,"
    } else {
        "((osm_id % 41 + 41) % 41 - 20)::int AS rotation,"
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
        ORDER BY diameter_crown NULLS FIRST, osm_id
        "#
    );
    let rows = query_prep(
        client,
        prep_cache,
        timers,
        &sql,
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
    )?;
    let mscale = mercator_scale(extent.bounds);
    // QGIS `tree crown` maplayer: layerOpacity 0.25. Its drop shadow only exists in the
    // `> z17` layer (scale < 1:2000); the `<= z17` layer has none.
    const TREE_LAYER_OPACITY: f32 = 0.25;
    let crown_shadow = scale_below_2000(extent).then(DropShadow::tree_crown);
    // QGIS `trunk` maplayer sits above `tree crown` in the layer tree, so trunks
    // are collected and stamped after every crown.
    let mut trunks: Vec<(geo_types::Geometry<f64>, f64)> = Vec::new();
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
        let rotation: Option<f32> = row
            .try_get::<_, Option<i32>>("rotation")
            .ok()
            .flatten()
            .map(|r| r as f32);
        let Some(wkb) = wkb_from_row(row, "wkb") else {
            continue;
        };
        let Ok(geom) = decode_wkb(&wkb) else {
            continue;
        };
        if natural.as_deref() != Some("tree_stump") {
            let is_shrub = natural.as_deref() == Some("shrub");
            // QGIS: @mercator_scale * if(diameter_crown, diameter_crown, randf(5,9)|randf(3,6))
            let crown_ground_m = diameter
                .filter(|d| *d > 0.0)
                .map(f64::from)
                .unwrap_or(if is_shrub { 4.5 } else { 7.0 });
            let crown_map_m = crown_ground_m * mscale;
            let shadow = crown_shadow;
            let rotation_deg = rotation.unwrap_or(0.0);
            for pt in geometry_points(geom.clone()) {
                let (cx, cy) = map_to_px(
                    extent,
                    geo_types::Coord {
                        x: pt.x(),
                        y: pt.y(),
                    },
                );
                // Stable per-tree key for the crown image variant (QGIS: rand(1, N, "tid")).
                let variant = (pt.x().to_bits() ^ pt.y().to_bits().rotate_left(29))
                    .wrapping_mul(0x9E37_79B9_7F4A_7C15)
                    >> 32;
                draw_tree_crown_marker(
                    pixmap,
                    extent,
                    cx,
                    cy,
                    tree_markers,
                    leaf_type.as_deref(),
                    is_shrub,
                    variant,
                    crown_map_m,
                    rotation_deg,
                    shadow,
                    TREE_LAYER_OPACITY,
                );
            }
        }
        if let Some(c) = circumference.filter(|c| *c > 0.0).map(f64::from) {
            // QGIS trunk: size = @mercator_scale * circumference / π (a diameter).
            let trunk_r_map = c / (2.0 * std::f64::consts::PI) * mscale;
            trunks.push((geom, trunk_r_map));
        }
    }
    });
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        // QGIS trunk maplayer: layerOpacity 0.75.
        let mut trunk = fill_tree_trunk();
        trunk.set_alpha(0.75);
        for (geom, radius_m) in trunks {
            fill_circles_m(pixmap, extent, geom, trunk, radius_m);
        }
    });
    Ok(())
}
