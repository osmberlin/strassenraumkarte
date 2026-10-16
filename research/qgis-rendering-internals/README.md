# QGIS rendering internals

Primary-source research notes on how QGIS turns styled vector layers into pixels — the semantics a faithful Rust reimplementation of this project's PyQGIS metatile renderer would need to reproduce.

Sources are the QGIS `master` branch ([qgis/QGIS](https://github.com/qgis/QGIS)), QGIS API docs, and Qt `QPainter` behaviour. QGIS version read: **master branch as of 2026-08-01** (not tied to a release tag).

## Contents

| File | Purpose |
| --- | --- |
| [summary.md](./summary.md) | Spec-style notes by topic: render pipeline, symbol layers, effects, labeling, style format, render tests |
| [sources.md](./sources.md) | Bibliography: every URL/file read, grouped, with one-line notes |

## Scope

Prioritises symbol types and effects this project uses heavily in `style/strassenraumkarte.qgz` (per `docs/maplibre-style-groups.md`):

- **Symbol layers:** SimpleLine (~1058), SimpleFill (~835), SimpleMarker (~803), SvgMarker (~185), RasterFill (~133), plus 7 Gradient/Shapeburst fills
- **Effects:** ~137 enabled dropShadow / innerShadow / outerGlow (blur is used inside those)
- **Labeling:** full-map PAL solve (metatile gutter exists specifically for label/symbol bleed)

Breadth on MarkerLine, FontMarker, LinePatternFill, etc. is intentionally shallow unless noted. No application code is changed here.
