# QGIS rendering internals — implementation spec

Notes for a Rust renderer that must match QGIS output from `style/strassenraumkarte.qgz` within a few pixels. Each subsection lists **inputs → unit conversion → geometry/paint path → gotchas**. Citations point at QGIS `master` source files.

---

## 1. Render pipeline

### 1.1 Job family overview

| Class | Role |
| --- | --- |
| `QgsMapSettings` | Extent, DPI, layers, flags, `mapToPixel()`, labeling settings |
| `QgsMapRendererJob` | Shared `prepareJobs()`, `composeImage()`, labeling pass, second-pass masks |
| `QgsMapRendererParallelJob` | Renders layers concurrently via `QtConcurrent::map`, then labels, then optional second pass |
| `QgsMapRendererSequentialJob` | Same stages, single-threaded |
| `QgsMapRendererCustomPainterJob` | Renders into a caller-supplied `QPainter` (shared canvas) |

**Metatile path in this repo:** `render/xyz_tiles.py` builds `QgsMapSettings`, uses `QgsMapRendererCustomPainterJob` (or equivalent) on a `QImage` sized to core tiles + gutter.

### 1.2 Layer preparation (`prepareJobs`)

Source: [`src/core/maprenderer/qgsmaprendererjob.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/maprenderer/qgsmaprendererjob.cpp) — `QgsMapRendererJob::prepareJobs` (~L541).

1. Iterate layers **bottom → top** (`QListIterator::toBack()` then `previous()`).
2. Skip invalid, out-of-scale, temporal, or Z-out-of-range layers.
3. Reproject visible extent (+ `extentBuffer()`) to layer CRS; set on per-layer `QgsRenderContext`.
4. Create `QgsMapLayerRenderer` via `ml->createMapRenderer()`.
5. **Per-layer offscreen image** when any of:
   - map cache is active (`canUseCache`), OR
   - no shared `QPainter` passed (`!painter && !deferredPainterSet`) — **always true for parallel job**, OR
   - `job.renderer->forceRasterRender()` is set.

   Allocated by `allocateImageAndPainter()` → transparent `QImage` + `QPainter` with `setPainterFlagsUsingContext()`.

6. Store `job.blendMode = ml->blendMode()`, `job.opacity = ml->opacity()` (raster layers may force opacity 1.0 if renderer handles opacity internally).

**Gotcha:** Comment at L708 says "alternative blending mode" but the condition is broader — parallel rendering **always** flattens each layer to its own image before compositing, not only when blend mode ≠ `SourceOver`.

### 1.3 Final compositing (`composeImage`)

Source: `QgsMapRendererJob::composeImage` (~L1339).

1. Create output `QImage` at `deviceOutputSize()`, fill `backgroundColor()`.
2. For each layer job (skipping `renderAboveLabels`):
   - `painter.setCompositionMode(job.blendMode)`
   - `painter.setOpacity(job.opacity)`
   - `painter.drawImage(0, 0, layerImage)`
3. Optional elevation shading composite.
4. Draw label image (`labelJob.img`) if `labelJob.complete`.
5. Draw layers with `renderAboveLabels` custom property.

**Order:** bottom layers first, labels in the middle, "above labels" layers last.

### 1.4 Parallel job stages

Source: [`src/core/maprenderer/qgsmaprendererparalleljob.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/maprenderer/qgsmaprendererparalleljob.cpp).

1. **RenderingLayers** — `QtConcurrent::map(mLayerJobs, renderLayerStatic)`; each job calls `job.renderer->render()`.
2. **RenderingLabels** — `drawLabeling()` on composed base (or direct painter).
3. **RenderingSecondPass** — mask-based re-render for masked symbol layers (uncommon in this style).

### 1.5 `QgsRenderContext` scale factors

