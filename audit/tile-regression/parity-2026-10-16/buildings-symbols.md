# Buildings and symbols parity (`full-approx` vs QGIS)

Scope: building fill and shadow, `building_lines`, road markings, street furniture and SVG
markers in `rust/srk-render`. Trees, labels, ground and street fills are out of scope and
still dominate the remaining error.

Reference: `/tmp/parity/baseline/qgis/` (QGIS, full project). Candidate: `--layers full-approx`,
`--metatile 1 --gutter 1 --workers 1 --format png`, same 10 tiles as `manifest-full.json`.
Metric: pixelmatch ratio from `audit/tile-regression/scripts/compare-run.ts` (threshold 0.1).

## Result

| Tile | Label | Before | After | Δ (pp) |
| --- | --- | ---: | ---: | ---: |
| 15/17605/10752 | intersection parent z15 | 23.15 % | 16.26 % | -6.89 |
| 15/17606/10752 | density z15 | 25.60 % | 12.68 % | -12.92 |
| 16/35211/21505 | intersection z16 | 19.25 % | 10.33 % | -8.92 |
| 16/35212/21505 | density z16 | 20.19 % | 8.98 % | -11.21 |
| 17/70422/43011 | intersection z17 (Herrfurthplatz) | 15.79 % | 9.49 % | -6.30 |
| 17/70425/43010 | density peak z17 | 14.71 % | 7.19 % | -7.53 |
| 18/140845/86023 | intersection z18 | 14.90 % | 11.78 % | -3.12 |
| 18/140851/86021 | density z18 | 10.85 % | 6.72 % | -4.14 |
| 19/281691/172046 | intersection z19 | 15.96 % | 15.19 % | -0.77 |
| 20/563382/344092 | intersection z20 | 9.23 % | 9.03 % | -0.21 |
| **mean** | | **16.96 %** | **10.76 %** | **-6.20** |

Building-class pixels at 17/70422/43011 now account for about 3 to 6 % of the remaining
mismatches. Green (trees, parks) is about half and grey (road edges, markings, shadows) about a
fifth. Labels are the rest.

Before and after crop (tile 17/70422/43011, 0–256 × 0–200 px, 2×): [`buildings-symbols.jpg`](buildings-symbols.jpg)

## What changed and why

Each item is checked against the QGIS project (`style/strassenraumkarte.qgz`, `.qgs` layer
XML) and, where noted, against pixel values in the QGIS reference.

1. **Building shadow under the fill, no knockout** (`paint.rs` `fill_polygons_batch_shadow_under`,
   `layers.rs` `paint_building_parts`). QGIS paints the dropShadow under the whole footprint,
   so the interior is darkened. The old code knocked the shadow out of the interior, which
   made building interiors too light. Pixel check at 43011 row y=40: QGIS interior `#e6d1d1`,
   before `#fbeaea`, after `#e2d2d2`.
2. **Building symbol alpha 0.7** (was 0.78). `building_parts_dissolved_height` has
   `alpha="0.7"` on `#ffe9e9`.
