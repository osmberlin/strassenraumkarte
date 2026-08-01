# MapLibre style port — layer groups

Work doc for porting `style/strassenraumkarte.qgz` to a MapLibre GL style, group by group.
Companion to the plan *MapLibre vector output channel*.

**Scale of the job:** 64 unique map layers (256 `maplayer` entries — most are duplicated 7× for OSM
`layer` stacking), ~812 renderer rules, 1058 SimpleLine / 835 SimpleFill / 803 SimpleMarker /
185 SvgMarker / 133 RasterFill symbol layers, 137 enabled paint effects, 0 geometry generators.

All numbers below were extracted from the project XML (`strassenraumkarte.qgs` inside the `.qgz`).
**MapUnit = ground metres** throughout; `MM`/`Point` are paper units and do *not* scale with zoom.

---

## How to use this doc

1. Finish **G0 (cross-cutting)** first — every other group depends on it.
2. Then work groups in the order given in [Work order](#work-order).
3. Per group: build the layers, run `bun run screenshots`, compare the diff score at the
   comparison locations, check the console is clean, then tick the checklist.
4. Record deviations from QGIS in the group's *Known deviations* line — the goal is a
   convincing recreation, not a pixel clone.

---

## G0 — Cross-cutting (do first)

These five concerns appear in nearly every group. Solve them once in shared modules.

### G0.1 Ground metres → pixels

Almost every width, size and offset in the project is a ground-metre value multiplied by the
project variable `@mercator_scale` (≈ 1.64 in Berlin, = 1/cos φ). MapLibre paints in CSS pixels
with 512 px tiles:

```
px = metres * 2^zoom / (78271.51696 * cos φ)
```

That is exactly base-2 exponential in zoom, so a two-stop interpolation is *exact*, not an
approximation:

```ts
metresToPixels(m) // -> ['interpolate', ['exponential', 2], ['zoom'], 15, …, 20, …]
```

Everything else in this doc quotes metres, so it can be passed straight into that helper.

**Watch out:** a few properties use paper units and must stay constant in pixels —
`building_shade` outline (0.26 MM), the `z14`–`z20` blur radii (MM), label font sizes (Point),
label buffers (Point). Do not run those through `metresToPixels`.
One expression in `path (way, fill)` / access_aisle uses `@scale_factor` instead of
`@mercator_scale` — likely a typo in the QGIS project; treat it as `@mercator_scale`.

### G0.2 OSM `layer` stacking (×7)

`update_highway_layered.py` clones the `map/highway (unlayered)` template into six filtered
copies: `"layer" >= 3`, `= 2`, `= 1`, `= 0 OR IS NULL`, `= -1`, `<= -2`. This affects G4, G5, G6
and parts of G3.

In MapLibre, do **not** create six copies of every layer *naively without a plan*. Decide early between:

- one style layer per `layer` bucket (faithful, verbose), or
- a single layer per style layer with `symbol-sort-key` / `sort-key` on `["get","layer"]`
  (compact, but interleaving across *different* style layers is lost).

**Decision (w4a):** use **one style-layer set per OSM bucket** for stacked source-layers
(`highway_area`, `highway_service`, markings, …). Helpers: `vector/src/style/order.ts`
(`OSM_LAYER_BUCKETS`, `osmLayerFilter`). `sort-key` alone cannot put markings on `layer=1`
above highway on `layer=0` while still under highway on `layer=1`.

### G0.3 Effect primitives (137 enabled effects)

QGIS paint effects have no MapLibre equivalent. Build three helpers and reuse them everywhere:

| Helper | QGIS source | MapLibre approximation |
| --- | --- | --- |
| `dropShadow` | 77 enabled | duplicate fill below with `fill-translate` (offset dist + angle) and reduced `fill-opacity`, plus a `line` layer with matched `line-width`/`line-blur` for the feathered edge |
| `innerShadow` | 60 enabled | `line` layer on the polygon ring with negative `line-offset` (half the width, inward) + `line-blur` |
| `outerGlow` / `innerGlow` | 7 / 1 enabled | two stacked blurred outline `line` layers, colour slightly lighter than the fill, opacity on the same zoom stops |

Always drive `line-width` and `line-blur` from the **same** interpolation
(see [research/maplibre-special-case-styling](../research/maplibre-special-case-styling/summary.md), ch. 1),
and keep glow widths moderate to avoid join artefacts on wide translucent lines.

Effect blur/offset values are stored as static MapUnit numbers without a `@mercator_scale`
expression, so it is not certain from the XML whether QGIS scales them with the project variable
at render time. Assume they do (they are MapUnit) and verify against the raster reference.

### G0.4 Textures → sprite `fill-pattern`

A closed set of ~12 PNG textures under `style/textures/` covers all 133 RasterFill uses:

`grass.png`, `gravel.png`, `sand.png`, `water.png`, `wetland.png`, `flowerbed.png`,
`woodchips.png`, `surface/asphalt.png`, `surface/concrete.png`, `surface/paving_stones.png`,
`surface/sett.png`, plus `style/textures/pitches/*.svg`.

Because the set is closed and known, put them in a build-time sprite rather than loading at
runtime. Two RasterFill parameters have no clean MapLibre equivalent and need a decision:

- **`width` in MapUnit** (e.g. sett 11 m, water 30–35 m, paving_stones 4.5 m) — `fill-pattern`
  tiles at the sprite's own pixel size, so ground-metre texture scale is lost. Options: bake
  several pre-scaled sprite variants per zoom band, or accept a fixed pixel scale.
- **`angle` expressions** (e.g. sett `"direction"`, paving_stones `"direction" + 45`) —
  `fill-pattern` cannot rotate. Either bake rotated variants or drop the rotation.

`width 0 Pixel` in the XML means *native texture resolution* (no ground scaling) — those cases
map cleanly onto `fill-pattern`.

### G0.5 Runtime icons (unbounded set)

`style/symbols/` holds ~228 SVGs selected by field-driven expressions
(`'symbols/traffic_signs/' + "class" + '/' + "symbol" + '.svg'`, etc.), so the id set is not
closed. Use MapLibre 6's `map.setMissingStyleImageResolver` to rasterize on demand
(see [research/maplibre-ad-hoc-image-loading](../research/maplibre-ad-hoc-image-loading/summary.md)):
guard with `hasImage`, skip `'null'` / `''` sentinels, re-register after `setStyle`.

Prefer base shapes where the QGIS symbol is trivially geometric — a large share of the 803
SimpleMarkers are plain circles/squares that become `circle` layers with no image at all.

### G0.6 Draw order

The QGIS layer tree order (top of tree = drawn last) is the style's layer order reversed.
Groups below are numbered **bottom-up**, i.e. G1 paints first, G12 paints last.

---

## Work order

Core street space first, then outward. `~L` = unique QGIS layers in the group.

| # | Group | ~L | Difficulty | Why this position |
| --- | --- | --- | --- | --- |
| 1 | [G4 Street surface](#g4--street-surface) | 12 | High | The signature look; unblocks everything visual |
| 2 | [G5 Road markings](#g5--road-markings) | 4 | High | Meaningless without G4 underneath |
| 3 | [G1 Land & landcover](#g1--land--landcover) | 7 | Medium | Largest category count, but mostly flat fills |
| 4 | [G2 Water](#g2--water) | 5 | Medium | Small, exercises Shapeburst approximation |
| 5 | [G9 Trees](#g9--trees) | 2 | Low | High visual payoff for two layers |
| 6 | [G10 Buildings](#g10--buildings) | 5 | Medium | Second-biggest visual mass |
| 7 | [G12 Labels](#g12--labels) | 6 | Medium | Needs glyphs; independent of the rest |
| 8 | [G6 Furniture & barriers](#g6--street-furniture--barriers) | 11 | High | Biggest icon surface; needs G0.5 proven |
| 9 | [G3 Landscape, bridges & railway](#g3--landscape-bridges--railway) | 7 | Low | Rare features |
| 10 | [G11 Foreground POI](#g11--foreground-poi) | 2 | Low | Small |
| 11 | [G8 Symbol patterns](#g8--symbol-patterns) | 2 | Low | Two pattern fills |
| 12 | [G7 Parked cars](#g7--parked-cars) | 1 | Blocked | External GeoJSON, not in PostGIS |

---

## G1 — Land & landcover

Bottom of the stack. Tables: `landuse`, `playground_polygon`, `pitch`, `pitch_markings`.

| Layer | Geom | Renderer | Detail |
| --- | --- | --- | --- |
| `landuse` | Polygon | categorized on `class` | **65 categories**, 67 SimpleFill + 48 RasterFill; dropShadow ×7, outerGlow ×6, innerGlow ×2, innerShadow ×2 |
| `landuse surface` | Polygon | categorized on `surface` | 19 categories, RasterFill only, filter `"surface" IS NOT NULL` |
| `scrub (width shade)` | Polygon | categorized on `class` | filter `class IN ('scrub')`; dropShadow + outerGlow |
| `sandpit` | Polygon | categorized | filter `playground = 'sandpit'`; renderer-level innerShadow |
| `pitch` | Polygon | single | fill from a 10-branch `CASE` on `surface:colour` / `surface` / `sport` |
| `pitch surface` | Polygon | categorized on `surface` | same 19 texture categories as `landuse surface` |
| `pitch_markings` | Point | single | SvgMarker into `textures/pitches/*.svg`, ~40-line aspect-fit size expression |

**Straightforward:** the bulk is `SimpleFill` + a `match` on `class`. Most categories share one of
about a dozen colours — build a colour table, not 65 hand-written layers.

**Representative values:** `park`/`allotments`/`cemetery` `#dfefce` + grass texture α 0.06;
`grass`-family `#d4e3c4` + grass α 0.06; `forest`/`wood`/`trees` `#c4d8af` + grass α 0.09 with
dropShadow (blur 1 m, offset 0.4 m @ 40°, `#232323`, opacity 0.33) and outerGlow
(blur/spread 0.75 m, `#c8dbb6`); gravel-family `#dddddd` + gravel α 0.08; institutional
(`school`, `college`, `kindergarten`, `social_facility`, `community_centre`) `#ede6e0`;
`parking` `#dbdde1`.

**Hard parts**

- Texture scale/rotation for `sett` (11 m, `"direction"`), `paving_stones` (4.5 m,
  `"direction" + 45`), `water` (30–35 m), `blockfield`/`shingle` gravel at 65 m — see G0.4.
- `pitch_markings` aspect-fit SVG sizing. MapLibre cannot resize an icon to fit a polygon's
  bounding box. Either precompute the icon id **and** a pixel size per feature in the exporter,
  or draw pitch markings as real geometry from PostGIS instead of an icon.
- `outdoor_seating` uses a LinePatternFill at 1.2 m / 135° with a `#0000ff` base fill — almost
  certainly a debugging leftover; confirm before porting.

**Known deviations:** texture ground-scale and rotation dropped (`fill-pattern` uses
sprite pixel size; `direction` / `sett:length` exported for future use). `pitch_markings`
use packed `pitches/*` sprites sized uniformly from `dist_long` (×0.95) — MapLibre cannot
independently fit width/height to the pitch aspect ratio the way QGIS does. Wetland stays
in G2 (not a landuse `class` overlay).

- [x] colour/texture table for all 65 `landuse` classes
- [x] `landuse surface` + `pitch surface` (shared 19-entry texture table)
- [x] forest/scrub/shrub glow + shadow via G0.3 helpers
- [x] `pitch` fill `CASE` and `pitch_markings` decision
- [x] `sandpit`

---

## G2 — Water

Tables: `water_body_dissolved`, `water_body`, `waterway_clipped`.

| Layer | Geom | Detail |
| --- | --- | --- |
| `water body` | Polygon | 4 symbol layers: SimpleFill `#cac7ed` + a pass-100 `#0000ff` mask fill + ShapeburstFill + RasterFill `water.png` 35 m α 0.2 @ 30°; innerShadow ×3 (blur 4 m, offset 0 @ 135°, `#a396d9`) |
| `water body (depth effect)` | Polygon | single ShapeburstFill, max_distance 100 MM, blur 18 MM, ramp `#457428` → `#bcdc3c`, base fill fully transparent |
| `water_body (simple backup)` | Polygon | **unchecked in the layer tree — do not port** |
| `wetland` | Polygon | single RasterFill `wetland.png` 30 m α 0.3, filter `natural = 'wetland'` |
| `waterway_clipped` | Line | 4 rules: river/canal 12 m and stream/ditch/drain 1.5 m, each with a dotted tunnel/covered variant, all `#b2abe0`, width from `"width"` |

**Hard parts**

- The Shapeburst shoreline fade is a distance-to-edge fill with a data-defined maximum
  distance: `@mercator_scale * clamp(10 * log10($area) - 25, 1.5, 20)` — the fade scales with
  waterbody area. MapLibre has no distance field. Approximate with 2–3 concentric inward
  blurred `line` layers whose width is driven by a precomputed per-feature area attribute
  exported from PostGIS.
- The pass-100 `#0000ff` fill and pass-101 texture form a compositing trick whose intent is not
  documented in the XML. Inspect the raster output before copying it.

**Known deviations:** shoreline fade is banded rather than continuous (3 inward
blurred `line` rings scaled by exported `shore_m`); water.png RasterFill and the
green `water body (depth effect)` Shapeburst are not ported; wetland texture
ground-metre scale dropped (`fill-pattern` sprite pixels); waterway open vs
tunnel/covered are split layers with class-based width fallbacks when `"width"`
is null.

- [x] base fill + inner shadow
- [x] shoreline fade approximation (needs `$area` exported)
- [x] `waterway_clipped` 4 rules incl. dotted tunnel variants
- [x] `wetland`

---

## G3 — Landscape, bridges & railway

Tables: `landscape_way`, `landscape_node`, `bridge`, `bridge_shade`, `railway_way`, `railway_node`.
Bridges and railway are part of the ×7 `layer` stack (G0.2).

| Layer | Geom | Detail |
| --- | --- | --- |
| `landscape_way` | Line | cliff / embankment / earth_bank: `#965220` 0.3–0.6 m + MarkerLine of equilateral triangles, interval 1.2/2.4 m, all length-dependent |
| `landscape_node` | Point | peak / rock / spring / stone; rock+stone are RasterMarker `symbols/rock/rock01.png` with `angle = rand(0,360)` |
| `bridge` | Polygon | flat `#dddddd`, no outline |
| `bridge_shade` | Polygon | `#dddddd` + dropShadow blur **5 m**, offset 0, opacity 0.33 — the widest blur in the project |
| `railway profile` | Line | two parallel rails `#808080` 0.24 m at ±0.7175 m; disused variant `#8ea08e` |
| `railway tie` | Line | HashLine interval 0.9 m, hash length 2.6 m, sub-line 0.3 m; `lineDistance` from `"gauge"` |

**Hard parts:** MarkerLine and HashLine become `symbol` layers with `symbol-placement: line` and
`symbol-spacing`; the hash marks need a tiny sprite or a second offset line layer.
`rand(0,360)` rotation is not reproducible in a style expression — precompute a rotation
attribute in the exporter (the `tree` table already does this via a `rotation` column).

**Known deviations:** rock/stone rotation comes from exported `((osm_id % 360) + 360) % 360`
(not QGIS `rand`). Peak uses a ▲ text stand-in (QGIS hospital SVG placeholder). Landscape
MarkerLine equilateral triangles → ▲ along-line symbols; length threshold 20 m drives width/
spacing via `length` export. Railway HashLine ties → wide `line-dasharray` (same compromise
as G4/G5). `tree_row` on `landscape_way` is not in the QGIS categorized renderer — omitted.

- [x] bridge + bridge_shade
- [x] railway profile + tie
- [x] landscape way/node

---

## G4 — Street surface

**The core group.** Tables: `highway_area`, `highway_service`, `highway`, `tactile_paving`.
All are part of the ×7 `layer` stack (G0.2).

### highway_area (13 rules)

Eight class rules paint a flat fill, five surface rules overlay a texture.

| Rule | Filter on | Fill |
| --- | --- | --- |
| footway | `area:highway IN ('footway','path','steps','bridleway')` | `#e1e3bd`, or `#ebedd6` when `footway`/`path` = `sidewalk` |
| pedestrian | `area:highway = 'pedestrian'` | `#d7d8c5` |
| cycleway | `area:highway = 'cycleway'` | `#cccccc` |
| service | `area:highway = 'service'` | `#cccccc`, or `#dcddd1` when `service = 'crossover'` |
| parking | `area:highway = 'parking'` | `#a8a8a7` |
| living_street | `area:highway = 'living_street'` | `#bbbbb2` |
| road | primary…unclassified, turning_circle, … | `#a8a8a7` |
| motorway | motorway/trunk + links | `#a8a8a7` |

| Surface rule | Texture | Width | Alpha | Angle |
| --- | --- | --- | --- | --- |
| `concrete`, `concrete:plates` | `surface/concrete.png` | 3 m | 0.35 | 0 |
| `paving_stones` | `surface/paving_stones.png` | 4.5 m | 0.10 | `"direction" + 45` |
| `sett` | `surface/sett.png` | 6 / 8.5 / 11 m by `sett:length` | 0.12 | `"direction"` |
| `asphalt` | `surface/asphalt.png` | 6 m | 0.06 | 0 |

### z14–z20 blur stack (7 layers)

This is the soft carriageway edge and it maps to MapLibre almost 1:1 — **each layer is visible at
exactly one zoom**, and only the blur radius changes:

| Layer | minScale | maxScale | innerShadow blur |
| --- | --- | --- | --- |
| z14 | 32000 | 16000 | 0.20 MM |
| z15 | 16000 | 8000 | 0.29 MM |
| z16 | 8000 | 4000 | 0.40 MM |
| z17 | 4000 | 2000 | 0.57 MM |
| z18 | 2000 | 1000 | 0.80 MM |
| z19 | 1000 | 500 | 1.13 MM |
| z20 | 500 | 1 | 1.60 MM |

All seven share the same fill (`#232323`) and the same offset (0 @ 40°); the shadow colour is
`#232323` at opacity 1. Because the radii are in **MM** (paper units) and each layer owns one
zoom, this collapses into a **single** MapLibre inner-glow line layer whose `line-blur` is a
`["interpolate", ["linear"], ["zoom"], 14, …, 20, …]` ramp over those seven values converted to
pixels at 96 DPI. That is the single highest-value simplification in the whole port.

### Remaining layers

| Layer | Detail |
| --- | --- |
| `service` | 2 rules — alley/`NULL` 4 m, driveway 3 m, both `#cccccc`, width from `"width"`; curved `name` labels 12 m, `#8c8c8c`. A `5;2` custom dash exists but `use_custom_dash=0`, so it renders solid |
| `path (way, fill)` | 8 rules — cycleway `#d2d1d2` 1 m; sidewalk/sidepath `#ebedd6` 1.8 m; footway `#e1e3bd` 1.8 m; segregated sidepath = two offset lines; steps + access_aisle are HashLines; informal at α 0.67. Cap style switches to flat on crossings |
| `path (way, casing)` | 5 rules — dashed `#d3d3d3` / `#979c90` 0.2 m at ±half-width, dash 0.6;0.6 m (footway) or 0.6;2.4 m (informal) |
| `tactile_paving` | `#d3d3d3` 1 m line at −0.5 m offset for kerbs + MarkerLine of red `cross2` markers, interval 1 m |

**Hard parts:** texture scale/rotation (G0.4); HashLine steps and access aisles; per-feature
dash arrays built with `array_foreach(string_to_array("dasharray", ';'), … * @mercator_scale)` —
MapLibre `line-dasharray` does **not** accept data-driven expressions, so distinct dash patterns
must be split into separate style layers filtered by `dasharray` value.

**Known deviations:** dash patterns quantised to a fixed set; texture rotation and ground-metre
texture scale dropped (`fill-pattern` uses sprite pixel size; `sett:length` / `direction`
exported for future use); segregated sidepath dual-offset omitted (no `segregated` column in
PostGIS); steps / access_aisle HashLines approximated with along-line `line-dasharray` (not
perpendicular ticks); tactile MarkerLine `cross2` markers omitted (offset kerb line only);
crossing flat caps left as round (`line-cap` is not data-driven); service `name` labels
deferred (no `name` on `highway_service`; glyphs optional).

- [x] G0.2 stacking decision documented
- [x] `highway_area` 8 class fills
- [x] `highway_area` 5 surface textures
- [x] z14–z20 collapsed into one blur ramp
- [x] `service`, `path` fill + casing
- [x] `tactile_paving`

---

## G5 — Road markings

Tables: `road_marking_polygon`, `road_marking_way`, `road_marking_node`, `separation`.
Part of the ×7 `layer` stack.

| Layer | Rules | Detail |
| --- | --- | --- |
| `road_marking_polygon` | 9 | restriction/barred_area with stripe, crosshatch, chessboard and none patterns; zebra stripes (solid `#ffffff`, colour from `"colour"`); surface colour (`#00c503` α 0.45, or `"colour"` verbatim). Two rules (zigzag, x) are deliberate no-render placeholders |
| `road_marking_way` | 5 | single line `#ffffff` width from `"width"` (default 0.12 m); zigzag variant (bevel join); double line = two lines at ±`"width"/1.25`; sharks_teeth = MarkerLine of triangles at 0.75 m; **zebra rule is disabled** (`checkstate=0`) |
| `road_marking_node` | 3 | all SvgMarker: turn arrows `traffic_signs/arrows/<arrow>.svg`, traffic signs `traffic_signs/<class>/<symbol>.svg`, symbols `traffic_signs/symbols/<bicycle\|footway\|wheelchair>.svg`; sized from `"length"`/`"width"`, rotated by `"direction"` |
| `separation` | 4 | bollard / flex_post / vertical_panel as MarkerLine at 2 m interval; bump as HashLine 2 m; markers 0.3–0.35 m with `#ededed` 0.1 m outline |

**Hard parts**

- **Pattern fills** (stripes at 0.75 m, crosshatch at 1.25 m in two directions, chessboard as two
  offset PointPatternFills at 2×2 m) all carry a data-defined angle `-"direction" + 90`.
  MapLibre `fill-pattern` cannot rotate or scale per feature. Best option: generate the stripe
  geometry in PostGIS (the pipeline already does this for zebra crossings via
  `helper/crossing_stripe_polygons.sql`) and draw real polygons instead of a pattern.
- **Data-driven dash arrays** — same constraint as G4; split into layers per distinct pattern.
- **Turn arrows** are the strongest case for `setMissingStyleImageResolver`: the icon id is
  built from `"arrow"`, and the width expression
  `"length" * 0.3 * max(1, min(2, 2 - "length"/5))` needs a per-feature `icon-size`.
- The `road_marking_polygon` `ELSE` rule paints `#b7484b` — a debug catch-all. Keep it during
  development as a "did I miss a case" signal, drop it before release.
- `road_marking_way` has an `osm_id` label at placement 2; that is debug output, do not port.

**Known deviations:** restriction `stripes` / `crosshatch` / `chessboard` use flat white fills
(opacity stand-in) rather than rotated LinePatternFill / PointPatternFill — MapLibre cannot
data-drive pattern angle or ground-metre spacing; PostGIS hatch geometry (like zebra stripes)
would be the faithful path. `line-dasharray` splits use metre pairs divided by the 0.12 m
reference width (wide markings get proportionally longer dashes). Double-line sides that
encode mixed `dashed;solid` strokes share one dasharray. `sharks_teeth` triangles are a ▼
text MarkerLine stand-in (not SVG triangles). Separation bollard / flex_post / vertical_panel
use ● text along the line (not SimpleMarker circles); bump HashLine is an along-line dash
(same compromise as G4 steps). Arrow icons are square (`length` for both axes); QGIS width
expression `length * 0.3 * clamp(…)` is dropped. Polygon ELSE `#b7484b` debug fill omitted.

- [x] `road_marking_way` incl. double lines and dash splitting
- [x] `road_marking_polygon` fills; decide pattern-vs-geometry
- [x] `road_marking_node` arrows/signs via runtime icons
- [x] `separation` four variants

---

## G6 — Street furniture & barriers

The widest surface in the project: 11 layers, ~90 rules/categories, most of the SVG usage.
Tables: `feature_node/way/polygon`, `barrier_node/way/polygon`, `playground_node/way/polygon`.
Part of the ×7 `layer` stack.

| Layer | Renderer | Scale |
| --- | --- | --- |
| `feature_node (middleground)` | RuleRenderer, **37 rules** | 16 SvgMarker, 2 FontMarker, 35 SimpleMarker |
| `feature_polygon (background)` | RuleRenderer, **18 rules** | dropShadow ×3 + innerShadow ×1 |
| `feature_polygon (middleground)` | RuleRenderer, 5 rules | dropShadow ×4, CentroidFill ×3 |
| `feature_way (middleground)` | categorized, 7 categories | plain lines |
| `feature_way (background)` | categorized, 1 category (`pier`) | dropShadow ×2 |
| `barrier_node` | categorized, 18 categories | 21 SimpleMarker; access-dependent fill colours |
| `barrier_way` | categorized, 17 categories | 22 SimpleLine, MarkerLine ×3, dropShadow on `fence` |
| `barrier_polygon` | categorized, 6 categories | flat fills |
| `playground_node / way / polygon` | single / categorized | `#d2c8a0` + `#b7916e`; climbingframe uses crossed LinePatternFills at 45°/135° |

**Icon inventory (drives the G0.5 decision).** 27 distinct path-building expressions expand to
~40 assets, e.g. `amenity/bench{,_backrest_no}.svg`, `amenity/post_box_{green,yellow}.svg`,
`amenity/{bicycle,bicycle_rental,cargo_bike}.svg`, `amenity/mobility_hub{,_Jelbi}.svg`,
`leisure/table_tennis{,_net_no,_net_yes}.svg`, `tourism/viewpoint{,_all_directions}.svg`,
`traffic_signs/DE/{222,222-10,605-10,605-11,605-20,605-21}.svg`,
`traffic_signs/street_name_sign.svg`, `amenity/loading_ramp.png`, `rock/rock01.png`.

Forty is small enough to sprite, but the expressions are open-ended (`"class"`/`"symbol"` from
the data), so the runtime resolver is still needed as the fallback. Verify
`amenity/small_electric_vehicle.svg` exists — one expression branch requests it.

**Hard parts:** two FontMarkers (`H` for fire hydrants, `~` for flagpoles) need either sprite
icons or a text symbol layer; CentroidFill becomes a separate `symbol` layer on the polygon
source; several markers combine 2–4 stacked symbol layers per rule.

**Known deviations:** compound multi-part markers simplified (street_lamp bent-mast / wall
directed stacks → single grey circle; gate MarkerLine stacks → one access-coloured circle;
flagpole `~` FontMarker omitted). CentroidFill icons use polygon centroid via `symbol` layers.
`feature_polygon` / pier dropShadow and fountain RasterFill omitted. Barrier-way MarkerLine
bollard/palisade use ● text (same compromise as G5 separation). Playground climbingframe
crossed LinePatternFills → flat orange fill. Sandpit stays in G1. Label rules
(capacity / ref / hydrant diameter) not ported. `entrance` / memorial / mast / viewpoint
POIs stay in G11 (not middleground). Icon pipeline: runtime
`setMissingStyleImageResolver` + Vite `/symbols/` (benches, bike, traffic panels, rocks, …);
closed textures remain in the build-time sprite.

- [x] icon pipeline proven end to end (sprite + resolver)
- [x] `feature_node (middleground)` 37 rules
- [x] `feature_polygon` background + middleground
- [x] `barrier_node` / `barrier_way` / `barrier_polygon`
- [x] `playground_*`

---

## G7 — Parked cars

**Blocked.** Single layer, and the only one not backed by PostGIS: it reads
`data/parking/street_parking_points_processed.geojson` via OGR (EPSG:4326), a directory that is
gitignored and currently empty.

SvgMarker `symbols/cars/<@modell>_<@colour>.svg` at 2.4 m, fill `#232323`, dropShadow
(blur 0.8 m, offset 0.5 m @ 40°, `#232323`, opacity 0.5). The rotation expression branches on
`orientation` (parallel / diagonal / perpendicular / random) and on
`highway:oneway` + `side`, and ends with a suspicious `- @mercator_scale` subtraction on an
**angle** — probably a bug in the QGIS project.

**Decide first:** is street parking part of the vector output at all? If yes, the exporter needs
a path for this GeoJSON (or the upstream process that generates it) before styling starts.

- [ ] decide in/out of scope
- [ ] if in: data path, then icons + rotation

---

## G8 — Symbol patterns

| Layer | Detail |
| --- | --- |
| `construction` | LinePatternFill 2.2 m @ 67°, sub-line `#ff5300` α 0.35 1 m, plus a `#ff5300` α 0.65 outline 0.4 m |
| `dog park` | PointPatternFill 10×10 m with 5/2.5 m displacement, SvgMarker `leisure/paw.svg` 3 m; visible only above ~z16.5 (`minScale` 6000) |

Both are pattern fills, so both hit the G0.4 constraint. Hatching at a fixed 67° is a good
candidate for a baked sprite pattern; the paw grid is a good candidate for
`fill-pattern` with a transparent tile.

- [ ] `construction` hatch
- [ ] `dog park` paw grid

---

## G9 — Trees

Two layers, table `tree`. High visual impact for very little work.

| Layer | Detail |
| --- | --- |
| `tree crown` | categorized on `natural`: **tree** → RasterMarker `symbols/trees/{broadleaved,needleleaved}.png`, size `if("diameter_crown", "diameter_crown", randf(5,9))` m, rotated by `"rotation"`, dropShadow blur 3 m / offset 0.4 m @ 45° / opacity 0.4. **shrub** → `broadleaved.png`, size `if("diameter_crown", …, randf(3,6))` m, dropShadow blur 1.5 m |
| `trunk` | `#8d8a63` circle, diameter `"circumference" / pi()` (fallback 0.5 m), layer opacity 0.75, dropShadow blur 2.5 m opacity 0.07; `ref` label at 7 pt |

**Approach:** the crown is a soft blob, so a MapLibre `circle` with `circle-blur` plus a
translated darker shadow circle gets very close without any image — this is the clearest
"replace graphics with base shapes" win in the project. Keep the leaf-type PNGs as an optional
overlay only if the circle version reads as too flat.

`randf(...)` is not reproducible in a style expression: the fallback crown diameter must be
materialised as a column by the exporter (`tree.rotation` already exists for the same reason).

**Known deviations:** leaf texture replaced by a flat blurred circle.

- [x] crown circle + blur + shadow
- [x] fallback diameter column in the exporter
- [x] trunk + `ref` label

---

## G10 — Buildings

Tables: `building_shade`, `building_parts_dissolved_height`, `building`, `building_lines`,
`housenumber`.

| Layer | Detail |
| --- | --- |
| `building_shade` | `#232323` fill, outline 0.26 **MM**; dropShadow blur 1.6 m, offset 0.4 m @ 40°, opacity 0.138 |
| `building_parts_dissolved_height` | `#ffe9e9` at symbol α 0.7, outline 0.015 m; dropShadow blur 2 m, offset 1 m @ 40°, opacity 0.4; **rendered ordered by `height` ascending** |
| `roof shape` | 5 rules on `roof:shape`: flat = solid `#990003`; round = radial GradientFill; gabled = two linear GradientFills; default/other = ShapeburstFill 5 MM |
| `building_lines` | categorized on `class`: `footline_covered` (`#cacaca` 0.2 m + dashed `#808080` 0.1 m, dash 0.45;0.45 m), `footline_uncovered` 0.05 m, `part_outline` 0.02 m, `roof_edge` / `roof_ridge` 0.04 m — all `#808080` |
| `housenumber` | label only: `addr:housenumber`, DejaVu Sans 7.5 pt `#b7b7b7`, buffer 2.5 pt `#d8d5d5` α 0.75, visible above ~1:1000 |

**Hard parts**

- `roof shape` is the least portable layer in the project: radial and linear gradients plus a
  distance-field fill, with a 51-stop magma-like colour ramp and a `#990003` base. The colours
  suggest this is an unfinished experiment rather than shipped cartography — **check the raster
  output before investing**; a flat fill may be the correct port.
- `enableorderby` on `building_parts_dissolved_height` maps to `sort-key` on `["get","height"]`.

**Decision — `roof shape`:** **skipped.** Magma gradients on `#990003` read as an unfinished
QGIS experiment, not shipped cartography; building mass stays the pink `building_parts` /
`building` fills. No `roof:shape` column exported.

**Known deviations:** roof shape not ported (see decision above); housenumber uses Open Sans
at ~10 px from tippecanoe z17 overzoom (style `minzoom` 18 ≈ QGIS 1:1000).

- [x] `building_shade` + `building_parts_dissolved_height` with shadows
- [x] `building_lines` five classes
- [x] `roof shape` — skipped (experimental; documented)
- [x] `housenumber` labels

---

## G11 — Foreground POI

| Layer | Detail |
| --- | --- |
| `feature_node (foreground) Kopie` | 8 rules: guard_stone, information, mast, memorial, public_bookcase, stolperstein, toilets, viewpoint; SvgMarkers 1.2–3 m. The layer name suggests it is a duplicate ("Kopie") — confirm it is intentional |
| `entrance` | 4 rules; subway / s-train SvgMarkers at 2–2.2 m with ±1.2 m offsets, generic entrance a 0.6 m circle; visible above ~z17.5 (`minScale` 3000) |

- [ ] confirm the "Kopie" layer is wanted
- [ ] both layers

---

## G12 — Labels

Six label-only layers (`nullSymbol` renderer — geometry hidden). Tables: `label_highway`,
`label_waterway`, `landuse`, `water_body`, `place_node`, `place_polygon`.
Needs a glyph endpoint configured before any of it renders.

| Layer | Placement | Font / colour | Zoom window |
| --- | --- | --- | --- |
| `label_highway` | curved (3), dist 0.75 m, curve angle ±25° | DejaVu Sans Condensed 10 pt `#dddddd`, buffer 2 pt `#a8a8a7` α 0.75 | `zoom='high'` 1:1000–4000, `zoom='low'` 1:4000–8000 |
| `label_waterway` | curved (3) | 10 pt `#cdcbea`, buffer `#aba5d8` | 1:2000–16000 |
| `label landuse` | around point (0), centroid-whole, fit-in-polygon | 10 pt `#a8a8a7`, buffer `#e1e3bd` | primary 1:2000–64000; secondary 1:2000–4000 at α 0.67 |
| `label water body` | around point (0) | 10 pt `#aba5d8`, buffer `#cdcbea` | 1:2000–60000 |
| `place_node` / `place_polygon` | over point (1) | 10 pt `#d7d8c5`, buffer `#a8a8a7` | five rules by place rank, 1:1000 → 1:128000 |

**Straightforward:** curved line labels are `symbol-placement: line`; the scale windows convert
to `minzoom`/`maxzoom` via `z ≈ log2(559082264 / scale)`; buffers are `text-halo-*`.

**Hard parts:** `label_highway` opacity drops via a `CASE` on `@map_scale` — becomes a zoom
`interpolate` on `text-opacity`. `label landuse` hides labels when the polygon is small relative
to the map scale (`$area / @map_scale < 25`) — precompute area and approximate with a zoom-
dependent filter. The Straßenraumkarte pipeline already produces dedicated label geometry
(`label_highway`, `label_waterway`), so anchoring is easier here than in a generic style.

**Known deviations:** font DejaVu Sans Condensed → Open Sans Regular + Arial Unicode MS
(demotiles glyph endpoint — confirmed serving those stacks). Landuse / water / place polygon
labels use point placement at the polygon centroid (`fit-in-polygon` not available). Landuse
small-area hide uses exported `area` + zoom expression (approximation of `$area / @map_scale`).
Place ranks for town/city (QGIS z12–14) are styled but sit below the PMTiles archive minzoom
(z15), so they do not paint until the archive is lowered. Starter extract may have few/no
`place_polygon` / named `water_body` / `label_waterway` features.

- [x] glyph endpoint (demotiles Open Sans / Arial Unicode MS; documented in `source.ts`)
- [x] street + waterway curved labels (`zoom` high/low windows + waterway colour swap)
- [x] landuse + water area labels (`name`/`area` on landuse; `label_water_body` export)
- [x] place labels (5 rank rules on `place_node` + `place_polygon`)

---

## Not porting

| Item | Reason |
| --- | --- |
| `water_body (simple backup)` | unchecked in the QGIS layer tree |
| `road_marking_way` → zebra rule | `checkstate=0`, disabled in QGIS |
| `road_marking_polygon` → zigzag, x | explicit "not rendered" placeholder rules |
| `road_marking_way` `osm_id` labels | debug output |
| `road_marking_polygon` `ELSE` → `#b7484b` | debug catch-all; keep during development only |

## Open questions

1. **G0.2** — one style layer per OSM `layer` bucket, or a single layer with `sort-key`?
2. ~~**G10** — is `roof shape` (magma gradients on `#990003`) shipped cartography or an experiment?~~ **Resolved:** experiment → skip (see G10 decision).
3. **G7** — is street parking in scope for the vector output at all?
4. **G1** — is `landuse` → `outdoor_seating` (`#0000ff` base fill) a debugging leftover?
5. **G11** — is `feature_node (foreground) Kopie` intentional or a stray duplicate?
6. **G0.4** — bake pre-scaled/rotated texture variants, or accept fixed-pixel patterns?