Source: [`src/core/qgsrendercontext.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsrendercontext.cpp).

| Field / method | Definition |
| --- | --- |
| `scaleFactor()` | Set in `fromMapSettings()`: `outputDpi / 25.4` → **pixels per millimetre** (L407) |
| `rendererScale()` | Map scale denominator from settings (L409) |
| `mapToPixel()` | Affine map CRS → device pixels |
| `symbologyReferenceScale` | Reference scale for size clamping (used in unit conversion) |
| `convertToPainterUnits()` | Canonical unit → device pixels (L547–652) |
| `convertMetersToMapUnits()` | Ground metres → map units via `QgsDistanceArea` (L824+); for EPSG:3857 tiles this is the path for `MetersInMapUnits` |

#### `convertToPainterUnits(size, unit, QgsMapUnitScale, property)` (L547)

| `Qgis::RenderUnit` | `conversionFactor` applied to `size` |
| --- | --- |
| `Millimeters` | `mScaleFactor` |
| `Points` | `mScaleFactor / 2.83464567` |
| `Inches` | `mScaleFactor * 25.4` |
| `MetersInMapUnits` | `size = convertMetersToMapUnits(size)` then fall through to `MapUnits` |
| `MapUnits` | `1.0 / scale.computeMapUnitsPerPixel(*this)` (invalid `mapToPixel` → hack as points, clamp 10–100 px) |
| `Pixels` | `1.0` |

After conversion for `MapUnits`:
- Clamp: `max(converted, minSizeMM * mScaleFactor)` if `minSizeMMEnabled`
- Clamp: `min(converted, maxSizeMM * mScaleFactor)` if `maxSizeMMEnabled`
- Multiply by `symbologyReferenceScale / rendererScale` when reference scale > 0

Preview flags clamp blur/shadow/glow subcomponents (L629–649).

#### `QgsMapUnitScale::computeMapUnitsPerPixel` ([`src/core/qgsmapunitscale.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsmapunitscale.cpp) L15)

```cpp
mup = mapToPixel().mapUnitsPerPixel();
if (minScale) mup = min(mup / (renderScale / minScale), mup);
if (maxScale) mup = max(mup / (renderScale / maxScale), mup);
```

### 1.6 Anti-aliasing and painter hints

`QgsRenderContext::setPainterFlagsUsingContext()` (L312–322) sets on each new `QPainter`:

| `Qgis::RenderContextFlag` | `QPainter::RenderHint` |
| --- | --- |
| `Antialiasing` | `QPainter::Antialiasing` |
| `LosslessImageRendering` | `QPainter::LosslessImageRendering` |
| `HighQualityImageTransforms` | `QPainter::SmoothPixmapTransform` |

Default constructor flags (L36): `DrawEditingInfo | UseAdvancedEffects | DrawSelection | UseRenderingOptimization`.

`fromMapSettings()` copies matching `Qgis::MapSettingsFlag` values (L385–403), including `Antialiasing`, `RenderMapTile`, `RenderBlocking`, `LosslessImageRendering`, `HighQualityImageTransforms`.

Symbol layers may **disable** antialiasing for simplified/generalised geometry (e.g. SimpleLine L479–488, `_renderPolygon` L990–999).

### 1.7 Render context flags that affect output

