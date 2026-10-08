# MapLibre style gaps — what the QGIS cartography needs that MapLibre lacks

What `style/strassenraumkarte.qgz` actually uses, what MapLibre GL JS 6 cannot express, how the
vector port (`vector/src/style`) works around it today, and which gaps we close with local
renderer patches ([maplibre-patches.md](./maplibre-patches.md)). Before/after screenshots for
each step live in [maplibre-progress/](./maplibre-progress/README.md).

Companion docs: [maplibre-style-groups.md](./maplibre-style-groups.md) (layer-by-layer port
notes), `vector/README.md` (pipeline).

Verified 2026-10-08 against the project XML (QGIS 3.34.4) and upstream issue trackers. This
replaces an older analysis that was written against a different copy of the style and had
several wrong claims (gradients "not used", wrong counts, a mislabelled issue).

## How the numbers are counted

The project has 256 map layers but only 64 unique names: `update_highway_layered.py` clones 32
highway-stack layers seven times (six OSM `layer` buckets plus a hidden template). **Raw** counts
the whole XML, **unique** counts each layer name once. Only enabled symbol layers and effects
are counted.

## Priority list

Ranked by visual impact on the map. "Patch" says whether closing the gap needs a renderer
change or can be done in style/sprite/ETL.

| # | Gap | QGIS usage (raw / unique) | Today in `vector/` | Loss | Fix route |
|---|---|---|---|---|---|
| 1 | **Drop shadow** (offset + Gaussian blur, multiplied) | 77 / 23 — `feature_polygon` 49, `bridge_shade`, `feature_way`, `landuse` 7 each, tree crown, `building_shade`, `building_parts`, scrub, trunk | `layerShadow` (blurred, multiplied layer) for buildings; old `dropShadow` helper (translated fill + blurred line) for forest and bridges; none for `feature_polygon` | High → **buildings done** (step 02); `feature_polygon`, trees, forest, bridges still on the old helper | **Patched**: `fill-layer-blur` + multiply |
| 2 | **Multiply / Screen blend** | Layer blend Multiply on `landuse surface`, `pitch surface`; Multiply inside the effect stack of `highway_area` textures (35 / 5); Screen on `roof shape`; every shadow composites with Multiply | ~~plain alpha-over~~ → **done**, `fill-layer-blend` patch | Medium | **Patched** (step 01) |
| 3 | **Texture rotation and ground-metre scale** (RasterFill `angle`, `width` in map units) | 133 / 96 RasterFill; 7 unique data-defined angles, 38 data-defined widths | Sprite baked at the z18 ground width, rotation dropped | Medium — sett/paving ignore street direction; scale is wrong off z18 | Style: per-zoom sprite variants. Rotation needs a **patch** (`fill-pattern-rotate`) |
| 4 | **Parametric pattern fills** (LinePatternFill / PointPatternFill, rotated per feature) | 44 / 8 and 15 / 3 — `road_marking_polygon`, construction, playground, dog park | Baked hatch sprites; road-marking hatching is flat white | Medium–high on restriction markings | ETL (generate hatch lines) or SDF pattern + rotation patch |
| 5 | **HashLine** (perpendicular ticks) | 42 / 6 — steps, railway ties, road markings, separation | `line-dasharray` along the line | Medium | Style: `line-pattern` sprite, or ETL ticks |
| 6 | **MarkerLine** (markers at a ground-metre interval, offset) | 59 / 11 — `barrier_way`, `landscape_way`, `road_marking_way`, separation, tactile paving | `symbol-placement: line` + `symbol-spacing`; several markers are glyph stand-ins that do not render | Medium | Style: sprite icons / round-cap dashes; ETL points for exact spacing |
| 7 | **Inner shadow / glows** | innerShadow 60 / 11 (49 are the `z14…z20` carriageway blur layers), outerGlow 7, innerGlow 1 | innerShadow: **done**, `fill-layer-blur-mode: inner-edge` (step 03). Glows still offset blurred lines | Low | **Patched** for inner shadows; glows can move to the same mode |
| 8 | **Shapeburst / gradient fills** | ShapeburstFill 4 (water shoreline 3 m, water depth, roof shape ×2), GradientFill 3 (roof shape) | Three inward blurred bands for the shoreline; depth ramp and roof shape omitted | Low for water; roof shading absent | **Patch** (distance-to-edge) or bake in ETL |

### Solved well enough by workarounds

| QGIS feature | Usage | Workaround | Loss |
|---|---|---|---|
| Ground-metre sizing (`@mercator_scale`, 2705×) | everywhere | `metresToPixels`: exact base-2 zoom interpolation at φ = 52.48° | None for Berlin |
| SvgMarker (185 / 35) and RasterMarker (25 / 7) | icons, pitch markings, tree crowns, rocks | Sprite atlas + runtime image resolver, `icon-rotate` | Low once the asset handling is fixed (aspect ratio, `param(fill)`, resolution) |
| Fill outline width (40 data-defined) | SimpleFill | Separate `line` layer | None visually; more layers |
| Line casing | stacked SimpleLine | Two `line` layers | None visually |
| Per-feature line offset (26 data-defined) | SimpleLine | `line-offset` (data-driven) | None |
| CentroidFill (42 / 6) | `feature_polygon` | `symbol` layer on the polygon | Low |
| FontMarker (14 / 2) | flagpole, stolperstein | Circle stand-in | Negligible |
| Layer opacity ≠ 1 (~100 raw) | markings 0.67, tree crown 0.25, … | `fill-layer-opacity` / `line-layer-opacity` (MapLibre ≥ 6) or per-feature opacity | Low. Symbol layers: **patched**, `symbol-layer-opacity` (step 04) |
| Label buffer, curved labels | all labels | `text-halo-*`, `symbol-placement: line` | Low (DejaVu → Open Sans) |

