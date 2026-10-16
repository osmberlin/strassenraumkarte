# Research sources

Bibliography for [summary.md](./summary.md). All paths are on QGIS **`master`** unless noted. One-line notes describe what each source establishes.

## Render pipeline

### [`src/core/maprenderer/qgsmaprendererjob.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/maprenderer/qgsmaprendererjob.cpp)
**QGIS**

`prepareJobs`, per-layer `QImage` allocation, `composeImage` layer order, blend mode/opacity compositing, label pass insertion, second-pass mask compose.

### [`src/core/maprenderer/qgsmaprendererparalleljob.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/maprenderer/qgsmaprendererparalleljob.cpp)
**QGIS**

Parallel layer render via `QtConcurrent::map`, label stage, `renderedImage()` compose timing.

### [`src/core/qgsrendercontext.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsrendercontext.cpp)
**QGIS**

`fromMapSettings`, `scaleFactor = dpi/25.4`, `convertToPainterUnits`, `convertMetersToMapUnits`, `setPainterFlagsUsingContext`, default and map-driven `RenderContextFlag` values.

### [`src/core/qgsmapunitscale.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsmapunitscale.cpp)
**QGIS**

`QgsMapUnitScale::computeMapUnitsPerPixel` min/max scale denominator adjustment.

### [`src/core/vector/qgsvectorlayerrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/vector/qgsvectorlayerrenderer.cpp)
**QGIS**

Per-layer render loop, renderer-level `paintEffect` begin/end, **symbol levels** (`drawRendererLevels`), feature blend mode, labeling registration.

## Symbol core

### [`src/core/symbology/qgssymbol.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbol.cpp)
**QGIS**

`renderFeature` geometry prep, `textureOrigin`, `RenderMapTile` clipping behaviour, per-symbol-layer `QgsEffectPainter`.

### [`src/core/symbology/qgssymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbollayer.cpp)
**QGIS**

`QgsFillSymbolLayer::_renderPolygon` — `QPainterPath` holes, default fill rule, `renderingPass` / symbol level index.

### [`src/core/symbology/qgssymbollayerutils.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssymbollayerutils.cpp)
**QGIS**

`offsetLine` via GEOS `offsetCurve`/`buffer`, symbol load/save, dash helpers, property encoding.

### [`src/core/symbology/qgsrulebasedrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsrulebasedrenderer.cpp)
**QGIS**

Rule XML (`filter`, `scalemindenom`, `scalemaxdenom`), `Rule::dump()`, filter combination for rendering.

## Line symbol layers

### [`src/core/symbology/qgslinesymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgslinesymbollayer.cpp)
**QGIS**

`QgsSimpleLineSymbolLayer`: pen/dash construction, `renderPolyline`, `renderPolygonStroke`, `drawPathWithDashPatternTweaks`, `alignDashPattern`, ring filter, offset.

## Fill symbol layers

### [`src/core/symbology/qgsfillsymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsfillsymbollayer.cpp)
**QGIS**

`QgsSimpleFillSymbolLayer`, `QgsImageFillSymbolLayer`, `QgsRasterFillSymbolLayer`, `QgsShapeburstFillSymbolLayer` (distance transform, stack blur).

## Marker symbol layers

### [`src/core/symbology/qgsmarkersymbollayer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgsmarkersymbollayer.cpp)
**QGIS**

`QgsSimpleMarkerSymbolLayer` cache/direct paths, `calculateSize`, shapes; `QgsSvgMarkerSymbolLayer::renderPoint` raster vs vector.

### [`src/core/symbology/qgssvgcache.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/symbology/qgssvgcache.cpp)
**QGIS**

`svgAsImage`, `replaceElemParams` for `param(fill)` / `param(outline)` / `param(outline-width)`, cache sizing.

## Paint effects

### [`src/core/effects/qgspainteffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgspainteffect.cpp)
**QGIS**

Effect base class: `begin`/`end` QPicture capture, `sourceAsImage`, `QgsDrawSourceEffect`, `QgsEffectPainter`.

### [`src/core/effects/qgseffectstack.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgseffectstack.cpp)
**QGIS**

Multi-effect ordering, Modifier vs Render draw modes, rasterization guard.

