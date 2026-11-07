# Style iterate gaps (stable pointer)

Latest compare run: **`audit/tile-regression/runs/style-fix-20260801-herrfurth/`**

| | |
| --- | --- |
| Gallery | `runs/style-fix-20260801-herrfurth/compare/index.html` |
| Rust cand | `runs/full-approx-20260801-200100/rust` (= `latest-rust`) |
| QGIS ref | `runs/style-iterate-20260801-190707/qgis/` (labels on) |

## Metrics — Herrfurthplatz `17/70422/43011`

| Pass | pixelmatch | Notes |
| --- | ---: | --- |
| Flat full-approx (earlier) | ~11.5% | no textures/trees/markings |
| Style-iterate buildings-v1 | **9.79%** | shapeburst + no red marking |
| **2026-08-01 evening fix** | **11.16%** | red marking + QGIS-aligned buildings/trees/textures |

Remaining gap vs 9.79% is mostly **labels** (QGIS ref has PAL text) + residual texture/tree AA. Functional parity on the four user issues is much better.

## Fixes landed (2026-08-01 evening)

1. **Streets** — Bicubic RasterFill (was Nearest → dithered sett); lower sett/asphalt α; light pre-blur on high-contrast PNGs.
2. **Trees** — `@mercator_scale` on crown diameter; soft light-green disks + faint RasterMarker; blurred dropShadow.
3. **Red cycleway** — `road_marking_polygon` `surface_colour`/`crossing` @ α 0.45 (`colour=red` → `#ff0000`).
4. **Buildings** — dropped fake ShapeburstFill; QGIS `building_shade` is **shadow-only** (`drawSource` disabled); flat `#ffe9e9` @ ~0.78 + dropShadow (2 m / 1 m @ 40° / 0.4). No separate `building` maplayer in QGIS.

## Still deferred

- PAL labels (dominate remaining pixelmatch)
- Highway z14–z20 innerShadow blur stack
- Sett `direction` / `sett:length` rotation
- Full RasterMarker leaf photo fidelity at all zooms
- `building_lines` / housenumbers