| Flag | Effect relevant to tile rendering |
| --- | --- |
| `RenderMapTile` | Disables feature clipping when symbol `canCauseArtifactsBetweenAdjacentTiles()` ( [`qgssymbol.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbol.cpp) L1603–1611) |
| `UseAdvancedEffects` | When off → `RasterizedRenderingPolicy::ForceVector`; effects skipped |
| `RenderBlocking` | Passed to SVG/image caches (synchronous load) |
| `ForceVectorOutput` | Effects that need rasterization draw unmodified source |
| `RenderSymbolPreview` / `RenderLayerTree` | Clamps metre sizes, blur, shadow for legend icons |

---

## 2. Symbol layer painting semantics

### 2.1 `QgsSimpleLineSymbolLayer`

Source: [`src/core/symbology/qgslinesymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgslinesymbollayer.cpp) (class starts ~L1; key methods below).

#### Inputs / XML keys (`properties()` ~L535)

`line_color`, `line_width`, `line_width_unit`, `width_map_unit_scale`, `line_style`, `joinstyle`, `capstyle`, `offset`, `offset_unit`, `customdash`, `customdash_unit`, `use_custom_dash`, `dash_pattern_offset`, `align_dash_pattern`, `tweak_dash_pattern_on_corners`, `draw_inside_polygon`, `ring_filter`, trim distances.

#### Pen construction (`startRender` L247–291)

- Width: `convertToPainterUnits(mWidth, mWidthUnit, mWidthMapUnitScale)`
- Custom dash: each dash value converted to painter units, **divided by** `max(1.0, scaledWidth)` → QPen dash lengths are in **multiples of pen width**
- Dash offset: `convertToPainterUnits(mDashPatternOffset, ...) / dashWidthDiv`
- Cap/join from `mPenCapStyle`, `mPenJoinStyle`

#### `renderPolyline` (L439–533)

- Optional trim via `QgsSymbolLayerUtils::polylineSubstring`
- Zero offset: `QPainterPath` + `drawPath` (not `drawPolyline` — joint quality)
- Non-zero offset: `offsetLine()` → GEOS `offsetCurve` / negative `buffer` for polygons ( [`qgssymbollayerutils.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbollayerutils.cpp) L1260–1328), `quadSegments=0`, `miterLimit=2.0`
- If `alignDashPattern` && non-solid && `dashOffset==0`: `drawPathWithDashPatternTweaks()` — recomputes dash pattern per segment/corner (L490+, L900+)

#### Polygon stroke (`renderPolygonStroke` L298)

- `drawInsidePolygon`: clip to polygon interior (`QPainterPath` + `Qt::IntersectClip`)
- `ringFilter`: exterior only / interior only; interior rings get **negated offset** (L360–370)

**Gotchas (pixel diffs):**
- Dash values are **pen-width-normalised**, not absolute pixels
- `alignDashPattern` / `tweakDashPatternOnCorners` change dash starts at vertices — large diffs vs naive `line-dasharray`
- GEOS offset failure returns **original** polyline (L1326)
- 2-point simplified lines drop antialiasing

---

### 2.2 `QgsSimpleFillSymbolLayer`

Source: [`src/core/symbology/qgsfillsymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsfillsymbollayer.cpp).

#### `renderPolygon` (L299–361)

- Fill/stroke colours × `context.opacity()`
- Offset: 2D `convertToPainterUnits` then `painter.translate`
- Non-solid brush + vector export: **two-pass** fill then stroke (L337–355) — opacity bug workaround for PDF
- Delegates to `_renderPolygon`

#### `_renderPolygon` ([`src/core/symbology/qgssymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbollayer.cpp) L983–1025)

- No holes + no pen: `drawPolygon(points)`
- With holes or stroke: `QPainterPath` — `addPolygon(exterior)` then each ring; `drawPath(path)`
- **Fill rule:** not explicitly set → Qt default `Qt::OddEvenFill` on `QPainterPath`
- Does **not** use `Qt::WindingFill`

**Gotchas:** ring orientation matters under OddEvenFill; clipped polygon outlines use `drawPath` not `drawPolygon` (comment L1002 — #13343)

---

### 2.3 `QgsSimpleMarkerSymbolLayer`

Source: [`src/core/symbology/qgsmarkersymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsmarkersymbollayer.cpp).

#### Size semantics

- `mSize` is **diameter of bounding box** (square envelope), not radius
- `calculateSize()` (L855): data-defined size; `ScaleMethod::ScaleArea` → `sqrt(size)`
- Device size: `convertToPainterUnits(mSize, mSizeUnit, mSizeMapUnitScale)`
- `prepareMarkerShape` / `prepareMarkerPath`: unit shapes scaled by `half = scaledSize/2` (L190–191)

#### Cached path (`mUsingCache`, L1088–1117)

Enabled when: no data-defined size/rotation/shape/colours/stroke AND not `forceVectorRendering()`.

`prepareCache()` (L1125):
- Renders marker centred in odd-sized `QImage` at `devicePixelRatio`
- `drawImage` at `point - size/2 + offset` (L1326)
- MAXIMUM_CACHE_WIDTH guard → falls back to direct paint

#### Direct paint (`renderPoint` L213+)

- Rotation origin: marker centre; offset rotated with angle (`_rotatedOffset`)
- Point features with data-defined rotation add `mapRotation()` (L920–922)

**Gotchas:** cache vs direct path can differ subpixel; metre sizes in preview clamp to 3–100 mm

---

### 2.4 `QgsSvgMarkerSymbolLayer`

Source: `qgssmarkersymbollayer.cpp` L2342+.

#### Render path

1. `width = convertToPainterUnits(scaledWidth, mSizeUnit, ...)`
2. Skip if `width < 1` or `> 10000` px
3. Dynamic params: `QgsSymbolLayerUtils::evaluatePropertiesMap(mParameters, expressionContext)`
4. **Raster path** (default when not rotated): `QgsSvgCache::svgAsImage(path, width * devicePixelRatio, fill, stroke, strokeWidth, scaleFactor, ...)` → `drawImage` centred
5. **Vector path**: `svgAsPicture` when rotated or cache miss

#### Parameter substitution ([`src/core/symbology/qgssvgcache.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssvgcache.cpp) `replaceElemParams` L598)

| SVG token | Replaced with |
| --- | --- |
| `param(fill)` | fill colour `.name()` |
| `param(fill-opacity)` | fill alpha |
| `param(outline)` | stroke colour |
| `param(outline-width)` | `strokeWidth * sizeScaleFactor` |
| `param(outline-opacity)` | stroke alpha |
| `param(custom)` | expression-driven map entries |

Cache key includes path, size, colours, stroke width, aspect ratio, parameters.

**Gotchas:** rasterized at `width * devicePixelRatio`; re-rasterize when selection colour needed; aspect from `svgViewboxSize` when path is data-defined

---

### 2.5 `QgsRasterFillSymbolLayer` / `QgsImageFillSymbolLayer`

Source: `qgsfillsymbollayer.cpp` L1784+ (base), L5154+ (raster).

#### Pattern setup (`applyPattern` L5473)

- Width/height → `convertToPainterUnits` (or % of original image pixels)
- `QgsApplication::imageCache()->pathAsImage(..., QSize(round(w), round(h)), alpha)` → `brush.setTextureImage(img)`

#### Coordinate reference

| Mode | Behaviour |
| --- | --- |
| `SymbolCoordinateReference::Viewport` (default) | Pattern origin fixed in device/map space — **viewport-anchored** |
| `Feature` | `RasterFillSymbolLayer::renderPolygon` translates brush to `points.boundingRect().topLeft()` (L5314–5318) |

`applyBrushTransformFromContext`: returns true only for **Feature** mode; then `textureOrigin` from symbol render sets brush translate ([`qgssymbol.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbol.cpp) L1584–1586 sets texture origin from geometry bounds).

**Gotchas for tiles:**
- Viewport mode: patterns are **not** feature-anchored — adjacent tiles align if map origin is consistent
- Feature mode: pattern shifts per polygon — **tile seams** unless geometry spans gutter
- This style uses ground-metre widths (e.g. 30 m, 35 m) → `MetersInMapUnits` / `MapUnits`

---

### 2.6 `QgsShapeburstFillSymbolLayer`

Source: `qgsfillsymbollayer.cpp` L1117+.

Per-feature algorithm (`renderPolygon` L1309):

1. Rasterise polygon mask to local `QImage` with `sideBuffer = 4 + (blurRadius+2)*4`
2. White fill on black → `distanceTransform()` — Felzenszwalb 1D DT ×2 ([`distanceTransform1d/2d`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsfillsymbollayer.cpp) L1514+, adapted from http://cs.brown.edu/~pff/dt/)
3. `dtArrayToQImage` maps distance through colour ramp
4. Optional `QgsImageOperation::stackBlur`
5. Alpha composite via `CompositionMode_DestinationIn` with polygon mask
6. `drawImage` at feature position

**Gotchas:** per-feature local image — tile boundary artefacts possible; `canCauseArtifactsBetweenAdjacentTiles()` returns true

---

### 2.7 Other symbol layers (brief)

| Layer | Placement / notes |
| --- | --- |
| `QgsMarkerLineSymbolLayer` | Interval in map units along line; `QgsSymbolLayerUtils::pointsOnLine` |
| `QgsHashedLineSymbolLayer` | Hash marks at interval, offset from centreline |
| `QgsArrowSymbolLayer` | Arrow head geometry at line end / middle |
| `QgsFontMarkerSymbolLayer` | `QFont` + `QgsTextRenderer` metrics; size via `convertToPainterUnits` |
| `QgsPointPatternFillSymbolLayer` | Grid of markers in polygon bounds |
| `QgsLinePatternFillSymbolLayer` | Rotated line pattern fill |

Not heavily used in `strassenraumkarte.qgz`; read `qgslinesymbollayer.cpp` / `qgsfillsymbollayer.cpp` if needed.

---

### 2.8 Symbol levels (multi-pass rendering)

Source: [`src/core/vector/qgsvectorlayerrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/vector/qgsvectorlayerrenderer.cpp) `drawRendererLevels` (L498, L836+).

When `renderer->usingSymbolLevels()`:

1. **First pass:** iterate all features, bucket by `(QgsSymbol*, symbolLayerIndex)` using `symbolLayer->renderingPass()` as level index (0–999)
2. **Second pass:** for each level ascending, render only that symbol layer for all features in bucket

**Effect:** symbol layer 2 of feature A draws **after** symbol layer 1 of feature B across the whole layer — not per-feature layer order.

**Gotcha:** essential for road casings / overlays; naive per-feature paint order will mismatch QGIS.

Per-layer paint effects: `renderer->paintEffect()->begin/end` wraps entire level pass (L312–317, L508–510).

Per-symbol-layer effects: `QgsEffectPainter` in `QgsSymbol::renderFeature` ([`qgssymbol.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbol.cpp) L1158–1173).

---

## 3. Paint effects

Architecture: [`src/core/effects/qgspainteffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgspainteffect.cpp).

- `QgsEffectPainter` saves painter, redirects to `QPicture` via `begin()`, restores and calls `render(picture)` in `end()`
- `sourceAsImage()`: rasterize picture to `QImage` padded by `boundingRect()` with AA (L89–107)
- Effects with `RequiresRasterization` flag skip when `ForceVector`

### 3.1 `QgsDrawSourceEffect`

Applies opacity + blend mode to rasterized source ([`qgspainteffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgspainteffect.cpp) L120+).

### 3.2 `QgsBlurEffect`

[`src/core/effects/qgsblureffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsblureffect.cpp)

- `blur_level` + `blur_unit` → `convertToPainterUnits(..., BlurSize)`
- Methods: `StackBlur` (default) or `GaussianBlur`
- `stackBlur` from Qt's pixmap filter ([`src/core/effects/qgsimageoperation.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsimageoperation.cpp) L585 — 4-pass box blur)
- `boundingRect`: `spread = blurLevel * 2 + 10` px

### 3.3 `QgsDropShadowEffect` / `QgsInnerShadowEffect`

[`src/core/effects/qgsshadoweffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsshadoweffect.cpp)

1. Rasterize source
2. Inner: `invertPixels(Rgba)` first
3. `overlayColor(image, mColor)`
4. Blur: `stackBlur` if `blurLevel <= 16`, else `gaussianBlur`
5. Offset: `offset_distance` + `offset_angle` (degrees):
   ```cpp
   transPt(-dist * cos(angleRad + π/2), -dist * sin(angleRad + π/2))
   ```
6. `multiplyOpacity`
7. Inner: draw offset shadow, `DestinationIn` with original source alpha
8. Exterior: `drawImage(offset + transPt)`
9. Blend mode: `mBlendMode` on painter (default `SourceOver`)

### 3.4 `QgsOuterGlowEffect` / `QgsInnerGlowEffect`

[`src/core/effects/qgsgloweffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsgloweffect.cpp)

1. Rasterize source
2. `QgsImageOperation::distanceTransform` with `spread` from `convertToPainterUnits(mSpread, ..., GlowSpread)`
3. Colour ramp: single-colour gradient to transparent, or custom ramp
4. `stackBlur` / `gaussianBlur` (same ≤16 threshold)
5. Inner glow: `DestinationIn` with source alpha
6. `drawImage` at `imageOffset`

`shadeExterior` true for outer glow (default), false for inner.

### 3.5 `QgsEffectStack`

[`src/core/effects/qgseffectstack.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgseffectstack.cpp)

- Processes enabled effects **back-to-front**; each result becomes source for previous
- `drawSource` effect always uses original picture
- `DrawMode::Modifier` vs `Render` controls whether result propagates
- Final composite draws non-Modifier results in forward order

### 3.6 `QgsImageOperation` helpers

[`src/core/effects/qgsimageoperation.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsimageoperation.cpp)

| Function | Semantics |
| --- | --- |
| `multiplyOpacity` | Per-pixel alpha × factor |
| `overlayColor` | Tint RGB toward colour, preserve alpha |
| `stackBlur` | 4-pass stack blur; `radius` maps to table alpha |
| `gaussianBlur` | Separable Gaussian, radius-dependent kernel |
| `distanceTransform` | 1-bit alpha → Felzenszwalb DT → ramp shade |

---

## 4. Labeling

### 4.1 Architecture

| Component | Role |
| --- | --- |
| `QgsLabelingEngine` | Orchestrates registration + solve + draw |
| `QgsVectorLayerLabelProvider` | Per-layer label candidates |
| `pal::Pal` | Placement library ([`src/core/labeling/qgslabelingengine.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/labeling/qgslabelingengine.cpp)) |
| `pal::LabelPosition`, `FeaturePart` | Candidates and chosen placements |
| `QgsTextRenderer` | Actual glyph/buffer/shadow paint |

### 4.2 Solve pipeline (`QgsLabelingEngine::solve` L332)

1. Extent = `visibleExtent().grown(extentBuffer())`
2. Map boundary = `labelBoundaryGeometry` or visible polygon (+ close ring)
3. Subtract `labelBlockingRegions`
4. `mPal->extractProblem(extent, mapBoundaryGeom, context)`
5. `mPal->solveProblem(...)` — global optimization, not greedy per feature
6. Still uses **pal** + `Chain` / cost model (class names in `src/core/labeling/pal/`)

### 4.3 Tile / metatile boundaries

**QGIS does not solve labels per tile.** One labeling problem per map render extent.

For this repo:
- Metatile render extent = core tiles + **gutter** (`render/xyz_tiles.py`, default gutter=1)
- Labels/symbols near edges are computed with extra context, then **core tiles cropped** — gutter discarded
- `RenderMapTile` flag relaxes clipping for symbols that `canCauseArtifactsBetweenAdjacentTiles()`

**Gotcha:** gutter=1 may be insufficient for long labels or large glow spreads; effects use `blurLevel*2+10` px padding minimum.

### 4.4 `QgsTextRenderer`

[`src/core/textrenderer/qgstextrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/textrenderer/qgstextrenderer.cpp)

- Font size: `convertToPainterUnits(size, unit, mapUnitScale)` rounded (L77)
- Buffer size: absolute units or % of text size (L596–597)
- Buffer drawn via `QPicture` + optional buffer `paintEffect`
- Shadow placement: `ShadowLowest`, `ShadowBuffer`, `ShadowText`, `ShadowShape`
- Draw order: shadow → buffer → mask → text → background (component flags)

---

## 5. Style definition format

### 5.1 `.qgz` container

- ZIP archive: project `.qgs` XML + `styles/` + symbology assets
- Layer styles embed `<renderer-v2>` with nested `<symbols>`, `<layer>` elements per symbol layer
- Symbol layer type in `layer` attribute `type="SimpleLine"` etc.
- Properties: child elements or `QgsSymbolLayer::properties()` keys (see per-layer sections)

### 5.2 Data-defined properties

- Serialized under `<data_defined_properties>` with property keys matching `QgsSymbolLayer::Property` enum
- Evaluated via `QgsPropertyCollection` + expression context per feature

### 5.3 Rule-based renderer XML

[`src/core/symbology/qgsrulebasedrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsrulebasedrenderer.cpp)

| Attribute | Meaning |
| --- | --- |
| `filter` | QgsExpression string |
| `scalemindenom` | **Maximum** scale (show when scale ≤ this) — naming is inverted |
| `scalemaxdenom` | **Minimum** scale |
| `else` | Catch-all rule |
| Nesting | Rules form tree; filters combined AND within branch, OR across siblings |

`Rule::dump(indent)` (L192) prints human-readable tree with filters and `symbol->dump()`.

### 5.4 Machine-readable style dump routes

| Route | Fidelity | Notes |
| --- | --- | --- |
| **PyQGIS `QgsSymbolLayer.properties()`** | High | QVariantMap of all layer props; still need renderer rules + expressions |
| **`QgsRuleBasedRenderer.rootRule().dump()`** | High for structure | Text tree; combine with `symbol->symbolLayer(i)->properties()` |
| **`QgsProject.read()` + layer tree walk** | Highest practical | Resolves paths, active rules, data-defined bindings |
| **`qgis_process`** | Medium | Can export render / print; not full symbology schema |
| **`QgsVectorLayer.saveSldStyle()`** | Low | Loses effects, many layer types, data-defined complexity |
| **MapLibre / Mapbox exporters** | Low | No effects, limited patterns; community plugins vary |

**Best approach for this project:** Python script loading `.qgz`, iterate rules, emit JSON: `{rule, filter, scaleRange, symbolLayers: [properties(), effectStack.properties()]}`. Still need parallel expression AST dump for filters and `@mercator_scale` etc.

### 5.5 Expression engine

[`src/core/expression/`](https://github.com/qgis/QGIS/tree/master/src/core/expression) — hundreds of functions.

This style uses:
- Rule filters on OSM tags
- `@mercator_scale` and geometry functions for width/size
- Data-defined SVG paths, colours, sizes

**Porting surface:** not the full expression engine — only functions referenced in the style dump. Expect **50–200** distinct functions for a complex QGZ (unverified count; run dump on `strassenraumkarte.qgz`).

---

## 6. QGIS render-comparison tests (template for Rust diff harness)

Source: [`src/core/qgsrenderchecker.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsrenderchecker.cpp).

### 6.1 `QgsRenderChecker::runTest(name, mismatchCount, flags)`

1. Load control image `mExpectedImageFile`
2. Render via attached map settings / layer tree
3. `compareImages(name, mismatchCount)`

### 6.2 Comparison algorithm (`compareImages` L356+)

- Default colour tolerance: `mColorTolerance` (per-channel absolute difference)
- Per-pixel tolerance override: companion **`_mask.png`** next to control — red channel = extra tolerance (0–255); 255 = skip pixel
- Count mismatched pixels; pass if `mismatchCount <= threshold`
- Dimension mismatch: allowed within tolerance (separate check L568)
- Outputs: rendered PNG, diff image (red = mismatch), HTML report

### 6.3 Mask workflow

Documented in failure message (L501, L776): `scripts/generate_test_mask_image.py` to grow allowed-diff regions.

### 6.4 Suggested Rust tile harness

| QGIS concept | Rust equivalent |
| --- | --- |
| Control PNG | QGIS-rendered tile at z/x/y |
| `_mask.png` | Ignore glow/blur fringe, or antialiased edges |
| `mismatchCount` threshold | Allow N pixels for FP differences |
| `mColorTolerance` | Start at 1–3; tune per layer group |
| HTML report | Side-by-side + diff heatmap per metatile |

Also see Python helpers: `tests/src/python/test_qgsrenderchecker.py`, `QgsMultiRenderChecker` for multi-layer scenarios.

---

## 7. Quick reference — technique → QGIS levers

| Goal | QGIS mechanism |
| --- | --- |
| Ground-metre line width | `MetersInMapUnits` + `convertMetersToMapUnits` / `@mercator_scale` |
| Texture fill at 30 m repeat | `RasterFill` + width/height in `MetersInMapUnits` |
| Soft shadow under fill | `QgsDropShadowEffect` on symbol layer or renderer |
| Outer halo on landuse | `QgsOuterGlowEffect` + `distanceTransform` + `stackBlur` |
| Road casing over fill | Symbol levels (`renderingPass`) |
| Label collision | Global `pal` solve on metatile+gutter extent |
| Tile seam safety | `RenderMapTile` + gutter + viewport-anchored patterns |

---

## Research sources

Full bibliography: [sources.md](./sources.md).