### [`src/core/effects/qgsblureffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsblureffect.cpp)
**QGIS**

Stack vs Gaussian blur, blur level unit conversion, bounding rect spread.

### [`src/core/effects/qgsshadoweffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsshadoweffect.cpp)
**QGIS**

`QgsDropShadowEffect`, `QgsInnerShadowEffect`: overlay colour, blur threshold 16, offset angle math.

### [`src/core/effects/qgsgloweffect.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsgloweffect.cpp)
**QGIS**

`QgsOuterGlowEffect`, `QgsInnerGlowEffect`: distance transform + blur + inner alpha mask.

### [`src/core/effects/qgsimageoperation.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/effects/qgsimageoperation.cpp)
**QGIS**

`stackBlur`, `gaussianBlur`, `distanceTransform`, `multiplyOpacity`, `overlayColor` implementations.

## Labeling & text

### [`src/core/labeling/qgslabelingengine.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/labeling/qgslabelingengine.cpp)
**QGIS**

`pal::Pal` integration, `extractProblem`, `solveProblem`, extent/boundary geometry, label draw pass.

### [`src/core/textrenderer/qgstextrenderer.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/textrenderer/qgstextrenderer.cpp)
**QGIS**

Text size/buffer unit conversion, buffer/shadow draw order, `convertToPainterUnits` for font metrics.

## Render testing

### [`src/core/qgsrenderchecker.cpp`](https://github.com/qgis/QGIS/blob/master/src/core/qgsrenderchecker.cpp)
**QGIS**

`runTest`, per-channel tolerance, `_mask.png` per-pixel tolerance, mismatch count threshold, HTML report.

## Official documentation

### [QGIS API Documentation](https://api.qgis.org)
**QGIS project**

Class reference for `QgsMapSettings`, `QgsRenderContext`, `QgsSymbolLayer`, enums `Qgis::RenderUnit`, `Qgis::RenderContextFlag`.

### [QGIS User Guide — Symbology](https://docs.qgis.org/latest/en/docs/user_manual/style_library/symbol_selector.html)
**QGIS Documentation**

User-facing symbology concepts (secondary to source for exact pixel semantics).

### [Qt QPainter documentation](https://doc.qt.io/qt-6/qpainter.html)
**Qt**

`RenderHint`, `CompositionMode`, `QPen` dash pattern units, `QPainterPath` fill rules.

## This repository

### [`render/xyz_tiles.py`](../../render/xyz_tiles.py)
**strassenraumkarte**

Metatile loop, gutter semantics, EPSG:3857 extent, QImage allocation guards.

### [`docs/maplibre-style-groups.md`](../../docs/maplibre-style-groups.md)
**strassenraumkarte**

Symbol layer counts (SimpleLine/Fill/Marker/SvgMarker/RasterFill), effect counts, MapLibre porting notes.

### [`.cursor/plans/maplibre_vector_output_channel_301665ec.plan.md`](../../.cursor/plans/maplibre_vector_output_channel_301665ec.plan.md)
**strassenraumkarte**

Style inventory and Rust/MapLibre migration context.

## Notes on coverage gaps

- **`pal` internals** (`Chain`, cost coefficients): not read file-by-file; behaviour inferred from `QgsLabelingEngine` + historical QGIS docs. Marked **partially verified**.
- **`QgsImageOperation::gaussianBlur` kernel details**: read header loop only; exact kernel weights not transcribed.
- **`QgsRenderedLayerStatistics`**: not investigated (newer API; unclear test harness relevance).
- **`QgsTextRenderer` full draw path**: buffer QPicture path read; not every shadow permutation.
- **Expression function inventory for `strassenraumkarte.qgz`**: not executed; count in summary is an estimate.
- **QGIS release version**: sources are `master` branch; installed QGIS for rendering may differ slightly.

## Unverified claims

| Claim | Status |
| --- | --- |
| `QPainterPath` default fill rule is OddEvenFill | **Verified** via Qt docs; QGIS does not override |
| Exact expression function count for this project | **Unverified** — needs PyQGIS dump script |
| `pal` still uses Chain algorithm internally | **Partially verified** — class names present; solver details not read |
