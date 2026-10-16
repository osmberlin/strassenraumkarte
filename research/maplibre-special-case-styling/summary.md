# Styling special cases with MapLibre

How cartographers recreate difficult visual effects when moving from **raster** basemaps to **MapLibre vector styles**. Primary grounding: Stamen’s Terrain/Toner redesign for Stadia Maps, plus related Stadia and MapLibre primary docs.

Vector styles draw on the client from tiled **data** plus a JSON stylesheet. That unlocks smooth zoom, language swaps, and live restyling — but several raster-era tricks (Photoshop-like blur, some fill patterns, consistent label offsets from lines) are missing or behave differently. The chapters below collect **problem → solution** patterns from the research sources.

---

## 1. Soft / blurred landcover (raster blur → glow line layers)

### Problem

Classic Terrain used a soft, blurred landcover look (similar to a Photoshop blur on raster tiles). MapLibre has no general polygon blur. Hard-edged landcover fills look heavy and “digital” compared to the original.

### Why it’s hard

Raster pipelines can blur finished pixels. In MapLibre, `fill` layers are crisp. Soft edges have to be **simulated** with other layer types and paint properties ([Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/)).

### Solution

1. Keep solid **fill** layers for the landcover polygons.
2. Add **glow** layers as `type: "line"` on the same polygon outlines (or dedicated outline geometries).
3. Use **multiple** glow layers per class (Stamen used **two glows per landcover class**, four total in the overlapping mid-zoom stack).
4. Set glow colors **slightly lighter** than the fill to avoid a splotchy look.
5. Drive `line-width` and `line-blur` with the **same** interpolate expression so blur scales smoothly with zoom.
6. Soften stacking with `line-opacity` (and zoom stops) so glows sit cleanly on the fills.

Sketch of the paint pattern:

```json
{
  "type": "line",
  "paint": {
    "line-color": "#c8e0a8",
    "line-width": ["interpolate", ["linear"], ["zoom"], 7, 2, 12, 8],
    "line-blur": ["interpolate", ["linear"], ["zoom"], 7, 2, 12, 8],
    "line-opacity": ["interpolate", ["linear"], ["zoom"], 7, 0.6, 12, 0.35]
  }
}
```