3. **`building_lines` added** (`layers.rs` `paint_building_lines`, `TableCache::building_lines`).
   Categories: `footline_covered` (#cacaca 0.2 m plus 0.45 m dashed 0.1 m #808080),
   `footline_uncovered` (0.05 m), `part_outline` (0.02 m), `roof_edge` and `roof_ridge`
   (0.04 m). Widths are ground metres × `@mercator_scale`. These draw the thin seams between
   building parts that the QGIS reference shows.
4. **Sub-pixel line model** (`layers.rs` `stroke_lines_exact`). `stroke_lines_dashed` has a
   0.5 px floor, which made every 0.02–0.12 m line a dark 1 px stroke, and at z15 it pushed the
   density tile to 40 %. The new helper uses the true width. Strokes thinner than 1 px are drawn
   at 1 px with alpha scaled by width, which matches AA coverage better than tiny-skia's thin
   stroke.
5. **Road markings use QGIS sizes and layer opacity** (`paint_road_marking_way`,
   `paint_road_marking_node`). Line width and dash lengths are `@mercator_scale * value`. The
   `road_marking_*` layers have `layerOpacity` 0.67. The old 10 px minimum on SVG signs
   (`min_m`) and the `max(0.8)` floor are removed. Traffic sign and symbol sizes come from the
   `width` and `length` data-defined expressions (arrow: `0.3·length·clamp(2−length/5, 1, 2)`).
   Result: the z15 black "spider" blobs at junctions are gone. Blue sign icons are now small, as in QGIS.
6. **SVG stamp floor** (`svg_stamps.rs` `stamp_tree_at_map_opacity`). The 2 px minimum is
   replaced by a sub-pixel skip (area < 0.25 px²). QGIS SVG markers have no pixel floor.
   Added `stamp_at_map_opacity` for symbol alpha (manhole 0.5, post box 0.5, artwork 0.67).
7. **Street furniture from `feature_node (middleground)`** (`furniture_a.rs`
   `paint_feature_node_furniture`, `furniture_marks`). Rules transcribed from the QGIS table.
   Covered: manhole, waste basket, bench (backrest yes/no), street cabinet, pole, post box,
   recycling, table tennis, picnic table, artwork, advertising column, vending machine, charging
   station, drinking water, clock, water well, planter, monitoring station, shelter, fountain,
   grit bin, guidepost, telephone, street lamp (circle with grey cross, bent-mast SVG when
   directed), traffic sign (arrow 222, street name sign, general pentagon approximated as a
   disc). Angles follow the QGIS data-defined expressions (`direction`, `direction±90`,
   `direction−180`).
8. **Feature polygons** (`furniture_a.rs` `paint_feature_polygon_furniture`): recycling areas
   under 150 m² with the recycling symbol at the centroid, waste disposal, toilets and skatepark
   obstacles, with QGIS fill and outline colours.
9. **Scale gates in QGIS terms**. QGIS evaluates scale in EPSG:3857 map units without a
   latitude correction, so 1:750 at 96 dpi is 0.198 m/px (z20), and 1:1500 is 0.397 m/px.
   Applied to: bicycle parking and mobility hub SVGs (`scalemaxdenom 750`, now z20 and up), and
   the fire-hydrant "H" marker (`@map_scale > 1500` hides it). The hydrant red ring is drawn
   only for pillar, pipe and wall (QGIS outline alpha 0 for the rest).
10. **Mercator sizes for bicycle parking SVGs** (`furniture_a.rs`): `1.8 | 2.2 × @mercator_scale`.

Checked and not implemented, because QGIS shows nothing:

- `roof shape` layer (`building`, `building:part IS NULL`, opacity 0.404): the flat roof and
  gabled roof buildings in 43011 show no red or gradient tint in the reference. Layer is
  effectively invisible here, so no roof shading is drawn. Shapeburst is not in the QGIS
  project, so there is no lighter centre.
- `parking cars`: the layer reads `data/parking/street_parking_points_processed.geojson`, which
  is 0 bytes in this checkout (only `.gitkeep`). Not implemented.

## Not done / remaining gaps

- Labels (`PAL`): the QGIS reference has house numbers and names, the candidate does not.
- Trees: the candidate draws boxy shadow squares around crowns, and the crowns are flatter
  than the QGIS textured crowns. Out of scope here.
- Ground and paving textures (Herrfurthplatz paving), and the grey kerb and edge lines on
  roundabouts. Out of scope here.
- Furniture not covered: `feature_node (foreground)` (toilets, information board, memorial,
  guard stone, public bookcase, mast), loading ramp (raster), wall-mounted street lamps and wall
  bracket lamps, vertical 605 signs, traffic signals at z17 (`furniture_batch_b`, size not
  verified against QGIS), and the `pentagon` sign shape (approximated as a disc).
- Symbol alpha and effects on SVGs are approximated (SVG `param(fill)` colours are not
  applied). The `cross2` lamp mark is drawn as two grey bars.
- Fire hydrant ring and "H" sizes were left at the previous calibration (`0.35` and `0.7` in
  3857 metres). QGIS sizes are `@mercator_scale`-scaled, so they are about 0.6× too small. A
  mercator-scaled attempt made the score slightly worse, so it was reverted. Needs a careful look.
- The `paint_road_marking_*` functions are also called by the `la` preset (`style_la.rs`); their
  output changes there too (thicker lines, real sizes, opacity 0.67).

## Reproduce

```bash
cd rust/srk-render && PATH="$HOME/.cargo/bin:$PATH" cargo build --release
cd ../.. && DB_PORT=5433 PGPASSWORD=postgres ./rust/srk-render/target/release/srk-render \
  --tiles 15/17605/10752,15/17606/10752,16/35211/21505,16/35212/21505,17/70422/43011,17/70425/43010,18/140845/86023,18/140851/86021,19/281691/172046,20/563382/344092 \
  --layers full-approx --out /tmp/parity/bld/rust --format png --metatile 1 --gutter 1 --workers 1
cd audit/tile-regression && bun run scripts/compare-run.ts --manifest manifest-full.json --suite full \
  --ref-dir /tmp/parity/baseline/qgis --cand-dir /tmp/parity/bld/rust --out /tmp/parity/bld/compare
```
