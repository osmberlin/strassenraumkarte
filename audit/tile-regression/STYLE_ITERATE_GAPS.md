# Style iterate gaps (stable pointer)

Latest compare run: **`audit/tile-regression/runs/style-iterate-20260801-190707/`**

| | |
| --- | --- |
| Gallery | `runs/style-iterate-20260801-190707/compare/index.html` |
| Full write-up | `runs/style-iterate-20260801-190707/GAPS.md` |
| QGIS ref | `render/tiles/` (jpg) |
| Rust cand | `runs/latest-rust/` → `bench-large-fullapprox-20260801-162831/rust` |

## Metrics (2026-08-01 run)

- **8 tiles (all):** mean pixelmatch **3.98%**, max **12.49%**
- **3 active tiles:** mean **10.63%** (five z18 tiles are blank `#ededed` both sides)
- Worst: `17/70425/43010` 12.49%, `17/70422/43011` 11.48%, `18/140844/86022` 7.91%

## Top 3 for next renderer pass

1. **RasterFill textures** — **v1 shipped** (2026-08-01): map-anchored `Pattern` fill for `highway_area` surface + `landuse` surface/class overlays (`rust/srk-render/src/textures.rs`, `paint.rs`). Textures from `vector/public/sprites/` (PNG sources under `style/textures/` not in git). Limits: no rotation, no innerShadow on roads, phase may differ from QGIS metatile ref.
2. **Tree crowns** — **v1 shipped** (2026-08-01): QGIS `style/symbols/trees/{broadleaved,needleleaved}.png` RasterMarker stamps + under-disk shadow (`tree_markers.rs`, `paint.rs::draw_tree_crown_marker`, `layers.rs::paint_tree`). Honours `diameter_crown`, `leaf_type`, `rotation`, shrub vs tree shadow.
3. **Building inner gradients** — **v1 shipped** (2026-08-01): mask−blur edge darkening on `building` + `building_parts` (`paint.rs::ShapeburstFill`, `fill_polygons_shapeburst`, `fill_polygons_batch_with_shadow_shapeburst`). Exterior SE drop-shadow retained on `building`.

### RasterFill v1 — pixelmatch (active z17 tiles)

| Tile | Before (flat) | After (RasterFill v1) | Δ |
| --- | ---: | ---: | ---: |
| `17/70422/43011` Herrfurthplatz | 11.48% | **12.69%** | +1.21% |
| `17/70425/43010` density peak | 12.49% | **12.91%** | +0.42% |

Cand: `runs/style-iterate-20260801-190707/rust-rasterfill-v1/` · compare: `compare-rasterfill-v1/`

**Shipped textures:** `surface/asphalt`, `surface/concrete`, `surface/paving_stones`, `surface/sett`, `grass`, `gravel`, `sand`, `woodchips` (from `style/textures/`; sprite/procedural fallback).

**Why Δ is positive:** pixelmatch still dominated by trees, buildings, labels, road-edge blur — not textures alone. Texture phase (map-anchored vs QGIS viewport/metatile) adds high-frequency residual. Rust-vs-Rust delta is ~1.7% mean (textures visibly change roads/parks).

**Not in v1:** per-feature rotation (`direction`, `sett:length` widths), highway innerShadow blur stack, pitch/sandpit/water textures.

### Tree crowns v1 — pixelmatch (active z17 tiles, RasterFill v1 baseline)

| Tile | RasterFill v1 | After (trees v1) | Δ |
| --- | ---: | ---: | ---: |
| `17/70422/43011` Herrfurthplatz | 12.69% | **10.68%** | −2.01% |
| `17/70425/43010` density peak | 12.91% | **11.83%** | −1.08% |

Cand: `runs/style-iterate-20260801-190707/rust-trees-v1/` · compare: `compare-trees-v1/`

**Approach:** Load QGIS crown PNGs (`broadleaved` / `needleleaved`); scale by `diameter_crown` (max-dimension, map metres); rotate via `rotation` column; offset under-disk shadow (0.4 m @ 45°, α≈0.18); crown stamp @ α≈0.92. Trunk unchanged.

**Residual:** Buildings (shapeburst), labels, road-edge effects still dominate diff. Full marker dropShadow blur stack not ported (under-disk only). Forest `randf` crown sizes materialised in DB only.

**Not in v1:** per-tree blurred RasterMarker shadow mask, shrub crown size randomisation at query time.

### Building shapeburst v1 — pixelmatch (active z17 tiles, trees v1 baseline)

| Tile | Trees v1 | After (buildings v1) | Δ |
| --- | ---: | ---: | ---: |
| `17/70422/43011` Herrfurthplatz | 10.68% | **9.79%** | −0.89% |
| `17/70425/43010` density peak | 11.83% | **8.59%** | −3.24% |

Cand: `runs/style-iterate-20260801-190707/rust-buildings-v1/` · compare: `compare-buildings-v1/`

**Approach:** Per-polygon mask − box-blur edge factor (QGIS ShapeburstFill stand-in): base `#ffe9e9` fill, then darken toward boundary over ~3 m (`band_m`) with `#a07070` @ strength ≈0.42. Applied to `building_parts_dissolved_height` and `building` (batch exterior shadow unchanged).

**Residual:** Labels, road-edge innerShadow, PAL text, one block's diagonal RasterFill hatch on `building_parts` (not ported — no hatch asset wired). Felzenszwalb distance-transform ramp + per-parts dropShadow (QGIS blur 2 m @ 40°) still deferred. Small footprints may over-darken vs QGIS when band width exceeds interior.

**Not in v1:** building_parts RasterFill hatch overlay, `roof shape` ShapeburstFill, parts-table dropShadow, area-scaled band width.

## Sample tile set

```
17/70422/43011  Herrfurthplatz (primary)
18/140844/86022
17/70425/43010  density peak
18/140857/86021  (blank — swap out)
18/140845/86058  (blank)
18/140843/86069  (blank)
18/140865/86060  (blank)
18/140859/86046  (blank)
```

Replace blank z18 tiles with feature-rich coords inside bbox `13.3958,52.4243,13.4874,52.4849` before the next iterate.