`line-blur` is documented in the [MapLibre Style Spec layers](https://maplibre.org/maplibre-style-spec/layers/) (pixels of blur along the line). Under the hood, MapLibre/Mapbox line shaders feather edges via tessellation — the same mechanism that enables antialiasing and intentional blur ([Drawing Antialiased Lines with OpenGL](https://blog.mapbox.com/drawing-antialiased-lines-with-opengl-8766f34192dc)).

**Caveat:** wide translucent lines (especially with blur) can show join/overlap artifacts; keep glow widths moderate ([Mapbox GL issue on line artefacts](https://github.com/mapbox/mapbox-gl-js/issues/10000)).

---

## 2. Dual-resolution landcover (coarse + fine overzoom)

### Problem

After switching tile sources, detailed landcover only appeared from about **z7**, so low zooms looked empty or wrong. Coarse global landcover alone looked blocky when overzoomed.

### Why it’s hard

A single landcover layer rarely covers all zooms with the same visual weight. Overzooming coarse polygons shows coarse edges; waiting for fine data leaves a hole at world/continental scales ([Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/); [Stadia Global Landcover tutorial](https://docs.stadiamaps.com/tutorials/incorporating-global-landcover-tiles-maplibre/)).

### Solution

1. Add a **coarse / global** landcover source for low zooms (Stadia: ESA WorldCover–derived tiles, focused on z0–6, transitioning into standard vector landcover).
2. Keep **fine** landcover from the main vector tiles (e.g. OpenMapTiles `landcover`) from mid zooms up.
3. **Overlap** both from roughly **z7–12**: overzoom coarse data while fine data masks jagged edges.
4. Fade with `fill-opacity` / `maxzoom` / `minzoom` so the handoff is invisible.

Stadia’s tutorial pattern: separate vector source → categorical `fill-color` by `class` → opacity that drops toward the transition zoom → `maxzoom: 7` on the global layer.

---

## 3. Color palette remapping when the data schema changes

### Problem

Copying the old Terrain hex colors onto new vector landcover produced the wrong look: land too yellow, forests wrong green, hills less “hilly.” Classes available in the old raster data (e.g. rainforest vs alpine forest) did not exist in the new schema; new classes (wetland, urban, barren, …) appeared.

### Why it’s hard

Colors are not portable across datasets. Class names, coverage, and overlap differ; the palette must be redesigned for the **new** taxonomy and layering ([Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/); [familiar maps, brand new data](https://stamen.com/stamen-x-stadia-familiar-maps-brand-new-data/)).

### Solution

1. Start from the old palette only as a **reference**, not a 1:1 map.
2. Reclassify stylesheet filters/`match` expressions to the new classes (`wood`, `grass`, `wetland`, `ice`, `farmland`, `barren`, `urban`, …).
3. Drop unused legacy classes; add colors for new ones.
4. Tune colors together with opacity and glow layers — palette and soft edges are one system.
5. Expect schema gaps (e.g. admin label abbreviations) to limit 1:1 recreation until the tileset improves ([harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/)).

---

## 4. Opacity and zoom transitions for overlapping layers

### Problem

New landcover sources **overlap** in space and zoom. Without careful opacity, mid zooms turn muddy; without zoom stops, one dataset pops on/off.

### Why it’s hard

Vector styles composite many semi-transparent fills and lines. Raster Terrain baked a single blended image per tile; GL styles must encode that blend explicitly ([Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/)).

### Solution

- Use `interpolate` / stop expressions on `fill-opacity`, `line-opacity`, and sometimes color.
- Align opacity ramps with the coarse↔fine landcover handoff (see chapter 2).
- Prefer gradual crossfades over hard `minzoom`/`maxzoom` cuts where both datasets exist.
- Treat glow opacities as part of the same ramp so soft edges don’t flash brighter than the fill.

---

## 5. Effects that are hard or impossible in MapLibre

### Problem

Some raster cartography features do not translate cleanly:

| Raster-era effect | Vector / MapLibre reality |
| --- | --- |
| Labels consistently offset from line features | Hard or impossible to match exactly |
| Fill patterning (e.g. Watercolor washes) | `fill-pattern` exists but looks different; Watercolor not rebuilt as vector |
| Photoshop-style area blur | Approximated only (chapter 1); extreme blur styles stay raster |

([harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/); [familiar maps, brand new data](https://stamen.com/stamen-x-stadia-familiar-maps-brand-new-data/); [future of Stamen maps](https://stamen.com/here-comes-the-future-of-stamen-maps/))

### Solution (pragmatic)

1. **Recreate the look**, not the algorithm — accept small differences where the GL model differs.
2. Fix old raster **inconsistencies** while redesigning instead of cloning bugs.
3. Keep extreme raster effects as **raster** (or server-rasterized vector) when needed — Watercolor remains raster for this reason.
4. For patterns that *are* needed, use sprite `fill-pattern` / `line-pattern` knowing tiling and resolution will differ from Mapnik patterns ([MapLibre “Add a pattern to a polygon” example](https://maplibre.org/maplibre-gl-js/docs/examples/add-a-pattern-to-a-polygon/); this repo’s QGIS textures are a related concern if porting street-space styles).

---

## 6. Layer order and “map sandwiches”

### Problem

In the raster era, inserting data between basemap “bottom” and “labels” required special sandwich tiles. Designers still need: land → landcover → hillshade → roads → overlays → labels.

### Why it’s hard

Less hard than before — but order is still easy to get wrong. Layers paint in style order; dynamic `addLayer` appends on top unless you pass `beforeId` ([Bathyl: MapLibre for geological maps](https://www.bathyl.com/en/blog/maplibre-for-geological-web-maps/); [bathymetry layer insertion](https://snailbones.medium.com/styling-oceans-with-bathymetry-in-maplibre-a326e912e02f)).

### Solution

1. Treat the style JSON layer list as the sandwich: bottom = ground/landcover/hillshade, top = symbols.
2. Insert thematic layers with `map.addLayer(layer, beforeId)` **above** water/land and **below** label layers.
3. Keep labels in symbol layers near the top so they are not buried.
4. Client-side reordering replaces regenerating world raster tiles ([harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/)).

Typical stack (bottom → top): basemap land → hillshade → landcover fills → landcover glows → roads → data overlay → labels.

---

## 7. Client-side customization vs regenerating rasters

### Problem

Changing colors, fonts, languages, or layer visibility on a global raster meant re-rendering the world. That was prohibitive for Stamen’s classic tiles and for app-specific variants.

### Solution

Vector + MapLibre:

- Restyle with JSON / Maputnik; host your own style URL ([Stadia custom styles](https://docs.stadiamaps.com/custom-styles/)).
- Change label language client-side (e.g. Open Etymology Map on Toner).
- Derive variants cheaply (Toner Dark / Blacklite from shared build tooling) ([What We Map in the Shadows](https://stamen.com/what-we-map-in-the-shadows/); [Dark Map Materials](https://stamen.com/stamens-dark-map-materials/)).
- Expect ~**60%** of the tile requests vs the same map as raster ([harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/)).

---

## 8. Hillshade / terrain emphasis with fresh data

### Problem

Terrain’s identity includes crisp hillshade and natural colors. New data and vector landcover changed how relief and vegetation read together; “same colors” alone were not enough.

### Solution

- Use a `raster-dem` source + `hillshade` layer under semi-transparent landcover so structure shows through ([MapLibre hillshade examples](https://maplibre.org/maplibre-gl-js/docs/examples/); geological-map guidance on exaggeration ~1.3–1.6).
- Retune landcover colors **with** hillshade visible — Stamen’s early drafts failed partly because relief and landcover were out of balance ([Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/)).
- Prefer updated DEM/OMT stacks (Stadia) so hillshade and features stay current ([familiar maps, brand new data](https://stamen.com/stamen-x-stadia-familiar-maps-brand-new-data/)).

---

## 9. Migration path: server-side rasterization of vector styles

### Problem

Apps stuck on Leaflet/raster APIs cannot switch to MapLibre overnight, but still need fresh OSM-derived data.

### Solution

Stadia **rasterizes** the new vector styles server-side. Clients keep raster URLs (after host migration) while the cartography and data stay on the modern stack. Tradeoff: rasters cost more bandwidth/money; migrate to vector when possible ([harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/); [future of Stamen maps](https://stamen.com/here-comes-the-future-of-stamen-maps/); [Stadia × Stamen partnership](https://stadiamaps.com/blog/stamen-design-and-stadia-maps/)).

For Leaflet that needs **custom** vector styling without leaving Leaflet, `maplibre-gl-leaflet` is the documented bridge ([Stadia custom styles](https://docs.stadiamaps.com/custom-styles/)).

---

## 10. Invert / variant styles without rebuilding data

### Problem

Need dark or inverse basemaps for UI themes without a second world render.

### Solution

Because paint lives in the style:

1. Fork the style (or use a multi-variant build system such as Stamen’s Map GL Build System).
2. Invert or shift colors systematically, then **fix patterns/sprites** so textures still read on dark grounds (Toner Blacklite).
3. Validate contrast (land vs water) — dark maps fail when land/water lightness collapses ([Dark Map Materials](https://stamen.com/stamens-dark-map-materials/)).

---

## Quick reference: technique → MapLibre levers

| Cartographic goal | Levers |
| --- | --- |
| Soft landcover edges | Extra `line` layers; matched `line-width` + `line-blur`; lighter glow colors; opacity |
| Low-zoom landcover | Second source (global landcover); overlap z-range; opacity crossfade |
| Schema change | Remap `match`/`filter`; redesign palette with layering |
| Data between basemap & labels | Layer order + `beforeId` |
| Relief | `hillshade` under translucent fills |
| Stay on raster APIs | Server rasterization of vector style |
| Language / theme variants | Client style edits; shared build pipeline |

---

## Research sources

Full bibliography with per-URL summaries: [sources.md](./sources.md).

### Seed articles (user-provided)

1. [Stamen x Stadia series: Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/) — Deep dive on recreating Terrain’s soft landcover with dual datasets, glow/`line-blur` stacks, and palette redesign.
2. [Stamen x Stadia: harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/) — Why vector/MapLibre, what is easier vs harder than raster, data refresh to OpenMapTiles, rasterization fallback.

### Closely related Stamen / Stadia series

3. [Stamen x Stadia: familiar maps, brand new data](https://stamen.com/stamen-x-stadia-familiar-maps-brand-new-data/) — OSM/OpenMapTiles refresh; why Watercolor stays raster.
4. [Here comes the future of Stamen Maps](https://stamen.com/here-comes-the-future-of-stamen-maps/) — Partnership context; vector advantages (~60% tile requests); Watercolor exception.
5. [Stamen Design × Stadia Maps](https://stadiamaps.com/blog/stamen-design-and-stadia-maps/) — Partnership announcement; MapLibre rebuild; customization pitch.
6. [What We Map in the Shadows](https://stamen.com/what-we-map-in-the-shadows/) — Toner Dark / Blacklite as cheap vector variants.
7. [Stamen’s Dark (Map) Materials](https://stamen.com/stamens-dark-map-materials/) — Dark basemap contrast theory; Toner variants vs other dark styles.
8. [Debugging 101 with Stamen Carto Tools](https://stamen.com/debugging-101-with-stamen-carto-tools-and-other-tools-we-like/) — Maperture, MapLibre vs Mapbox GL differences, Map GL Style Build.

### Primary docs & tutorials

9. [Stadia: Incorporating Global Landcover Tiles with MapLibre](https://docs.stadiamaps.com/tutorials/incorporating-global-landcover-tiles-maplibre/) — Practical coarse landcover source + categorical fills + opacity stops.
10. [Stadia: Custom Map Styling](https://docs.stadiamaps.com/custom-styles/) — Maputnik workflow, OMT schema, sprites/glyphs, Leaflet bridge.
11. [MapLibre Style Spec — Layers](https://maplibre.org/maplibre-style-spec/layers/) — Authoritative `line-blur`, fill, hillshade, symbol properties.
12. [MapLibre GL JS examples](https://maplibre.org/maplibre-gl-js/docs/examples/) — Patterns, hillshade, expressions, layer styling demos.

### Technical background

13. [Drawing Antialiased Lines with OpenGL (Mapbox)](https://blog.mapbox.com/drawing-antialiased-lines-with-opengl-8766f34192dc/) — Why `line-blur` / soft edges exist at the shader level.
14. [Mapbox GL: strange artefacts with line layers](https://github.com/mapbox/mapbox-gl-js/issues/10000) — Limits of wide translucent / blurred lines.
15. [MapLibre for Geological Web Maps (Bathyl)](https://www.bathyl.com/en/blog/maplibre-for-geological-web-maps) — Layer order, hillshade under fills, `beforeId`.
16. [Styling Oceans with Bathymetry in MapLibre](https://snailbones.medium.com/styling-oceans-with-bathymetry-in-maplibre-a326e912e02f) — Inserting a thematic fill into an existing style sandwich.
