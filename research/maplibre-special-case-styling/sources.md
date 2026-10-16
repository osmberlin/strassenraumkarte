# Research sources

Bibliography for [summary.md](./summary.md). Summaries are factual overviews of what each source covers; they are not endorsements.

## Seed articles

### [Stamen x Stadia series: Terrain behind the scenes](https://stamen.com/stamen-x-stadia-series-terrain-behind-the-scenes/)
**Stamen Design**

Walkthrough of rebuilding Stamen Terrain as a MapLibre/vector style. Covers why color and visual effects were harder than expected; dual coarse+fine landcover; approximating raster blur with multiple glow `line` layers; matching `line-width` and `line-blur` expressions; lighter glow colors; opacity stacking; and remapping the palette to a new landcover class set.

### [Stamen x Stadia: harnessing modern vector cartography](https://stamen.com/stamen-x-stadia-harnessing-modern-vector-cartography/)
**Stamen Design**

Explains the move from raster tiles to MapLibre vector cartography: crisp rendering at fractional zooms, client customization, blurry basemap/data-layer boundary, performance (~60% of raster tile requests), limits (line-offset labels, fill patterning), OpenMapTiles data refresh, and Stadia’s server-side rasterization of vector styles for migration.

## Related Stamen / Stadia series

### [Stamen x Stadia: familiar maps, brand new data](https://stamen.com/stamen-x-stadia-familiar-maps-brand-new-data/)
**Stamen Design**

Focuses on the data story: aging 2011-era OSM extracts vs monthly OpenMapTiles updates; examples of new real-world features appearing on the map; and why Watercolor’s blurred aesthetic is poorly suited to a vector rebuild (tiles preserved via Stadia / Smithsonian).

### [Here comes the future of Stamen Maps](https://stamen.com/here-comes-the-future-of-stamen-maps/)
**Stamen Design**

Announcement that Stamen tiles move to Stadia Maps: cost/maintenance motivation, partnership rationale (OpenMapTiles, MapLibre, privacy), vector recreations of Toner and Terrain, optional raster endpoints, and Watercolor remaining raster-only without data updates.

### [Stamen Design × Stadia Maps](https://stadiamaps.com/blog/stamen-design-and-stadia-maps/)
**Stadia Maps**

Partnership launch post: hosting refreshed Toner, Terrain, and Watercolor; rebuild on MapLibre; vector vs raster delivery; customization (colors, layers, language); migration path for existing Stamen tile users.

### [What We Map in the Shadows](https://stamen.com/what-we-map-in-the-shadows/)
**Stamen Design**

Shows how vector styles enable fast variants: Toner Dark and Toner Blacklite derived from existing Toner/Toner Lite via Stamen’s Map GL Build System; inverting colors and adjusting patterns for dark backgrounds; availability through Stadia.

### [Stamen’s Dark (Map) Materials](https://stamen.com/stamens-dark-map-materials/)
**Stamen Design**

Broader essay on dark basemap design: when “dark vibes” vs true low-light maps diverge; contrast between land and water; comparison of vendor dark styles; scatterplot/contrast analysis including Toner Dark and Blacklite.

### [Debugging 101 with Stamen Carto Tools](https://stamen.com/debugging-101-with-stamen-carto-tools-and-other-tools-we-like/)
**Stamen Design**

Practical tooling for GL style work: Maperture for side-by-side MapLibre vs Mapbox GL rendering differences; Chartographer for symbol layers; Map GL Style Build for multi-variant stylesheets and regression-resistant fixes.

## Primary documentation & tutorials

### [Incorporating Global Landcover Tiles with MapLibre GL JS](https://docs.stadiamaps.com/tutorials/incorporating-global-landcover-tiles-maplibre/)
**Stadia Maps Docs**

Step-by-step: add Stadia’s global landcover vector source (ESA WorldCover–based, low zooms), style with categorical `fill-color` by `class`, fade with `fill-opacity` stops, and cap with `maxzoom` so it hands off to standard tile landcover.

### [Custom Map Styling](https://docs.stadiamaps.com/custom-styles/)
**Stadia Maps Docs**

How to fork Stadia MapLibre styles in Maputnik, host custom JSON, map OpenMapTiles schemas, customize sprites/fonts, and use `maplibre-gl-leaflet` when staying on Leaflet.

### [Layers — MapLibre Style Spec](https://maplibre.org/maplibre-style-spec/layers/)
**MapLibre**

Authoritative reference for layer types and paint/layout properties, including `line-blur`, fill/line/symbol/hillshade behavior, and expression support. The contract for any glow or soft-edge technique.

### [MapLibre GL JS examples](https://maplibre.org/maplibre-gl-js/docs/examples/)
**MapLibre**

Official demos for patterns (`fill-pattern`), hillshade (including multidirectional), expressions, layer color changes, and related styling building blocks.

## Technical background & adjacent articles

### [Drawing Antialiased Lines with OpenGL](https://blog.mapbox.com/drawing-antialiased-lines-with-opengl-8766f34192dc/)
**Mapbox (2014)**

Engineering background for GL line rendering: tessellation, normals, and feathering. Explains why controllable edge softness (`line-blur`-style effects) exists and how “blur” is related to antialiasing feathers.

### [Strange rendering artefacts with the line layer](https://github.com/mapbox/mapbox-gl-js/issues/10000)
**mapbox/mapbox-gl-js (GitHub)**

Documents visual artifacts on wide, low-opacity, or blurred lines at joins — a practical limit when stacking landcover glow layers.

### [MapLibre for Geological Web Maps](https://www.bathyl.com/en/blog/maplibre-for-geological-web-maps)
**Bathyl**

Applied MapLibre patterns: sources vs layers, hillshade under translucent fills, layer-order pitfalls, and `addLayer(..., beforeId)` for sandwiching thematic data.

### [Styling Oceans with Bathymetry in MapLibre](https://snailbones.medium.com/styling-oceans-with-bathymetry-in-maplibre-a326e912e02f)
**Aidan H (Medium)**

Inserting a depth-colored fill into an existing basemap style: `step` expressions on attributes and placing the layer above `water` but below labels via `beforeId`.

## Notes on coverage gaps

- No dedicated public “Toner behind the scenes” post matching the Terrain deep dive was found in this pass; Toner variant workflow is covered indirectly via the dark-Toner posts and the harnessing-vector overview.
- Watercolor-style organic washes remain largely **out of scope** for vector MapLibre; sources treat that as an intentional raster holdout.
- This bibliography prioritizes first-party Stamen/Stadia/MapLibre material over secondary blog roundups.