### Found while porting (not in the original list)

| Gap | Effect | Status |
|---|---|---|
| Sub-pixel lines are drawn ~3× too strong | Building-part edges, roof lines and path casings look crisp and pixelated | **Patched** (step 08): ink fitted to QGIS, `w·(2 − w)` |
| Symbol layers have no layer opacity | Overlapping tree crowns stack up dark | **Patched** (step 04): `symbol-layer-opacity` |
| Dash phase restarts at tile edges | A dash can be cut or doubled where tiles meet | Open; not noticeable at the compare locations |
| A per-feature effect cannot interleave with its own layer | Roof-on-roof shadows between building parts are missing | Open; trees solved by baking the shadow into the sprite |

### Not used in the project

GeometryGenerator (0), blur effect (0), label shadows and backgrounds (0), label callouts
(configured, disabled), feature blend modes (0). The "map fog" of the old analysis does not exist
in the project XML.

## Upstream status

Checked with `gh` on 2026-10-08.

| Gap | Upstream | State |
|---|---|---|
| Blend modes | [maplibre-gl-js#48](https://github.com/maplibre/maplibre-gl-js/issues/48), [style-spec#1661](https://github.com/maplibre/maplibre-style-spec/issues/1661); implementation in [style-spec PR #1798](https://github.com/maplibre/maplibre-style-spec/pull/1798) and [gl-js PR #8073](https://github.com/maplibre/maplibre-gl-js/pull/8073) (draft) | Open — our patch uses the same property names, so the style carries over when it lands |
| Drop shadow / blur for 2D layers | [gl-js#1326](https://github.com/maplibre/maplibre-gl-js/issues/1326) (symbols/circles only, stale). 3D only: [style-spec#1797](https://github.com/maplibre/maplibre-style-spec/issues/1797), [PR #1870](https://github.com/maplibre/maplibre-style-spec/pull/1870) | Nothing for fills and lines |
| Gradient fill | [gl-js#5005](https://github.com/maplibre/maplibre-gl-js/issues/5005) | Open, stale |
| Pattern rotation / pattern size in metres | none found | — |
| SDF / tintable patterns | [gl-js PR #8239](https://github.com/maplibre/maplibre-gl-js/pull/8239) merged, [style-spec#1642](https://github.com/maplibre/maplibre-style-spec/issues/1642) `fill-pattern-color` | Partly landed; not checked whether it is in 6.0.0 |
| Marker lines | [style-spec#789](https://github.com/maplibre/maplibre-style-spec/issues/789) `symbol-line-anchor`, [style-spec#1898](https://github.com/maplibre/maplibre-style-spec/issues/1898) `text-repeat-distance` | Open |
| Fill outline width | [gl-js#4167](https://github.com/maplibre/maplibre-gl-js/issues/4167) | Open |
| Line casing | [style-spec#1554](https://github.com/maplibre/maplibre-style-spec/issues/1554) | Open |
| Variable line offset | [style-spec#1498](https://github.com/maplibre/maplibre-style-spec/issues/1498) | Open |
| SVG / colour-font icons | [style-spec#1615](https://github.com/maplibre/maplibre-style-spec/issues/1615), [#1605](https://github.com/maplibre/maplibre-style-spec/issues/1605) | Open |

## Port bugs that are not MapLibre gaps

Found in the 2026-10-08 code review; they hurt fidelity as much as the gaps above and need no
patch. Tracked here until fixed.

- [ ] OSM `layer` buckets are not interleaved: all street buckets are emitted before all
      marking/furniture buckets, so ground-level markings paint over bridges (`qgis.ts`).
- [ ] Glyph stand-ins (▲ ▼ ▶ ●) render nothing — the glyph PBFs do not contain them. Affects
      cliffs, peaks, sharks teeth, bollard rows, guard stones.
- [x] Runtime icons are squeezed into 64×64 squares and SVG `param(fill)` is not substituted
      (arrows render black and ~3× too wide).
- [x] Tree crowns are flat blurred circles; QGIS uses the `symbols/trees/*.png` raster markers.
- [ ] Texture scale is baked for z18 only. (`@2x` textures are now resampled from the source.)
- [ ] Effect helpers (glows only — shadows are patched): blurred lines peak at half the stated opacity and inner effects peak
      inside the polygon instead of at its edge.
- [x] Dash lengths scale with the data-driven line width (`detail.ts`).
- [x] QGIS scale gates were converted to zoom without the 512 px tile offset (one zoom late).
- [ ] Dash phase restarts at tile edges (MapLibre limitation, see progress step 05).
- [x] `/symbols/*` is only served by the dev server, not by `vite preview` or a build.
- [ ] Unused sprites (`forest`, `gravel`, `flowerbed`). (`water` is used now.)
