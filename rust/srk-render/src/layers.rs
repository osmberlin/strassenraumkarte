//! Layer paint passes for `highway_area` isolate and `full-approx`.

use anyhow::{Context, Result};
use postgres::Client;
use tiny_skia::Pixmap;

use crate::paint::{
    clip_line_wkb_sql_fast, clip_point_wkb_sql, clip_polygon_wkb_sql_fast, decode_wkb,
    draw_tree_crown_marker, envelope_sql, fill_circles_m, fill_polygons,
    fill_polygons_batch_with_shadow, fill_polygons_shadow_only, fill_polygons_textured,
    geometry_points, map_to_px, stroke_lines, DropShadow,
};
use crate::palette::{
    fill_building, fill_for_area_highway, fill_for_landuse, fill_for_pitch,
    fill_tree_trunk, fill_water, highway_surface_texture, landuse_class_texture,
    landuse_surface_texture, pitch_surface_texture, stroke_path, stroke_service, stroke_waterway,
    surface_colour, AREA_HIGHWAY_PAINTED,
};
use crate::profile::{StageSlot, StageTimers};
use crate::sql_cache::{query_prep, PreparedCache};
use crate::pitch_markings::{stamp_at_map_point, stem_for_feature, PitchMarkingCatalog};
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
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
                    fill_polygons_textured(pixmap, extent, geom, fill_color, texture);
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
    mt: MetaTile,
    out_dir: &std::path::Path,
    format_ext: &str,
    quiet: bool,
    cache: &TableCache,
    textures: &TextureCatalog,
    tree_markers: &TreeMarkerCatalog,
    pitch_markings: &PitchMarkingCatalog,
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
    if cache.water_body {
        paint_water_body(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.waterway {
        paint_waterway(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.highway {
        paint_highway_path(client, prep_cache, &mut pixmap, extent, z, timers)?;
    }
    if cache.highway_service {
        paint_highway_service(client, prep_cache, &mut pixmap, extent, z, timers)?;
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
    if cache.road_marking_polygon {
        paint_road_marking_polygon(client, prep_cache, &mut pixmap, extent, z, timers)?;
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

    if cache.tree && z >= 17 {
        paint_tree(
            client,
            prep_cache,
            &mut pixmap,
            extent,
            z,
            cache,
            tree_markers,
            timers,
        )?;
    }

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
    if cache.tree && z >= 17 {
        parts.push(format!("EXISTS (SELECT 1 FROM tree WHERE geom && {env})"));
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
                Ok(geom) => fill_polygons_textured(pixmap, extent, geom, base, texture),
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
    crate::profile::time_stage(timers, StageSlot::Paint, || {
        for row in &rows {
            let surface: Option<String> = row.try_get("surface").ok().flatten();
            let colour: Option<String> = row.try_get("surface_colour").ok().flatten();
            let sport: Option<String> = row.try_get("sport").ok().flatten();
            let Some(wkb) = wkb_from_row(row, "wkb") else {
                continue;
            };
            let base = fill_for_pitch(colour.as_deref(), surface.as_deref(), sport.as_deref());
            let texture = surface
                .as_deref()
                .and_then(pitch_surface_texture)
                .and_then(|(id, opacity)| textures.get(id).map(|t| (t, opacity)));
            if let Ok(geom) = decode_wkb(&wkb) {
                fill_polygons_textured(pixmap, extent, geom, base, texture);
            }
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
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
                let width_map = width_m * mercator_scale(extent.bounds);
                stroke_lines(
                    pixmap,
                    extent,
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
    extent: RenderExtent,
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
        &[&extent.bounds.minx, &extent.bounds.miny, &extent.bounds.maxx, &extent.bounds.maxy],
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
                fill_polygons(pixmap, extent, geom, fill);
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
    fill_polygons_batch_with_shadow(pixmap, extent, &geoms, color, DropShadow::building(), timers);
    Ok(())
}

#[derive(Clone, Debug)]
pub struct TableCache {
    pub pitch: bool,
    pub pitch_markings: bool,
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
            pitch_markings: table_exists(client, "pitch_markings")?,
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

fn paint_tree(
    client: &mut Client,
    prep_cache: &mut PreparedCache,
    pixmap: &mut Pixmap,
    extent: RenderExtent,
    z: u32,
    cache: &TableCache,
    tree_markers: &TreeMarkerCatalog,
    timers: &mut Option<&mut StageTimers>,
) -> Result<()> {
    if z < 17 {
        return Ok(());
    }
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
    // QGIS `tree crown` maplayer: layerOpacity 0.25. Soft disks need a bit more
    // to match the visual weight of the RasterMarker photo texture.
    const TREE_LAYER_OPACITY: f32 = 0.38;
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
            // QGIS: @mercator_scale * if(diameter_crown, diameter_crown, randf(5,9)|randf(3,6))
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
            let marker = tree_markers.for_leaf_type(leaf_type.as_deref());
            for pt in geometry_points(geom.clone()) {
                let (cx, cy) = map_to_px(
                    extent,
                    geo_types::Coord {
                        x: pt.x(),
                        y: pt.y(),
                    },
                );
                draw_tree_crown_marker(
                    pixmap,
                    extent,
                    cx,
                    cy,
                    marker,
                    crown_map_m,
                    rotation_deg,
                    shadow,
                    TREE_LAYER_OPACITY,
                );
            }
        }
        if let Some(c) = circumference.filter(|c| *c > 0.0).map(f64::from) {
            let trunk_r_ground = c / (2.0 * std::f64::consts::PI);
            let mut trunk = fill_tree_trunk();
            trunk.set_alpha(0.8);
            fill_circles_m(
                pixmap,
                extent,
                geom,
                trunk,
                trunk_r_ground * mscale,
            );
        }
    }
    });
    Ok(())
}
